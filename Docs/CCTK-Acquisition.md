# Dynamic CCTK Acquisition and Tool Staging

The script acquires Dell Command | Configure (CCTK) at execution time without permanently installing anything onto the device. This document describes the mechanism, how to host your own portable archive, and how to update to a newer CCTK release.

## Tool staging

Because the binaries cannot be redistributed with this repository, the generic `Invoke-ToolStaging` toolkit function ([Toolkit/Functions/Invoke-ToolStaging.ps1](../Toolkit/Functions/Invoke-ToolStaging.ps1)) stages them dynamically on every execution - **regardless of the device manufacturer** - into the toolkit tools directory:

```
Toolkit\Tools\All\7-Zip\7zr.exe    Portable 7-Zip console executable
Toolkit\Tools\X64\CCTK\            CCTK for x64 (from the package's X86_64 folder)
Toolkit\Tools\ARM64\CCTK\          CCTK for ARM64 (when present within the source)
Toolkit\Tools\X86\CCTK\            CCTK for x86 (when present within the source)
```

Each tool defines completion test paths; when they already exist, the tool is skipped entirely (a cache hit takes well under a second). Because the tools directory lives inside the script folder, **the staged bits travel with it** - stage once on a deployment share and every subsequent device (including WinPE) uses the cached bits without downloading anything. These folders are git ignored so the bits can never be committed.

The toolkit resolves the device architecture (`X86`, `X64`, or `ARM64`) automatically, and the script locates `cctk.exe` in this order:

1. `Toolkit\Tools\<architecture>\CCTK\cctk.exe` (then `Toolkit\Tools\X64\CCTK\cctk.exe` as a fallback)
2. `cctk.exe` resolvable from the process path (e.g. pre-staged within a boot image)
3. `%ProgramFiles%\Dell\Command Configure\X86_64\cctk.exe` / `%ProgramFiles(x86)%\Dell\Command Configure\X86_64\cctk.exe`

## The Dell Update Package extraction chain (default)

Dell does **not** publish a portable (non-MSI) build of Dell Command | Configure for Windows - the DUP executable wrapping an MSI is the only official distribution. The portable folder you get after extraction is fully reusable, however, which is why the script caches it in the staging directory and supports self hosted portable archives (below) for an MSI-free path that can be reused every time.

The default `-CCTKDownloadURL` points at the Dell Update Package (DUP) for Dell Command | Configure. A DUP cannot simply be unzipped - it is a portable executable (DUPFramework.exe) with a 7-Zip archive embedded inside it, and that archive contains an MSI whose CAB stores files under mangled MSI File-table names. The validated chain is:

```
DUP (.exe)                      Downloaded from dl.dell.com (requires a User-Agent header,
  |                             which the script always sends; anonymous requests are rejected)
  v
Embedded 7z payload             Carved out by scanning for the 7-Zip binary signature
  |                             37 7A BC AF 27 1C followed by format version bytes 00 04.
  |                             (The signature alone produces false positives inside the
  |                             executable code; the version bytes disambiguate.)
  v
CCTKPayload.7z                  Extracted with the portable 7-Zip console executable 7zr.exe
  |                             (~600 KB, downloaded from -SevenZipDownloadURL).
  |                             7-Zip exit code 1 (warning) is accepted: the carved file
  |                             contains a couple of trailing bytes after the archive end.
  v
Command_Configure.msi           Expanded with an MSI administrative extraction:
  |                             msiexec /a Command_Configure.msi TARGETDIR=<working dir> /qn
  |                             This produces the proper directory tree WITHOUT installing.
  v
Toolkit\Tools\X64\CCTK\         The X86_64 folder content, placed by the destination mapping
Toolkit\Tools\ARM64\CCTK\       The ARM64 folder content, from the same package
```

Notes:

- The MSI administrative extraction fails with MSI error 1320 ("path too long") when the target path is deep, because the extracted tree itself is several levels deep. This is why the default staging directory is the short `%WINDIR%\Temp\HTTPBootBios`.
- Dell Command | Configure 5.x no longer requires a separate HAPI driver installation. Dell's own WinPE integration script that ships inside the package (`X86_64\cctk_x86_64_winpe_11.bat`) simply copies the `X86_64` folder into the boot image; `cctk.exe` handles its BIOS interface at runtime. The portable extract therefore runs as-is in both a full OS and WinPE.
- The extracted tree also contains an `ARM64` variant; the script deliberately selects the `X86_64` executable.

## Hosting a portable archive instead (`.zip` / `.7z`)

For WinPE boot images without the WinPE-MSI optional component, or to avoid depending on Dell/7-Zip servers, host your own archive and point `-CCTKDownloadURL` at it.

**Archive layout requirement:** the staging destination mappings locate folders literally named `X86_64` (and optionally `ARM64` / `X86`) anywhere within the archive - the natural layout of an installed or administratively extracted `Command Configure` tree. Do not zip the already renamed `Toolkit\Tools\X64\CCTK` folder directly, because it no longer contains a folder named `X86_64`.

1. Install Dell Command | Configure on any machine (or perform an MSI administrative extraction) so that you have a `Command Configure` tree containing `X86_64` and `ARM64`.
2. Zip that tree:

   ```powershell
   Compress-Archive -Path "${Env:ProgramFiles(x86)}\Dell\Command Configure\*" -DestinationPath "CommandConfigurePortable.zip"
   ```
3. Host it on your content server and invoke the script with:

   ```
   -CCTKDownloadURL "https://contentserver.example.com/tools/CommandConfigurePortable.zip"
   ```

`.zip` archives are extracted with the built-in `System.IO.Compression` classes; `.7z` archives are extracted with the dynamically staged `7zr.exe`. A bare `.msi` URL is also supported and is expanded with an MSI administrative extraction.

## Updating to a newer CCTK release

The default pins Dell Command | Configure **5.2.2 A00** (released 2026-03-31, driver ID `F2V9N`):

- URL: `https://dl.dell.com/FOLDER14333137M/1/Dell-Command-Configure-Application_F2V9N_WIN64_5.2.2.292_A00.EXE`

To move to a newer release:

1. Open the Dell Command | Configure landing page: <https://www.dell.com/support/kbdoc/en-us/000178000/dell-command-configure>
2. Follow the link for the newest version to its driver details page and copy the direct `dl.dell.com` download URL.
3. Either pass it as `-CCTKDownloadURL`, or update the default value within the "Set default parameter values" region of the script.

The carve-and-extract chain is version independent (it keys off the 7-Zip signature and `*.msi`), so newer DUPs are expected to work unchanged.
