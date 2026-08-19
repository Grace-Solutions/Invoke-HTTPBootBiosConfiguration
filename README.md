# Invoke-HTTPBootBiosConfiguration

Configures the UEFI HTTP(s) boot BIOS settings on supported devices so that they can network boot directly from a web server, such as a [2Pint DeployR](https://2pintsoftware.com) instance secured with a Let's Encrypt certificate.

The script is fully dynamic: everything it needs (the BIOS configuration utility, the certificate authority root certificate, and the boot image digest) is downloaded and generated at execution time. Nothing is permanently installed onto the device, and the script runs in both a full Windows operating system and Windows PE (WinPE), which makes it suitable for MDT/SCCM task sequences.

A manufacturer switch statement selects the configuration method per device vendor so that additional manufacturers can be added over time.

| Manufacturer | Status | Method |
| --- | --- | --- |
| Dell | Implemented | Dell Command \| Configure (CCTK) |
| HP | Not implemented yet | - |
| Lenovo | Not implemented yet | - |

## How it works

**Tool staging (all manufacturers).** Before anything vendor specific runs, the `Invoke-ToolStaging` toolkit function stages the required binaries into `Toolkit\Tools` (`All`, `X86`, `X64`, `ARM64`), because they cannot be redistributed with this repository: the portable 7-Zip console executable (`7zr.exe`) goes to `All\7-Zip`, and Dell Command | Configure is downloaded (the Dell Update Package by default - the embedded 7-Zip payload is carved out by binary signature, extracted with `7zr.exe`, and the resulting MSI is expanded with an MSI administrative extraction), then placed into `X64\CCTK` and `ARM64\CCTK`. Once staged, the binaries travel with the script folder (for example on a deployment share), so repeat executions on any device use the cached bits without downloading anything. See [Docs/CCTK-Acquisition.md](Docs/CCTK-Acquisition.md).

Then, for Dell devices:

1. **Locate CCTK** - the staged `Toolkit\Tools\<architecture>\CCTK` folder first (the toolkit resolves `X86`, `X64`, or `ARM64` automatically), then the process path, then the standard installation directories.
2. **Determine the root certificate** - when `-RootCertificateURL` is not explicitly specified, the `Get-EndpointCertificateChain` toolkit function performs a direct TLS handshake against the boot endpoint (exactly what the firmware will do - no proxy), captures the presented certificate chain, exports it to PEM (the full chain is written to the staging directory), and embeds the chain's self-signed root into the profile. If the endpoint cannot be reached, it gracefully falls back to downloading `-RootCertificateURL` (Let's Encrypt "ISRG Root X1" by default). Dell BIOS certificate import requires RSA - non-RSA (e.g. ECDSA) certificates are still exported and embedded, with a warning.
3. **Determine the boot image digest** - the BIOS requires a non-empty SHA-256 digest in the profile (hardware verified: an empty digest is rejected with exit 157 "some or all fields missing"), so the boot image is downloaded and hashed - unless a precomputed value is supplied with `-BootImageDigest`, which places the value without downloading anything.
4. **Generate the HTTP boot profile XML** - built with an XmlDocument and written through an XmlWriter. See [Docs/HttpBootProfile-Reference.md](Docs/HttpBootProfile-Reference.md) for the document format and the hardware verified field constraints (single certificate only - the BIOS cert field is capped at 2047 characters, so a chain bundle cannot be embedded).
5. **Apply the BIOS configuration** by executing the following CCTK commands in order:

   | # | Command | Notes |
   | --- | --- | --- |
   | 1 | `cctk --Version` | Validates that the acquired executable runs |
   | 2 | `cctk --HttpsBoot=Enabled` | Enables the HTTPS boot BIOS feature |
   | 3 | `cctk --HttpsBootMode=ManualMode` | Sets the HTTPS boot mode to manual |
   | 4 | `cctk HttpBootProfile --Delete` | Deletes any existing profile first (exit code 150 "Profile Not Present" is accepted). Skippable with `-SkipProfileDeletion` |
   | 5 | `cctk HttpBootProfile --Set=<profile.xml>` | Applies the generated profile |
   | 6 | `cctk HttpBootProfile --Get` | Reads the profile back and verifies the configured URL |

   The existing profile is deleted before the new one is applied because updating only the URL within an existing profile has been observed to not always apply. When a BIOS setup password is supplied with `-SetupPassword`, it is appended to each modification command as `--ValSetupPwd=<password>` and the command lines are obfuscated within the log.

## Usage

```
# Basic usage (elevates automatically when required)
powershell.exe -ExecutionPolicy Bypass -NoProfile -NoLogo -File ".\Invoke-HTTPBootBiosConfiguration.ps1" -BootURL "https://prod.ipxe.example.com/2PXE/boot/x64/snponly_x64.efi"

# A URL that does not end with a file name gets "snponly_x64.efi" appended automatically (with or without a trailing slash)
powershell.exe -ExecutionPolicy Bypass -NoProfile -NoLogo -File ".\Invoke-HTTPBootBiosConfiguration.ps1" -BootURL "https://prod.ipxe.example.com/2PXE/boot/x64" -SetupPassword "MyBiosPassword"

# Windows PE with a self hosted portable CCTK archive
powershell.exe -ExecutionPolicy Bypass -NoProfile -NoLogo -File ".\Invoke-HTTPBootBiosConfiguration.ps1" -BootURL "https://prod.ipxe.example.com/2PXE/boot/x64/snponly_x64.efi" -CCTKDownloadURL "https://contentserver.example.com/tools/CommandConfigurePortable.zip"
```

`Invoke-HTTPBootBiosConfiguration.exe` is the bootstrapper that launches the identically named PowerShell script, which avoids PowerShell execution policy complexities when invoked from deployment tooling.

## Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `-BootURL` | (required) | Fully qualified HTTP(s) URL of the UEFI boot image, e.g. `https://prod.ipxe.example.com/2PXE/boot/x64/snponly_x64.efi`. When the URL does not end with a file name, `snponly_x64.efi` is appended automatically |
| `-RootCertificateURL` | Let's Encrypt ISRG Root X1 (`https://letsencrypt.org/certs/isrgrootx1.pem`) | PEM encoded CA root certificate the BIOS uses to validate the boot server TLS certificate. When NOT explicitly specified, the chain is fetched directly from the boot endpoint instead, and this URL is only the graceful fallback; specifying it skips the endpoint retrieval |
| `-CCTKDownloadURL` | Dell Command \| Configure 5.2.2 DUP on `dl.dell.com` | Source for the dynamic CCTK acquisition. Supports `.exe` (DUP), `.zip`, and `.7z` |
| `-SevenZipDownloadURL` | `https://www.7-zip.org/a/7zr.exe` | Portable 7-Zip console executable used for payload extraction |
| `-StagingDirectory` | `%WINDIR%\Temp\HTTPBootBios` | Working directory for downloads and extraction. Keep it short (MSI extraction fails on deep paths) |
| `-BootImageDigest` | (computed) | Precomputed SHA-256 of the boot image (64 hex chars), placed into the profile without downloading the boot image. When omitted, the boot image is downloaded and hashed. The BIOS enforces the digest at boot time - a stale value stops HTTP boot until the profile is re-applied |
| `-SetupPassword` | (none) | BIOS setup password, appended as `--ValSetupPwd=` on modification commands. Safe to supply fleet-wide: CCTK ignores the argument on devices with no setup password installed (verified on 5.2.2) |
| `-SkipProfileDeletion` | off | Do not delete the existing HTTP boot profile before applying |
| `-LogDirectory` | auto (toolkit) | Log folder override |
| `-ContinueOnError` | off | Ignore failures |

## Windows PE

The script detects WinPE automatically (toolkit `$IsWindowsPE`). The only WinPE specific requirement is for the dynamic DUP extraction path, which needs `msiexec.exe` (the **WinPE-MSI** optional component). The simplest way around it: run the script once from a full Windows operating system - the staged binaries land in `Toolkit\Tools` and travel with the script folder, so WinPE executions find them already cached. Alternatively pre-stage `cctk.exe` or use a self hosted portable archive. Details, boot image requirements, and task sequence examples: [Docs/WindowsPE-Guide.md](Docs/WindowsPE-Guide.md).

## Proxy support

All downloads automatically honor the proxy configuration of the environment - no parameters needed:

1. **Current user proxy (WinINET)** - used when the user has a static proxy enabled or an automatic configuration script (PAC) set. PAC evaluation and per-protocol proxy lists are honored.
2. **Machine WinHTTP proxy** - used when the user has none (typical when running as SYSTEM or in WinPE). This is the proxy set with `netsh winhttp set proxy`, including per-protocol lists (`https=` preferred) and the bypass list (`<local>` and wildcard entries are honored).
3. **No proxy** - when neither is configured, the proxy is explicitly disabled, which also avoids WebClient's automatic proxy detection delay.

Default credentials are supplied to authenticating proxies. The resolved proxy source and address are written to the log.

## Repository layout

```
Invoke-HTTPBootBiosConfiguration.ps1   The script
Invoke-HTTPBootBiosConfiguration.exe   Bootstrapper that launches the script
Toolkit\                               Shared toolkit (logging, error handling, process execution, tool staging)
Toolkit\Tools\{All,X86,X64,ARM64}\     Staged tool binaries (populated at execution time; git ignored because the bits cannot be redistributed)
Docs\                                  Detailed documentation
Content\                               Additional content placed here travels with the script
.claude\rules\                         PowerShell authoring guidelines for this repository
```

## Documentation

- [Docs/CCTK-Acquisition.md](Docs/CCTK-Acquisition.md) - how CCTK is acquired dynamically, how to host a portable archive, and how to update to a newer CCTK release
- [Docs/HttpBootProfile-Reference.md](Docs/HttpBootProfile-Reference.md) - HTTP boot profile XML format, CCTK command and exit code reference, troubleshooting
- [Docs/WindowsPE-Guide.md](Docs/WindowsPE-Guide.md) - running within Windows PE / task sequences

## Logging

A transcript is written to `%WINDIR%\Logs\Software\Invoke-HTTPBootBiosConfiguration` by default (task sequence aware: MDT/SCCM log paths are used automatically when a task sequence is running). All executed command lines, exit codes, and process output are logged. Command lines that contain the BIOS setup password are obfuscated.
