# AMD External Events Utility SSD write fix

Stop-gap fix for an AMD Radeon driver bug where `atieclxx.exe` (AMD External Events Client Module) copies itself to disk over and over, writing tens of GB per day to your system SSD while the PC sits idle.

The common advice is to disable the **AMD External Events Utility** service. **That breaks FreeSync/VRR** (measured below). This script keeps the service running and blocks only the useless self-copy.

> Unofficial community workaround. Not affiliated with AMD. Remove it once AMD ships a fixed driver.

## The problem

On affected drivers, `atieclxx.exe` repeatedly copies its own executable to:

```
C:\Windows\System32\config\systemprofile\AppData\Local\AMD\atieclxx.exe
```

Each cycle truncates the file, rewrites the full 677 KB, closes it, then resets the timestamps. The file's "Date modified" never changes, so the activity is invisible in Explorer.

Measured on the test system (idle desktop, 60 s kernel trace):

| Metric | Value |
|---|---|
| Copies | about 78 per minute |
| Logical writes by `atieclxx.exe` | 52.9 MB/min |
| Physical writes to the SSD | 39.8 MB/min |
| Projection | about 2.4 GB/hour, about 57 GB/day if the PC runs 24/7 |
| On a 500 GB drive rated 300 TBW | about 7% of rated endurance per year at 24/7 |

Nothing about the copied file changes between cycles: it is byte-for-byte identical to the running driver binary.

## Why not just disable the service?

Because FreeSync/VRR stops working. Tested with Intel PresentMon on Dragon's Dogma 2 (V-Sync on, about 80 to 90 fps on a 120 Hz FreeSync TV). On a fixed 120 Hz display, screen updates can only land on multiples of 8.33 ms; values in between mean the refresh rate is varying (VRR active).

| Run | Service | Updates off the 8.33 ms grid | Result |
|---|---|---|---|
| A | Running | 48.3% | VRR working |
| B | Disabled (fresh reboot) | 0.0% (only 8.3 and 16.7 ms) | VRR broken, locked to 120 Hz |
| C | Re-enabled, same scene as B | 48.8% | VRR working |
| D | Running, **this fix applied** | 48.7% | VRR working |

## What the script does

Adds one NTFS **deny** rule for `SYSTEM` (write data, append, write attributes, write extended attributes, delete) on that single copied file. The copy attempt fails, nothing is written, and the service keeps running.

- One file, one ACL entry. No services, drivers, registry or AMD settings are changed.
- Fully reversible with `-Action Remove`.
- Results on the test system: writes 78 copies/min to 0, `atieclxx.exe` stays running at about 0.04% CPU, VRR still works, and the rule survives a reboot.

## Requirements

- Windows 10 or 11 with an AMD Radeon driver that installs the AMD External Events Utility service
- Administrator rights
- Windows PowerShell 5.1 (built in) or PowerShell 7

## Usage

### 1. Download

Download `Fix-AmdEeuSsdWrites.ps1` from this repo (open the file, then **Download raw file**), or clone the repo / **Code > Download ZIP**. Check its SHA-256:

```powershell
Get-FileHash .\Fix-AmdEeuSsdWrites.ps1 -Algorithm SHA256
```

Expected:

```
541E531405152C4B0ACFC3654397656BF3DA46527A43CB5BDD787413D767487D
```

If the hash differs, the file was modified or corrupted in transit. Don't run it.

### 2. Open an elevated PowerShell

- **GUI:** Start menu, type `PowerShell`, right-click **Windows PowerShell** (or **Terminal**), choose **Run as administrator**.
- **CLI:** from any PowerShell window: `Start-Process powershell -Verb RunAs`

Then `cd` to the folder with the script.

### 3. Check whether you are affected

```powershell
powershell -ExecutionPolicy Bypass -File .\Fix-AmdEeuSsdWrites.ps1 -Action Measure
```

Leave the PC idle for 30 seconds. Output like this means the bug is active:

```
[*] Change events: 28 in 20 s (about 84 per minute).
[!] Bug is ACTIVE. Rough upper bound: up to about 76.3 GB/day if the PC runs 24/7.
```

(The GB/day figure is an upper bound from change notifications. The kernel-trace measurement above is the accurate number.)

### 4. Apply

```powershell
powershell -ExecutionPolicy Bypass -File .\Fix-AmdEeuSsdWrites.ps1 -Action Apply
```

```
[+] Fix applied.
[*] Verifying for 15 s...
[+] No writes in 15 s. Done.
```

Then play a game and confirm FreeSync/VRR behaves as before (your TV or monitor's refresh-rate readout is the simplest check).

### 5. Check status any time

```powershell
powershell -ExecutionPolicy Bypass -File .\Fix-AmdEeuSsdWrites.ps1
```

```
[*] Service: Running, start type Auto
[*] Running client: C:\WINDOWS\System32\DriverStore\FileRepository\u0205306.inf_amd64_...\atieclxx.exe
[*] Copy: C:\WINDOWS\System32\config\systemprofile\AppData\Local\AMD\atieclxx.exe (677392 bytes, ...)
[*] Copy matches the running driver's atieclxx.exe.
[+] Fix is APPLIED (SYSTEM deny-write rule present).
```

### Undo

```powershell
powershell -ExecutionPolicy Bypass -File .\Fix-AmdEeuSsdWrites.ps1 -Action Remove
```

Preview any change without making it by adding `-WhatIf`.

### Manual equivalent (no script)

From an elevated prompt:

```powershell
# apply
icacls "$env:WINDIR\System32\config\systemprofile\AppData\Local\AMD\atieclxx.exe" /deny "*S-1-5-18:(WD,AD,WEA,WA,DE)"
# check
icacls "$env:WINDIR\System32\config\systemprofile\AppData\Local\AMD\atieclxx.exe"
# undo
icacls "$env:WINDIR\System32\config\systemprofile\AppData\Local\AMD\atieclxx.exe" /remove:d "*S-1-5-18"
```

The GUI (Explorer, Properties, Security) can't reach this folder without taking ownership of the SYSTEM profile, which is not recommended. Use the CLI.

## After an AMD driver update

A new driver installs a new `atieclxx.exe`. `-Action Status` warns if the protected copy no longer matches the running binary. To refresh:

1. `-Action Remove`
2. Reboot
3. `-Action Measure`. If the bug is gone, you're done (AMD fixed it). If it's still active, run `-Action Apply` again.

## FAQ

**Is this safe?** It only denies SYSTEM write and delete access on a duplicate of a driver executable that the driver itself never runs from that location. On the test system `atieclxx.exe` kept running normally, with no crashes, CPU spikes or event log errors, and VRR was unaffected. It's still an unofficial change: undo it if anything misbehaves.

**Why not redirect the folder to a RAM disk?** That needs a third-party RAM disk driver that must mount before the AMD service starts at every boot, and it moves the problem instead of removing it. Blocking the write has no dependencies.

**Does this fix the "log rewrites on window move" reports?** That is a separate, much smaller behavior (on the test system about 70 small log rewrites per day, under 50 MB/week, in `DriverStore\FileRepository\amdfendr.inf_amd64_*\AMD\AppHistoryDumps`). It isn't worth patching.

**Will AMD fix this?** AMD has reportedly acknowledged SSD write reports and has a fix in validation. Remove this workaround once a fixed driver is out.

## Test system

| Component | Value |
|---|---|
| OS | Windows 11 Pro, build 26200 |
| GPU | Radeon RX 7900 XT, Adrenalin 26.20 (driver 32.0.32015.7029) |
| CPU | Ryzen 9 7950X3D |
| Boot SSD | WD_BLACK SN770 500 GB |
| Display | 4K 120 Hz FreeSync TV over HDMI |
| PowerShell | 5.1 and 7.6 |

Results on other GPUs and driver versions are welcome. Please open an issue with the output of `-Action Status` and `-Action Measure`.

## How this was measured

See [docs/METHODOLOGY.md](docs/METHODOLOGY.md) for the kernel trace, change-journal and PresentMon procedures, so you can reproduce the numbers yourself.

## Sources

- Tom's Hardware: [AMD users flag heavy SSD write activity tied to chipset driver](https://www.tomshardware.com/software/windows/amd-users-flag-heavy-ssd-write-activity-tied-to-chipset-driver-incessant-log-file-writes-observed-every-time-a-window-is-moved-or-resized)
- PC Gamer: [AMD's graphics driver discovered making hundreds of SSD writes for every mouse move](https://www.pcgamer.com/hardware/graphics-cards/amds-graphics-driver-discovered-making-hundreds-of-ssd-writes-for-every-mouse-move-but-it-probably-isnt-actually-a-problem)
- WindowsForum: [AMD Radeon SSD write bug: how to check atieclxx.exe](https://windowsforum.com/news/amd-radeon-ssd-write-bug-how-to-check-atieclxx-exe-on-windows-10-and-11.450605/)
- GameGPU: [AMD Radeon drivers can continuously write up to 432 GB per day](https://en.gamegpu.com/news/zhelezo/drajvery-amd-radeon-mogut-postoyanno-zapisyvat-do-432-gb-dannykh-na-ssd-za-sutki)
- Intel PresentMon: <https://github.com/GameTechDev/PresentMon>

## License

MIT. See [LICENSE](LICENSE). Provided as-is, without warranty.
