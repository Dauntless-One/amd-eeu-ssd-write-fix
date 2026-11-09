# Methodology

How each number in the README was produced, so anyone can reproduce or challenge it. Every command needs an elevated PowerShell.

## 1. Finding the writer (kernel I/O trace)

Windows Performance Recorder is built into Windows 10 and 11.

```powershell
wpr -start FileIO -start DiskIO -filemode
Start-Sleep 60                      # leave the PC idle
wpr -stop C:\Temp\io.etl
tracerpt C:\Temp\io.etl -o C:\Temp\io.csv -of CSV -y
```

In the CSV:

- `FileIo/Write` events carry the issuing thread (`TTID`), the file key and `IoSize` (logical writes).
- `DiskIo/Write` events carry the disk number, the file key and `TransferSize` (physical writes).
- `Thread/DCStart` maps thread to process ID; `Process/DCStart` maps process ID to image name.
- `FileIo/FileRundown` and `FileIo/FileCreate` map file key to path.

Joining these gave, for 60 s idle:

| Process | Logical writes | File |
|---|---|---|
| `atieclxx.exe` | 52,921 KB | `\Windows\System32\config\systemprofile\AppData\Local\AMD\atieclxx.exe` |

and 39,840 KB of physical writes to disk 0 (the boot SSD) for that file. Physical writes are attributed to `System` (the cache manager's lazy writer), so join on the file key, not the process.

Tip: write the `.etl` to a different drive than the one you are measuring. WPR's own buffers show up as large writes too.

## 2. Confirming the pattern (NTFS change journal)

```powershell
fsutil usn readjournal C: csv | Select-String -SimpleMatch '"atieclxx.exe"' | Select-Object -Last 6
```

Each cycle shows: `EA change`, `Data truncation`, `Data extend`, `Data overwrite`, `Basic info change`, `Close`. The `Basic info change` is the timestamp reset that hides the activity. Count records over a fixed window to get a rate (246 records in 20 s on the test system).

Identity check:

```powershell
$copy = "$env:WINDIR\System32\config\systemprofile\AppData\Local\AMD\atieclxx.exe"
$run  = (Get-Process atieclxx).Path
Get-FileHash $copy, $run
```

Both hashes matched: the copy is the running driver binary.

## 3. FreeSync/VRR test (PresentMon)

Tool: [Intel PresentMon](https://github.com/GameTechDev/PresentMon) 2.6.0 CLI (signed by Intel).

Setup:
- Game with V-Sync **on**, no frame cap, running below the display's max refresh. Dragon's Dogma 2's title screen ran at about 80 to 90 fps on a 120 Hz display.
- Radeon Enhanced Sync **off**. Below max refresh, Enhanced Sync behaves like V-Sync off, so a broken VRR run would tear instead of quantizing and the test couldn't tell the difference.

Capture 30 s:

```powershell
.\PresentMon-2.6.0-x64.exe --process_name DD2.exe --output_file run.csv --timed 30 --terminate_after_timed --v1_metrics --no_console_stats
```

Analysis: take `msBetweenDisplayChange` for non-dropped frames. With V-Sync on and a fixed refresh, every value must be a multiple of the refresh period (8.333 ms at 120 Hz). Count the share within 0.35 ms of a multiple:

```powershell
$p = 1000/120
$v = Import-Csv run.csv | ? Dropped -eq 0 | % { [double]$_.msBetweenDisplayChange } | ? { $_ -gt 0 }
$on = ($v | ? { [math]::Abs($_/$p - [math]::Round($_/$p)) * $p -le 0.35 }).Count
'{0:N1}% on grid' -f (100 * $on / $v.Count)
```

- About 100% on grid (only 8.3 / 16.7 / 25 ms): fixed refresh, **VRR not active**.
- A large off-grid share (here about 48%): refresh interval varying, **VRR active**.

Run order used: A (service running), B (service disabled, fresh reboot), C (service re-enabled, same scene as B, to rule out scene differences), D (service running with the fix applied).

Caveat: the game presented as `Composed: Flip` (borderless). Exclusive fullscreen was not tested.

## 4. Fix verification

After `-Action Apply`:

- Change journal: 0 records for the file in 15 s (previously 246 per 20 s).
- Kernel trace: no file writes from any AMD process in 60 s.
- `atieclxx.exe` CPU over 15 s: 0.04% of total.
- PresentMon run D: 48.7% off-grid (VRR working).
- After a reboot: the deny rule was still present, the file's creation time was unchanged (not deleted and recreated), and the journal showed no writes since the rule was applied.
