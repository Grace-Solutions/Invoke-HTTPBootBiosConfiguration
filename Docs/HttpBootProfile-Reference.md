# HTTP Boot Profile Reference (Dell)

This document describes the HTTP boot profile document the script generates, the CCTK commands used to apply it, and the troubleshooting knowledge gathered while building this automation.

## Generated profile document

The script writes `<StagingDirectory>\HttpBootProfile.xml` (UTF-8, no BOM):

```xml
<?xml version="1.0" encoding="utf-8"?>
<HttpBootProfile>
  <UrlInfo Type="https">
    <Url>https://prod.ipxe.example.com/2PXE/boot/x64/snponly_x64.efi</Url>
    <CertInfo Type="pem">
      <cert>-----BEGIN CERTIFICATE-----
... PEM content of the CA root certificate (ISRG Root X1 by default) ...
-----END CERTIFICATE-----
</cert>
    </CertInfo>
  </UrlInfo>
  <IntegrityInfo>
    <Algorithm>sha256</Algorithm>
    <Digest />
    <SignValue />
  </IntegrityInfo>
</HttpBootProfile>
```

The document is built with an `XmlDocument` and written through an `XmlWriter` (two-space indentation, UTF-8 without BOM).

Element notes (informed by the `BiosConnectProfile.xsd` schema that ships inside Dell Command | Configure):

| Element | Notes |
| --- | --- |
| `UrlInfo@Type` | `https` or `http`, derived from the boot URL scheme |
| `Url` | The full boot image URL |
| `CertInfo` | Optional per the schema. Only emitted for `https` URLs. `Type="pem"` is the only supported certificate encoding |
| `cert` | The PEM encoded CA **root** certificate of the chain that signs the boot server's TLS certificate. For Let's Encrypt this is **ISRG Root X1** - not the leaf and not the R10/R11 intermediates |
| `IntegrityInfo` | **Required** by the schema (it cannot be omitted). `Algorithm` supports `sha1` and `sha256` |
| `Digest` | Intentionally left empty (the schema allows an empty value). This script places configuration values only - it does not download or hash the boot image, so the boot image on the web server can change freely without invalidating the profile |
| `SignValue` | Left empty (unsigned profile) |

## CCTK command sequence

```
cctk --Version
cctk --HttpsBoot=Enabled            [--ValSetupPwd=<password>]
cctk --HttpsBootMode=ManualMode     [--ValSetupPwd=<password>]
cctk HttpBootProfile --Delete       [--ValSetupPwd=<password>]   (skippable)
cctk HttpBootProfile --Set=<path>\HttpBootProfile.xml [--ValSetupPwd=<password>]
cctk HttpBootProfile --Get
```

### Why delete before set

Updating only the URL inside an existing profile via `HttpBootProfile --Set` has been observed to **not always apply** - the BIOS keeps the old URL even though CCTK returns success. Deleting the profile first and applying the new one fresh avoids this. The script does this by default; `-SkipProfileDeletion` disables it if you want to test the in-place update behavior on a given BIOS release.

### Verification

After applying, the script runs `HttpBootProfile --Get` and asserts that the output contains the exact boot URL that was requested. If it does not, the script fails (unless `-ContinueOnError`), so a silently ignored profile surfaces as a task sequence error instead of a device that will not boot later.

## Relevant exit codes

CCTK exit codes are documented by Dell at <https://www.dell.com/support/kbdoc/en-us/000147084/dell-command-configure-error-codes>. The ones that matter here:

| Exit code | Meaning | Script handling |
| --- | --- | --- |
| 0 | Success | Accepted everywhere |
| 150 | Profile Not Present | Accepted for `HttpBootProfile --Delete` and returned by `--Get` when nothing is configured (verified empirically on 5.2.2) |
| 240-246 | Password related errors (wrong/required setup password) | Fails the script - check `-SetupPassword`. Note the asymmetry: a device WITH a setup password fails without the correct `-SetupPassword`, but supplying `-SetupPassword` on a device WITHOUT one is harmless - CCTK ignores `--ValSetupPwd` when no setup password is installed (verified on 5.2.2), so one fleet-wide command line works both ways |
| 119 | Setting not supported on this platform | Fails the script - the model may not support HTTPS boot |

## Troubleshooting

- **Profile applies but device does not boot**: confirm the boot URL actually serves the boot image (e.g. `snponly_x64.efi`), and confirm the certificate in the profile is the root of the server's actual chain (`openssl s_client -connect server:443 -showcerts`).
- **URL change did not take effect**: this is the delete-before-set issue above - re-run without `-SkipProfileDeletion`, or as a last resort clear it in the BIOS setup UI.
- **`--Set` returns a schema/parse error**: inspect the generated `HttpBootProfile.xml` in the staging directory; the full document is also written into the script log.
- **Certificate expiry**: the script logs the downloaded root certificate's subject, thumbprint, and expiration, and warns when it is expired. ISRG Root X1 is valid until 2035-06-04.
