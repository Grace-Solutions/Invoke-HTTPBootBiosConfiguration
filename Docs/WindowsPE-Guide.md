# Windows PE Guide

The script runs inside Windows PE (WinPE) so that the HTTP(s) boot BIOS configuration can be performed as a step within an MDT/SCCM task sequence. WinPE is detected automatically by the toolkit (`HKLM:\SYSTEM\ControlSet001\Control\MiniNT`), and logs are redirected to the standard MDT/SCCM task sequence log locations when a task sequence is running.

## Boot image requirements

| Component | Needed for | Notes |
| --- | --- | --- |
| WinPE-WMI | Manufacturer detection, CCTK | Included by default in MDT/SCCM boot images. Dell's own WinPE guidance starts the `winmgmt` service before running cctk |
| WinPE-NetFx + WinPE-PowerShell | Running the script at all | Standard for script-driven task sequence steps |
| WinPE-MSI | **Only** the dynamic Dell Update Package extraction path (`msiexec /a`) | Not needed when CCTK is pre-staged or downloaded as a portable archive |
| Network + TLS | The dynamic downloads | The script enables TLS 1.2/1.3 on the ServicePointManager itself; no OS configuration needed |
| Proxy (optional) | Environments that require a proxy for internet access | The script resolves the proxy automatically: user WinINET proxy first, then the machine WinHTTP proxy, then direct. In WinPE/SYSTEM contexts there is normally no user proxy, so configure the WinHTTP proxy when one is required: `netsh winhttp set proxy proxy.example.com:8080 "<local>;*.example.com"` (run it as a task sequence step before this script) |

Dell Command | Configure 5.x needs **no HAPI driver installation step** in WinPE. Dell's own boot image integration script that ships inside the package simply copies the `X86_64` folder into the image, so a copied/extracted `cctk.exe` folder works as-is (requires the WMI service, which WinPE task sequence environments already run).

## Four ways to provide CCTK in WinPE

Pick one, in order of preference:

1. **Stage once from a full Windows operating system (recommended).** Run the script once from a full OS out of the same script folder (for example the deployment share). The binaries are staged into `Toolkit\Tools` and travel with the folder, so every WinPE execution finds them already cached and downloads nothing.
2. **Pre-stage cctk.exe in the boot image** (offline capable). Copy the extracted `Command Configure\X86_64` folder into the boot image (e.g. `X:\Command_Configure\X86_64`) as Dell's integration script does, or include it via an extra-files directory / task sequence package. The script finds it automatically when the folder is on the process `PATH`.
3. **Self hosted portable archive** (dynamic, no WinPE-MSI needed). Host a `.zip`/`.7z` of an extracted `Command Configure` tree on your content server and pass `-CCTKDownloadURL`. See [CCTK-Acquisition.md](CCTK-Acquisition.md) for the required archive layout.
4. **Direct Dell Update Package download** (fully dynamic, default). Works in WinPE **only when the boot image contains the WinPE-MSI optional component**, because expanding the MSI uses `msiexec /a`. Without it the script fails with a clear error that points at the options above.

ARM64 note: the portable `7zr.exe` is an x86 binary. A full ARM64 Windows installation runs it through x86 emulation, but ARM64 WinPE cannot, so options 3 (with a `.zip`, which needs no 7-Zip) and 4 are unavailable within ARM64 WinPE when a `.7z`/DUP must be extracted - use option 1 or 2 there. The staged `Toolkit\Tools\ARM64\CCTK` folder from an x64 staging run covers ARM64 devices via option 1.

## Task sequence step example

Run Command Line step (after a "Gather"/network is available, before the reboot that should HTTP boot):

```
powershell.exe -ExecutionPolicy Bypass -NonInteractive -NoProfile -NoLogo -File "%DEPLOYROOT%\Scripts\Invoke-HTTPBootBiosConfiguration\Invoke-HTTPBootBiosConfiguration.ps1" -BootURL "https://prod.ipxe.example.com/2PXE/boot/x64/snponly_x64.efi" -CCTKDownloadURL "https://contentserver.example.com/tools/CommandConfigurePortable.zip" -SetupPassword "%BIOSPWD%"
```

Notes:

- The whole repository folder (script + `Toolkit\`) must travel together; the script dot-sources `Toolkit\Toolkit.ps1` relative to itself.
- The script auto-elevates in a full OS; in WinPE everything already runs as SYSTEM, so it executes directly.
- The staging directory defaults to `%WINDIR%\Temp\HTTPBootBios`, which resolves to the RAM disk (`X:`) in WinPE. The DUP download plus extraction needs roughly 350 MB of scratch space - increase the WinPE scratch space to 512 MB, or prefer the much smaller portable archive (option 2), which needs about 50 MB.
- On non-Dell hardware the script logs a warning and exits successfully, so the same step can run unconditionally in a mixed fleet.
- Failure behavior: any CCTK error, download failure, or a post-apply verification mismatch fails the step (non-zero exit code) unless `-ContinueOnError` is specified.
