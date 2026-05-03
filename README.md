# PCPreviZ / FastCheck

**FastCheck.ps1** is a Windows PowerShell script that prints a structured hardware and system report to the console. It is aimed at anyone who wants a quick read on device identity, key components, storage headroom, battery health (on laptops), and whether Windows reports any misconfigured or failing plug-and-play devices.

## Requirements

- Windows with PowerShell (the script uses CIM, BitLocker cmdlets when elevated, and optional UEFI Secure Boot confirmation when elevated).
- Run from an ordinary PowerShell window, or start PowerShell **as Administrator** when you need the checks that require elevation (see below).

## How to run

From the repository folder:

```powershell
.\FastCheck.ps1
```
or precompiled binary

To run with full privileges (right-click PowerShell, **Run as administrator**, then execute the same command).

## Normal run versus run as administrator

### Normal run (fastest)

Without elevation, the script avoids operations that need administrator rights. 
Sections that depend on elevation show a short note that you must run as admin to check them (for example **Secure Boot** and **BitLocker**).

Use this mode when you want the quickest pass with minimal friction and no UAC prompt.

### Run as administrator (most comprehensive)

With elevation, the script can:

- Report **Secure Boot** status via `Confirm-SecureBootUEFI`.
- Inspect **BitLocker** on the `C:` volume with `Get-BitLockerVolume`.

**Important:** If BitLocker is not fully decrypted on `C:`, the script attempts to **disable BitLocker** on that volume (`Disable-BitLocker`). If you rely on full-disk encryption, review that behavior before running elevated, or run the normal (non-admin) mode if you only want a read-only style report.

Administrator mode is appropriate when you intentionally want those firmware and volume checks and accept the BitLocker handling implemented in the script.

## What the report covers (summary)

| Area | Typical content |
|------|-----------------|
| System and OS | Manufacturer, model, Windows caption and build, BIOS serial |
| Licensing | Product key from firmware OA3 or registry fallback |
| CPU / BIOS | Processor name, core counts, BIOS identification string |
| Secure Boot / BitLocker | Only fully populated when elevated (BitLocker may trigger decryption on `C:`) |
| Graphics | Physical GPUs matching common vendor patterns; driver version, resolution, reported VRAM |
| Display | Approximate panel size from WMI monitor data when reported |
| Memory | Per-DIMM capacity, speed, slot, part number |
| Peripherals | Webcam (Camera/Image class), microphone via PnP |
| Storage | Fixed drives: free space, total size, free percentage |
| Network | Physical adapters (non-virtual) with link speed when available |
| Battery | Charge level; health percentage from WMI or `powercfg /batteryreport` XML if WMI is insufficient |
| Device health | PnP entities with configuration error codes (with short descriptions for common codes) |

## Limitations

- This is a **snapshot** tool: it reflects what Windows reports at run time, not a full stress test or long-term reliability study.
- Some values (GPU VRAM, monitor size, battery health) can be missing or approximate depending on drivers and firmware.
- Elevated runs have side effects on BitLocker
