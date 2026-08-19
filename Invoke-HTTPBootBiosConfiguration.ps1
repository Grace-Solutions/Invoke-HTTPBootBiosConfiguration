#Requires -Version 5

<#
    .SYNOPSIS
    Configures the UEFI HTTP(s) boot BIOS settings on supported devices so that they can network boot directly from a web server, such as a 2Pint DeployR instance secured with a Let's Encrypt certificate.

    .DESCRIPTION
    Invoke-HTTPBootBiosConfiguration dynamically acquires everything it needs at execution time, builds the HTTP boot profile document, and applies the BIOS configuration by using the manufacturer specific BIOS configuration utility. A switch statement handles each device manufacturer so that additional manufacturers can be added over time. Dell is currently the only implemented manufacturer.

    Regardless of the device manufacturer, the required tool binaries are first staged into the toolkit tools directory (Toolkit\Tools\All, X86, X64, ARM64) by using the Invoke-ToolStaging toolkit function, because the binaries cannot be redistributed with this repository. The portable 7-Zip console executable is placed into "All\7-Zip", and Dell Command | Configure (CCTK) is downloaded (the Dell Update Package by default, or a self hosted .zip, .7z, or .msi), extracted, and placed into the architecture specific folders ("X64\CCTK", "ARM64\CCTK", and "X86\CCTK" when present within the source). Once staged, the binaries travel with the script folder (for example on a deployment share), so repeat executions on any device use the cached bits without downloading anything. No software is permanently installed onto the device.

    For Dell devices, the following operations are then performed by using CCTK:

      1. Locates cctk.exe from the staged toolkit tools directory (architecture specific first), the process path, or the standard installation directories.
      2. Determines the certificate authority root certificate that the BIOS uses to validate the TLS certificate presented by the HTTP(s) boot server. When a root certificate URL was not explicitly specified, the certificate chain is retrieved directly from the boot endpoint by using the Get-EndpointCertificateChain toolkit function (the full chain is exported to PEM format within the staging directory, and the root of the chain is embedded within the profile). When the endpoint retrieval fails, the root certificate is downloaded from the RootCertificateURL as a graceful fallback (the Let's Encrypt "ISRG Root X1" certificate by default).
      3. Determines the boot image digest. The BIOS requires a non-empty digest value within the profile integrity information (verified on hardware - an empty digest is rejected with "some or all fields missing"), so the SHA-256 digest of the boot image is computed by downloading it from the boot URL, unless a precomputed value is supplied by using the BootImageDigest parameter.
      4. Generates the HttpBootProfile XML document containing the boot URL, the root certificate, and the integrity information section.
      5. Executes the CCTK commands to enable HTTPS boot, set the HTTPS boot mode to manual, delete any existing HTTP boot profile (this avoids a known issue where updating the URL within an existing profile does not always apply), apply the new profile, and read the profile back to verify that the configured URL was applied.

    All downloads automatically honor the proxy configuration of the environment. The proxy configuration of the current user (a static WinINET proxy or an automatic configuration script) is preferred, followed by the machine WinHTTP proxy configuration (as set by "netsh winhttp set proxy"), and no proxy is used when neither is configured. Default credentials are supplied to authenticating proxies.

    The script supports execution within a full Windows operating system as well as within Windows PE (WinPE), which makes it suitable for MDT/SCCM task sequence usage. Within WinPE, the MSI administrative extraction requires the WinPE-MSI optional component. When that component is not available, either execute the script once from a full Windows operating system so that the staged binaries travel with the script folder, host a portable ZIP or 7z archive of the "Command Configure" folder and specify its URL by using the CCTKDownloadURL parameter, or pre-stage cctk.exe within the boot image.

    .PARAMETER BootURL
    Required. The fully qualified HTTP(s) URL of the UEFI boot image the BIOS will boot from. Example: https://prod.ipxe.example.com/2PXE/boot/x64/snponly_x64.efi. When the URL does not end with a file name (for example https://prod.ipxe.example.com/2PXE/boot/x64, with or without a trailing slash), the default boot image file name of "snponly_x64.efi" is appended automatically. Alias: URL, BURL.

    .PARAMETER RootCertificateURL
    Optional. The URL of the PEM encoded certificate authority root certificate that the BIOS uses to validate the TLS certificate presented by the HTTP(s) boot server. When this parameter is NOT explicitly specified, the certificate chain is retrieved directly from the boot endpoint instead, and this URL (the Let's Encrypt "ISRG Root X1" root certificate at https://letsencrypt.org/certs/isrgrootx1.pem by default) is only used as a graceful fallback when the endpoint retrieval fails. Explicitly specifying this parameter skips the endpoint retrieval entirely. Alias: RCURL.

    .PARAMETER CCTKDownloadURL
    Optional. The URL that the Dell Command | Configure content is downloaded from when cctk.exe cannot be located on the device. Supports a Dell Update Package executable (.exe), a ZIP archive (.zip), or a 7-Zip archive (.7z) containing a previously extracted portable "Command Configure" folder. Defaults to the Dell Command | Configure version 5.2.2 Dell Update Package hosted at dl.dell.com. Alias: CCTKURL.

    .PARAMETER SevenZipDownloadURL
    Optional. The URL that the portable 7-Zip console executable (7zr.exe) is downloaded from. It is used to extract the payload that is carved out of the Dell Update Package, as well as to extract .7z archives. Defaults to https://www.7-zip.org/a/7zr.exe. Alias: SZURL.

    .PARAMETER StagingDirectory
    Optional. The directory that downloaded and extracted content is staged within. Keep this path short, because the MSI administrative extraction can fail with "path too long" errors when the staging path is deep. Defaults to "$($Env:Windir)\Temp\HTTPBootBios". Alias: SD.

    .PARAMETER BootImageDigest
    Optional. A precomputed SHA-256 digest (64 hexadecimal characters) of the boot image, placed directly into the profile integrity information without downloading the boot image. When not specified, the boot image is downloaded from the boot URL and its digest is computed. The BIOS requires a non-empty digest value, and enforces it against the downloaded boot image at boot time - a stale digest stops the device from HTTP booting until the profile is re-applied. Alias: BID, Digest.

    .PARAMETER SetupPassword
    Optional. The BIOS setup (administrator) password. When specified, it is appended to each BIOS modification command by using the --ValSetupPwd argument, and the process command lines are obfuscated within the log. This parameter is safe to supply fleet wide: CCTK ignores the --ValSetupPwd argument on devices where no setup password is installed (verified on version 5.2.2), so the same command line works on both password protected and unprotected devices. When this parameter is omitted, the argument is not appended at all, which also works on unprotected devices. Alias: BIOSPassword, SP.

    .PARAMETER SkipProfileDeletion
    Optional. Skips the deletion of any existing HTTP boot profile before the new profile is applied. By default, the existing profile is deleted first, because updating only the URL within an existing profile has been observed to not always apply. Alias: SPD.

    .PARAMETER TaskSequenceVariables
    One or more task sequence variable(s) to retrieve during task sequence execution.
    If this parameter is not specified, all task sequence variable(s) will be stored into the variable 'TSVariableTable'.
    Any task sequence variables that are new or have been updated will be saved back to the task sequence engine for futher usage.

    .PARAMETER LogDirectory
    A valid folder path. If the folder does not exist, it will be created. This parameter can also be specified by the alias "LogPath".

    .PARAMETER ContinueOnError
    Ignore failures.

    .EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -NoLogo -File "%FolderPathContainingScript%\Invoke-HTTPBootBiosConfiguration.ps1" -BootURL "https://prod.ipxe.example.com/2PXE/boot/x64/snponly_x64.efi"

    .EXAMPLE
    #The boot URL does not end with a file name, so "snponly_x64.efi" is appended automatically.

    powershell.exe -ExecutionPolicy Bypass -NoProfile -NoLogo -File "%FolderPathContainingScript%\Invoke-HTTPBootBiosConfiguration.ps1" -BootURL "https://prod.ipxe.example.com/2PXE/boot/x64" -SetupPassword "MyBiosPassword"

    .EXAMPLE
    #Windows PE usage with a self hosted portable archive of the "Command Configure" folder (recommended when the boot image does not contain the WinPE-MSI optional component).

    powershell.exe -ExecutionPolicy Bypass -NoProfile -NoLogo -File "%FolderPathContainingScript%\Invoke-HTTPBootBiosConfiguration.ps1" -BootURL "https://prod.ipxe.example.com/2PXE/boot/x64/snponly_x64.efi" -CCTKDownloadURL "https://contentserver.example.com/tools/CommandConfigurePortable.zip"

    .EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NonInteractive -NoProfile -NoLogo -WindowStyle Hidden -Command "& '%FolderPathContainingScript%\Invoke-HTTPBootBiosConfiguration.ps1' -BootURL 'https://prod.ipxe.example.com/2PXE/boot/x64/snponly_x64.efi' -SkipProfileDeletion -ContinueOnError"

    .NOTES
    All Dell Command | Configure exit codes other than 0 indicate an error. Exit code 150 means "Profile Not Present" and is accepted for the profile deletion command, because a device that has never been configured will not have an existing profile.

    Dell BIOS HTTP boot profile certificate import requires RSA certificates. When the certificate that will be embedded does not use an RSA public key (for example ECDSA), a warning is logged and the certificate is still exported and embedded, however the BIOS may reject the profile with a "not RSA format" error.

    The following HTTP boot profile constraints were verified on hardware (CCTK 5.2.2): the certificate field accepts a maximum of 2047 characters, so only a single certificate (the root) can be embedded - a chain bundle does not fit and is rejected with exit code 150 ("field certificate max allowed characters are 2047"). The IntegrityInfo element and a non-empty digest value are mandatory - profiles without them are rejected with exit code 157 ("some or all fields missing").

    The default Dell Command | Configure download details (version 5.2.2 A00, released 2026-03-31) were retrieved from the Dell support site (driver ID F2V9N) and validated end to end.

    The BIOS setup password, when supplied, is passed to cctk.exe on its command line. The command lines are obfuscated within the script log, however any process auditing solution on the device may still record them.

    .LINK
    https://www.dell.com/support/kbdoc/en-us/000178000/dell-command-configure

    .LINK
    https://letsencrypt.org/certificates/

    .LINK
    https://2pintsoftware.com
#>

[CmdletBinding(SupportsShouldProcess=$True)]
  Param
    (
        [Parameter(Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [Alias('URL', 'BURL')]
        [System.URI]$BootURL,

        [Parameter(Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [Alias('RCURL')]
        [System.URI]$RootCertificateURL,

        [Parameter(Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [Alias('CCTKURL')]
        [System.URI]$CCTKDownloadURL,

        [Parameter(Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [Alias('SZURL')]
        [System.URI]$SevenZipDownloadURL,

        [Parameter(Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [Alias('SD')]
        [System.IO.DirectoryInfo]$StagingDirectory,

        [Parameter(Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [Alias('BID', 'Digest')]
        [String]$BootImageDigest,

        [Parameter(Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [Alias('BIOSPassword', 'SP')]
        [String]$SetupPassword,

        [Parameter(Mandatory=$False)]
        [Alias('SPD')]
        [Switch]$SkipProfileDeletion,

        [Parameter(Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [Alias('TSVars', 'TSVs')]
        [String[]]$TaskSequenceVariables,

        [Parameter(Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [Alias('TSVD', 'TSVDL')]
        [String[]]$TSVariableDecodeList,

        [Parameter(Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [Alias('LogDir', 'LogPath')]
        [System.IO.DirectoryInfo]$LogDirectory,

        [Parameter(Mandatory=$False)]
        [Switch]$ContinueOnError
    )

Function Test-ProcessElevationStatus
    {
        $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = New-Object -TypeName 'System.Security.Principal.WindowsPrincipal' -ArgumentList ($Identity)
        $Result = $Principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

        Write-Output -InputObject ($Result)
    }

Switch (Test-ProcessElevationStatus)
  {
      Default
        {
            Try
              {
                  #region Define Default Action Preferences
                    $Script:InformationPreference = 'Continue'
                    $Script:DebugPreference = 'SilentlyContinue'
                    $Script:ErrorActionPreference = 'Stop'
                    $Script:VerbosePreference = 'SilentlyContinue'
                    $Script:WarningPreference = 'Continue'
                    $Script:ConfirmPreference = 'None'
                    $Script:WhatIfPreference = $False
                  #endregion

                  #region Set the default exit code for the script (By default, the script will exit with an exit code of 0)
                    [System.Environment]::ExitCode = 0
                  #endregion

                  #region Initialize Toolkit (This operation loads functions, modules, and variables into the current session, so if you do not see a variable defined below, it is because it is defined in the Toolkit)
                    Try
                      {
                          [System.IO.FileInfo]$ToolkitScriptPath = "$([System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Definition))\Toolkit\Toolkit.ps1"

                          . "$($ToolkitScriptPath.FullName)" -CallingScriptInvocationInfo ($MyInvocation) -CallingScriptParameterSetName ($PSCmdlet.ParameterSetName)
                      }
                    Catch
                      {
                          [System.Environment]::ExitCode = 6000

                          Throw
                      }
                  #endregion

                  #region Set default parameter values
                    Switch ($True)
                      {
                          {([System.String]::IsNullOrEmpty($BootURL) -eq $True) -or ([System.String]::IsNullOrWhiteSpace($BootURL) -eq $True)}
                            {
                                $WriteLogMessage.Invoke(2, @("The `"BootURL`" parameter is required. Specify the fully qualified HTTP(s) URL of the UEFI boot image. Example: -BootURL `"https://prod.ipxe.example.com/2PXE/boot/x64/snponly_x64.efi`""))

                                Throw 'The "BootURL" parameter is required.'
                            }

                          {([System.String]::IsNullOrWhiteSpace([System.IO.Path]::GetFileName($BootURL.LocalPath)) -eq $True) -or ([System.IO.Path]::GetFileName($BootURL.LocalPath).Contains('.') -eq $False)}
                            {
                                #When the boot URL does not end with a file name (a last segment without an extension is treated as a folder), the default boot image file name is appended. Trailing slashes are handled either way.
                                [System.URI]$BootURL = "$($BootURL.AbsoluteUri.TrimEnd('/'))/snponly_x64.efi"

                                $WriteLogMessage.Invoke(0, @("The specified boot URL does not end with a file name. The default boot image file name of `"snponly_x64.efi`" was appended. [Boot URL: $($BootURL.AbsoluteUri)]"))
                            }

                          {([System.String]::IsNullOrEmpty($RootCertificateURL) -eq $True) -or ([System.String]::IsNullOrWhiteSpace($RootCertificateURL) -eq $True)}
                            {
                                [System.URI]$RootCertificateURL = 'https://letsencrypt.org/certs/isrgrootx1.pem'
                            }

                          {([System.String]::IsNullOrEmpty($CCTKDownloadURL) -eq $True) -or ([System.String]::IsNullOrWhiteSpace($CCTKDownloadURL) -eq $True)}
                            {
                                [System.URI]$CCTKDownloadURL = 'https://dl.dell.com/FOLDER14333137M/1/Dell-Command-Configure-Application_F2V9N_WIN64_5.2.2.292_A00.EXE'
                            }

                          {([System.String]::IsNullOrEmpty($SevenZipDownloadURL) -eq $True) -or ([System.String]::IsNullOrWhiteSpace($SevenZipDownloadURL) -eq $True)}
                            {
                                [System.URI]$SevenZipDownloadURL = 'https://www.7-zip.org/a/7zr.exe'
                            }

                          {([System.String]::IsNullOrEmpty($StagingDirectory) -eq $True) -or ([System.String]::IsNullOrWhiteSpace($StagingDirectory) -eq $True)}
                            {
                                [System.IO.DirectoryInfo]$StagingDirectory = [System.IO.Path]::Combine("$($Env:Windir)", 'Temp', 'HTTPBootBios')
                            }
                      }
                  #endregion

                  #region Perform Script Actions
                    #region Enforce modern TLS protocols for outbound web requests (Required for Windows PE and Windows Powershell 5.1)
                      $SecurityProtocolTypeList = New-Object -TypeName 'System.Collections.Generic.List[System.Int32]'
                        $SecurityProtocolTypeList.Add(3072)
                        $SecurityProtocolTypeList.Add(12288)

                      For ($SecurityProtocolTypeListIndex = 0; $SecurityProtocolTypeListIndex -lt $SecurityProtocolTypeList.Count; $SecurityProtocolTypeListIndex++)
                        {
                            $SecurityProtocolType = $SecurityProtocolTypeList[$SecurityProtocolTypeListIndex]

                            Try
                              {
                                  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor $SecurityProtocolType
                              }
                            Catch
                              {
                                  $WriteLogMessage.Invoke(1, @("The security protocol type value of $($SecurityProtocolType) is not supported on this platform and will not be enabled."))
                              }
                        }
                    #endregion

                    #region Determine the proxy configuration for outbound web requests
                      #The proxy is resolved once and applied to every download. Order of precedence: the proxy configuration of the current user (a static WinINET proxy or an automatic configuration script), then the machine WinHTTP proxy configuration, and finally no proxy when neither is configured.
                      $WebProxyConfiguration = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                        $WebProxyConfiguration.Source = 'None'
                        $WebProxyConfiguration.Proxy = $Null

                      Try
                        {
                            #region Check the proxy configuration of the current user (WinINET)
                              $UserProxySettings = Try {Get-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue} Catch {$Null}

                              Switch ($Null -ine $UserProxySettings)
                                {
                                    {($_ -eq $True)}
                                      {
                                          [Int32]$UserProxyEnable = Try {$UserProxySettings.GetValue('ProxyEnable', 0)} Catch {0}

                                          [String]$UserProxyServer = Try {"$($UserProxySettings.GetValue('ProxyServer', ''))"} Catch {[System.String]::Empty}

                                          [String]$UserProxyAutoConfigURL = Try {"$($UserProxySettings.GetValue('AutoConfigURL', ''))"} Catch {[System.String]::Empty}

                                          Switch ((($UserProxyEnable -eq 1) -and ([System.String]::IsNullOrWhiteSpace($UserProxyServer) -eq $False)) -or ([System.String]::IsNullOrWhiteSpace($UserProxyAutoConfigURL) -eq $False))
                                            {
                                                {($_ -eq $True)}
                                                  {
                                                      #GetSystemWebProxy() returns the WinINET proxy configuration of the current user, including automatic configuration script (PAC) evaluation and per protocol proxy lists.
                                                      $WebProxyConfiguration.Source = 'UserConfiguration'
                                                      $WebProxyConfiguration.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
                                                        $WebProxyConfiguration.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials

                                                      $WriteLogMessage.Invoke(0, @("The proxy configuration of the current user will be used for outbound web requests.", "Proxy Server: $($UserProxyServer)", "Automatic Configuration Script: $($UserProxyAutoConfigURL)"))
                                                  }
                                            }
                                      }
                                }
                            #endregion

                            #region Check the machine WinHTTP proxy configuration (When the current user does not have a proxy configured)
                              Switch ($WebProxyConfiguration.Source -ieq 'None')
                                {
                                    {($_ -eq $True)}
                                      {
                                          #The WinHttpSettings registry value is a binary structure: [DWORD signature] [DWORD unknown] [DWORD flags] [DWORD proxy server length] [proxy server (ANSI)] [DWORD bypass list length] [bypass list (ANSI)]. Bit 2 of the flags indicates that a proxy server is configured.
                                          $WinHttpConnectionSettings = Try {Get-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -ErrorAction SilentlyContinue} Catch {$Null}

                                          [System.Byte[]]$WinHttpSettingsValue = Try {$WinHttpConnectionSettings.GetValue('WinHttpSettings', $Null)} Catch {$Null}

                                          [String]$SystemProxyServer = [System.String]::Empty

                                          [String]$SystemProxyBypassList = [System.String]::Empty

                                          Switch (($Null -ine $WinHttpSettingsValue) -and ($WinHttpSettingsValue.Length -ge 16))
                                            {
                                                {($_ -eq $True)}
                                                  {
                                                      [Int32]$WinHttpProxyFlags = [System.BitConverter]::ToInt32($WinHttpSettingsValue, 8)

                                                      Switch (($WinHttpProxyFlags -band 2) -eq 2)
                                                        {
                                                            {($_ -eq $True)}
                                                              {
                                                                  [Int32]$WinHttpProxyServerLength = [System.BitConverter]::ToInt32($WinHttpSettingsValue, 12)

                                                                  Switch (($WinHttpProxyServerLength -gt 0) -and ((16 + $WinHttpProxyServerLength) -le $WinHttpSettingsValue.Length))
                                                                    {
                                                                        {($_ -eq $True)}
                                                                          {
                                                                              [String]$SystemProxyServer = [System.Text.Encoding]::ASCII.GetString($WinHttpSettingsValue, 16, $WinHttpProxyServerLength)

                                                                              [Int32]$WinHttpProxyBypassOffset = 16 + $WinHttpProxyServerLength

                                                                              Switch (($WinHttpProxyBypassOffset + 4) -le $WinHttpSettingsValue.Length)
                                                                                {
                                                                                    {($_ -eq $True)}
                                                                                      {
                                                                                          [Int32]$WinHttpProxyBypassLength = [System.BitConverter]::ToInt32($WinHttpSettingsValue, $WinHttpProxyBypassOffset)

                                                                                          Switch (($WinHttpProxyBypassLength -gt 0) -and (($WinHttpProxyBypassOffset + 4 + $WinHttpProxyBypassLength) -le $WinHttpSettingsValue.Length))
                                                                                            {
                                                                                                {($_ -eq $True)}
                                                                                                  {
                                                                                                      [String]$SystemProxyBypassList = [System.Text.Encoding]::ASCII.GetString($WinHttpSettingsValue, $WinHttpProxyBypassOffset + 4, $WinHttpProxyBypassLength)
                                                                                                  }
                                                                                            }
                                                                                      }
                                                                                }
                                                                          }
                                                                    }
                                                              }
                                                        }
                                                  }
                                            }

                                          Switch (([System.String]::IsNullOrEmpty($SystemProxyServer) -eq $False) -and ([System.String]::IsNullOrWhiteSpace($SystemProxyServer) -eq $False))
                                            {
                                                {($_ -eq $True)}
                                                  {
                                                      #A WinHTTP proxy server value can contain a single proxy or a per protocol list such as "http=proxya:80;https=proxyb:443". The https entry is preferred, followed by the http entry, followed by the first entry.
                                                      [String]$SelectedProxyServer = [System.String]::Empty

                                                      Switch ($SystemProxyServer.Contains('='))
                                                        {
                                                            {($_ -eq $True)}
                                                              {
                                                                  $SystemProxyServerEntryList = New-Object -TypeName 'System.Collections.Generic.List[System.String]'

                                                                  ForEach ($SystemProxyServerEntry In $SystemProxyServer.Split(';'))
                                                                    {
                                                                        $SystemProxyServerEntryList.Add($SystemProxyServerEntry.Trim())
                                                                    }

                                                                  $SystemProxyServerProtocolPrefixList = New-Object -TypeName 'System.Collections.Generic.List[System.String]'
                                                                    $SystemProxyServerProtocolPrefixList.Add('https=')
                                                                    $SystemProxyServerProtocolPrefixList.Add('http=')

                                                                  :SystemProxyServerProtocolPrefixLoop ForEach ($SystemProxyServerProtocolPrefix In $SystemProxyServerProtocolPrefixList)
                                                                    {
                                                                        ForEach ($SystemProxyServerEntry In $SystemProxyServerEntryList)
                                                                          {
                                                                              Switch ($SystemProxyServerEntry.ToLower().StartsWith($SystemProxyServerProtocolPrefix))
                                                                                {
                                                                                    {($_ -eq $True)}
                                                                                      {
                                                                                          [String]$SelectedProxyServer = $SystemProxyServerEntry.Substring($SystemProxyServerProtocolPrefix.Length)

                                                                                          Break SystemProxyServerProtocolPrefixLoop
                                                                                      }
                                                                                }
                                                                          }
                                                                    }

                                                                  Switch (([System.String]::IsNullOrEmpty($SelectedProxyServer) -eq $True) -or ([System.String]::IsNullOrWhiteSpace($SelectedProxyServer) -eq $True))
                                                                    {
                                                                        {($_ -eq $True)}
                                                                          {
                                                                              [String]$SelectedProxyServer = $SystemProxyServerEntryList[0].Split('=')[-1]
                                                                          }
                                                                    }
                                                              }

                                                            Default
                                                              {
                                                                  [String]$SelectedProxyServer = $SystemProxyServer.Trim()
                                                              }
                                                        }

                                                      Switch ($SelectedProxyServer -inotmatch '(^.*://.*$)')
                                                        {
                                                            {($_ -eq $True)}
                                                              {
                                                                  [String]$SelectedProxyServer = "http://$($SelectedProxyServer)"
                                                              }
                                                        }

                                                      $WebProxyObject = New-Object -TypeName 'System.Net.WebProxy' -ArgumentList @("$($SelectedProxyServer)")
                                                        $WebProxyObject.Credentials = [System.Net.CredentialCache]::DefaultCredentials

                                                      Switch (([System.String]::IsNullOrEmpty($SystemProxyBypassList) -eq $False) -and ([System.String]::IsNullOrWhiteSpace($SystemProxyBypassList) -eq $False))
                                                        {
                                                            {($_ -eq $True)}
                                                              {
                                                                  $SystemProxyBypassRegexList = New-Object -TypeName 'System.Collections.Generic.List[System.String]'

                                                                  ForEach ($SystemProxyBypassEntry In $SystemProxyBypassList.Split(';'))
                                                                    {
                                                                        [String]$SystemProxyBypassEntryValue = $SystemProxyBypassEntry.Trim()

                                                                        Switch ($SystemProxyBypassEntryValue)
                                                                          {
                                                                              {($_ -ieq '<local>')}
                                                                                {
                                                                                    $WebProxyObject.BypassProxyOnLocal = $True
                                                                                }

                                                                              {([System.String]::IsNullOrWhiteSpace($_) -eq $False) -and ($_ -ine '<local>')}
                                                                                {
                                                                                    $SystemProxyBypassRegexList.Add([Regex]::Escape($SystemProxyBypassEntryValue).Replace('\*', '.*'))
                                                                                }
                                                                          }
                                                                    }

                                                                  Switch ($SystemProxyBypassRegexList.Count -gt 0)
                                                                    {
                                                                        {($_ -eq $True)}
                                                                          {
                                                                              $WebProxyObject.BypassList = $SystemProxyBypassRegexList.ToArray()
                                                                          }
                                                                    }
                                                              }
                                                        }

                                                      $WebProxyConfiguration.Source = 'SystemConfiguration'
                                                      $WebProxyConfiguration.Proxy = $WebProxyObject

                                                      $WriteLogMessage.Invoke(0, @("The machine WinHTTP proxy configuration will be used for outbound web requests.", "Proxy Server: $($SelectedProxyServer)", "Proxy Bypass List: $($SystemProxyBypassList)"))
                                                  }
                                            }
                                      }
                                }
                            #endregion
                        }
                      Catch
                        {
                            $WebProxyConfiguration.Source = 'None'
                            $WebProxyConfiguration.Proxy = $Null

                            $WriteLogMessage.Invoke(2, @("The proxy configuration could not be determined. Outbound web requests will be made without a proxy.", "Message: $($_.Exception.Message)"))
                        }

                      Switch ($WebProxyConfiguration.Source -ieq 'None')
                        {
                            {($_ -eq $True)}
                              {
                                  $WriteLogMessage.Invoke(0, @("A proxy is not configured for the current user or the machine. Outbound web requests will be made without a proxy."))
                              }
                        }
                    #endregion

                    #region Define reusable scriptblocks
                      #The Dell download site (dl.dell.com) rejects requests that do not contain a user agent header, so one is always added.
                      [ScriptBlock]$DownloadFile = {
                                                        Param
                                                          (
                                                              [System.URI]$SourceURL,
                                                              [System.IO.FileInfo]$DestinationPath
                                                          )

                                                        $WriteLogMessage.Invoke(0, @("Attempting to download `"$($SourceURL.AbsoluteUri)`" to `"$($DestinationPath.FullName)`". Please Wait..."))

                                                        Switch ([System.IO.Directory]::Exists($DestinationPath.Directory.FullName))
                                                          {
                                                              {($_ -eq $False)}
                                                                {
                                                                    $Null = [System.IO.Directory]::CreateDirectory($DestinationPath.Directory.FullName)
                                                                }
                                                          }

                                                        $WebClient = New-Object -TypeName 'System.Net.WebClient'

                                                        Try
                                                          {
                                                              $WebClient.UseDefaultCredentials = $True

                                                              #Apply the resolved proxy configuration. Explicitly assigning a null proxy disables the default automatic proxy detection, which makes the "no proxy" case deterministic and avoids its detection delay.
                                                              Switch ($Null -ine $WebProxyConfiguration.Proxy)
                                                                {
                                                                    {($_ -eq $True)}
                                                                      {
                                                                          $WebClient.Proxy = $WebProxyConfiguration.Proxy
                                                                      }

                                                                    Default
                                                                      {
                                                                          $WebClient.Proxy = $Null
                                                                      }
                                                                }

                                                              $Null = $WebClient.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) HTTPBootBiosConfiguration')

                                                              $Null = $WebClient.DownloadFile($SourceURL.AbsoluteUri, $DestinationPath.FullName)

                                                              $WriteLogMessage.Invoke(0, @("The download completed successfully. [Size: $([System.Math]::Round((Get-Item -Path $DestinationPath.FullName).Length / 1MB, 2)) MB]"))
                                                          }
                                                        Finally
                                                          {
                                                              $Null = $WebClient.Dispose()
                                                          }
                                                    }
                    #endregion

                    #region Create the staging directory
                      Switch ([System.IO.Directory]::Exists($StagingDirectory.FullName))
                        {
                            {($_ -eq $False)}
                              {
                                  $WriteLogMessage.Invoke(0, @("Attempting to create the staging directory `"$($StagingDirectory.FullName)`". Please Wait..."))

                                  $Null = [System.IO.Directory]::CreateDirectory($StagingDirectory.FullName)
                              }
                        }
                    #endregion

                    #region Determine the device manufacturer
                      $DeviceManufacturerCandidateList = New-Object -TypeName 'System.Collections.Generic.List[System.String]'
                        $DeviceManufacturerCandidateList.Add("$($MSSystemInformation.SystemManufacturer)")
                        $DeviceManufacturerCandidateList.Add("$($ComputerSystem.Manufacturer)")

                      [String]$DeviceManufacturer = [System.String]::Empty

                      :DeviceManufacturerCandidateLoop For ($DeviceManufacturerCandidateListIndex = 0; $DeviceManufacturerCandidateListIndex -lt $DeviceManufacturerCandidateList.Count; $DeviceManufacturerCandidateListIndex++)
                        {
                            $DeviceManufacturerCandidate = "$($DeviceManufacturerCandidateList[$DeviceManufacturerCandidateListIndex])".Trim()

                            Switch (([System.String]::IsNullOrEmpty($DeviceManufacturerCandidate) -eq $False) -and ([System.String]::IsNullOrWhiteSpace($DeviceManufacturerCandidate) -eq $False))
                              {
                                  {($_ -eq $True)}
                                    {
                                        [String]$DeviceManufacturer = $DeviceManufacturerCandidate

                                        Break DeviceManufacturerCandidateLoop
                                    }
                              }
                        }

                      $WriteLogMessage.Invoke(0, @("Device Manufacturer: $($DeviceManufacturer)", "Is Windows PE: $($IsWindowsPE)", "Boot URL: $($BootURL.AbsoluteUri)"))
                    #endregion

                    #region Stage the required tools into the toolkit tools directory
                      #The tool binaries cannot be redistributed with this repository, so they are staged dynamically regardless of the device manufacturer. Once staged, the binaries travel with the script folder (for example on a deployment share), so repeat executions on any device use the cached bits without downloading anything.
                      $ToolStagingList = New-Object -TypeName 'System.Collections.Generic.List[System.Collections.IDictionary]'

                      $ToolDefinition = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                        $ToolDefinition.Enabled = $True
                        $ToolDefinition.Name = 'SevenZip'
                        $ToolDefinition.Type = 'RawFile'
                        $ToolDefinition.DownloadURL = $SevenZipDownloadURL
                        $ToolDefinition.DestinationMappingTable = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                          $ToolDefinition.DestinationMappingTable['.'] = [System.IO.Path]::Combine('All', '7-Zip', '7zr.exe')
                        $ToolDefinition.CompletionTestPathList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                          $ToolDefinition.CompletionTestPathList.Add([System.IO.Path]::Combine('All', '7-Zip', '7zr.exe'))
                      $ToolStagingList.Add($ToolDefinition)

                      #The CCTK tool type is derived from the download URL extension, so that a self hosted portable archive (.zip or .7z) or a bare MSI can be specified instead of the Dell Update Package (.exe).
                      Switch ([System.IO.Path]::GetExtension($CCTKDownloadURL.LocalPath).ToLower())
                        {
                            {($_ -iin @('.zip', '.7z'))}
                              {
                                  [String]$CCTKToolType = 'Archive'
                              }

                            {($_ -iin @('.msi'))}
                              {
                                  [String]$CCTKToolType = 'MSI'
                              }

                            Default
                              {
                                  [String]$CCTKToolType = 'DellUpdatePackage'
                              }
                        }

                      $ToolDefinition = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                        $ToolDefinition.Enabled = $True
                        $ToolDefinition.Name = 'CCTK'
                        $ToolDefinition.Type = $CCTKToolType
                        $ToolDefinition.DownloadURL = $CCTKDownloadURL
                        $ToolDefinition.DestinationMappingTable = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                          $ToolDefinition.DestinationMappingTable['X86_64'] = [System.IO.Path]::Combine('X64', 'CCTK')
                          $ToolDefinition.DestinationMappingTable['ARM64'] = [System.IO.Path]::Combine('ARM64', 'CCTK')
                          $ToolDefinition.DestinationMappingTable['X86'] = [System.IO.Path]::Combine('X86', 'CCTK')
                        $ToolDefinition.CompletionTestPathList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                          $ToolDefinition.CompletionTestPathList.Add([System.IO.Path]::Combine('X64', 'CCTK', 'cctk.exe'))
                          $ToolDefinition.CompletionTestPathList.Add([System.IO.Path]::Combine('ARM64', 'CCTK', 'cctk.exe'))
                          $ToolDefinition.CompletionTestPathList.Add([System.IO.Path]::Combine('X86', 'CCTK', 'cctk.exe'))
                      $ToolStagingList.Add($ToolDefinition)

                      $InvokeToolStagingParameters = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                        $InvokeToolStagingParameters.ToolList = $ToolStagingList.ToArray()
                        $InvokeToolStagingParameters.ToolsDirectory = $ToolsDirectory
                        $InvokeToolStagingParameters.StagingDirectory = [System.IO.DirectoryInfo][System.IO.Path]::Combine("$($StagingDirectory.FullName)", 'Tools')

                        Switch ($Null -ine $WebProxyConfiguration.Proxy)
                          {
                              {($_ -eq $True)}
                                {
                                    $InvokeToolStagingParameters.WebProxy = $WebProxyConfiguration.Proxy
                                }
                          }

                        $InvokeToolStagingParameters.ContinueOnError = $True
                        $InvokeToolStagingParameters.Verbose = $True

                      $InvokeToolStagingResult = Invoke-ToolStaging @InvokeToolStagingParameters
                    #endregion

                    #region Configure the HTTP(s) boot BIOS settings based on the device manufacturer
                      :DeviceManufacturerSwitch Switch -Regex ($DeviceManufacturer)
                        {
                            '(^.*Dell.*$)'
                              {
                                  $WriteLogMessage.Invoke(0, @("The device manufacturer `"$($DeviceManufacturer)`" is supported. The HTTP(s) boot BIOS configuration will be performed by using Dell Command | Configure (CCTK)."))

                                  #region Locate the CCTK executable
                                    #The staged toolkit tools directory is preferred (architecture specific first), followed by the process path, followed by the standard installation directories.
                                    $CCTKExecutablePath = $Null

                                    $CCTKCandidatePathList = New-Object -TypeName 'System.Collections.Generic.List[System.String]'
                                      $CCTKCandidatePathList.Add([System.IO.Path]::Combine("$($ToolsDirectory_OSArchSpecific.FullName)", 'CCTK', 'cctk.exe'))
                                      $CCTKCandidatePathList.Add([System.IO.Path]::Combine("$($ToolsDirectory.FullName)", 'X64', 'CCTK', 'cctk.exe'))

                                    $CCTKCommandObject = Try {Get-Command -Name 'cctk.exe' -ErrorAction SilentlyContinue} Catch {$Null}

                                    Switch ($Null -ine $CCTKCommandObject)
                                      {
                                          {($_ -eq $True)}
                                            {
                                                $CCTKCandidatePathList.Add("$($CCTKCommandObject.Path)")
                                            }
                                      }

                                    Switch ($True)
                                      {
                                          {([System.String]::IsNullOrEmpty("$($Env:ProgramFiles)") -eq $False)}
                                            {
                                                $CCTKCandidatePathList.Add([System.IO.Path]::Combine("$($Env:ProgramFiles)", 'Dell', 'Command Configure', 'X86_64', 'cctk.exe'))
                                            }

                                          {([System.String]::IsNullOrEmpty("$(${Env:ProgramFiles(x86)})") -eq $False)}
                                            {
                                                $CCTKCandidatePathList.Add([System.IO.Path]::Combine("$(${Env:ProgramFiles(x86)})", 'Dell', 'Command Configure', 'X86_64', 'cctk.exe'))
                                            }
                                      }

                                    :CCTKCandidatePathLoop For ($CCTKCandidatePathListIndex = 0; $CCTKCandidatePathListIndex -lt $CCTKCandidatePathList.Count; $CCTKCandidatePathListIndex++)
                                      {
                                          $CCTKCandidatePath = $CCTKCandidatePathList[$CCTKCandidatePathListIndex]

                                          Switch ([System.IO.File]::Exists($CCTKCandidatePath))
                                            {
                                                {($_ -eq $True)}
                                                  {
                                                      [System.IO.FileInfo]$CCTKExecutablePath = $CCTKCandidatePath

                                                      $WriteLogMessage.Invoke(0, @("A CCTK executable was located at `"$($CCTKExecutablePath.FullName)`"."))

                                                      Break CCTKCandidatePathLoop
                                                  }

                                                Default
                                                  {
                                                      $WriteLogMessage.Invoke(1, @("A CCTK executable does not exist at `"$($CCTKCandidatePath)`"."))
                                                  }
                                            }
                                      }

                                    Switch ($Null -ieq $CCTKExecutablePath)
                                      {
                                          {($_ -eq $True)}
                                            {
                                                Throw 'A CCTK executable could not be located even after the tool staging operation. Review the tool staging warnings within the log. Within Windows PE without the WinPE-MSI optional component, either execute the script once from a full Windows operating system so that the staged binaries travel with the script folder, or specify a CCTKDownloadURL that points to a ZIP or 7z archive of a previously extracted portable "Command Configure" folder.'
                                            }
                                      }
                                  #endregion

                                  #region Determine the certificate authority root certificate (Only required for HTTPS boot URLs)
                                    [String]$RootCertificateContent = [System.String]::Empty

                                    Switch ($BootURL.Scheme -ieq 'https')
                                      {
                                          {($_ -eq $True)}
                                            {
                                                #region Retrieve the certificate chain directly from the boot endpoint (When a root certificate URL was not explicitly specified)
                                                  Switch ($PSBoundParameters.ContainsKey('RootCertificateURL'))
                                                    {
                                                        {($_ -eq $False)}
                                                          {
                                                              $WriteLogMessage.Invoke(0, @("A root certificate URL was not explicitly specified. Attempting to retrieve the certificate chain directly from the boot endpoint. Please Wait..."))

                                                              #The endpoint probe is always made directly (never through a proxy), because the BIOS HTTP(s) boot feature contacts the endpoint directly as well.
                                                              $GetEndpointCertificateChainParameters = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                                                $GetEndpointCertificateChainParameters.URL = $BootURL
                                                                $GetEndpointCertificateChainParameters.ExportPath = [System.IO.FileInfo][System.IO.Path]::Combine("$($StagingDirectory.FullName)", 'BootEndpointCertificateChain.pem')
                                                                $GetEndpointCertificateChainParameters.ContinueOnError = $True
                                                                $GetEndpointCertificateChainParameters.Verbose = $True

                                                              $GetEndpointCertificateChainResult = Get-EndpointCertificateChain @GetEndpointCertificateChainParameters

                                                              Switch (($GetEndpointCertificateChainResult.Succeeded -eq $True) -and ($Null -ine $GetEndpointCertificateChainResult.RootCertificate))
                                                                {
                                                                    {($_ -eq $True)}
                                                                      {
                                                                          [String]$RootCertificateContent = "$($GetEndpointCertificateChainResult.RootCertificate.PEMContent)".Trim()

                                                                          $WriteLogMessage.Invoke(0, @("The root certificate retrieved from the boot endpoint will be embedded within the HTTP boot profile.", "Subject: $($GetEndpointCertificateChainResult.RootCertificate.Subject)", "Key Algorithm: $($GetEndpointCertificateChainResult.RootCertificate.KeyAlgorithm)", "Thumbprint: $($GetEndpointCertificateChainResult.RootCertificate.Thumbprint)"))
                                                                      }

                                                                    Default
                                                                      {
                                                                          $WriteLogMessage.Invoke(2, @("The certificate chain could not be retrieved from the boot endpoint. Falling back to downloading the root certificate from `"$($RootCertificateURL.AbsoluteUri)`"."))
                                                                      }
                                                                }
                                                          }
                                                    }
                                                #endregion

                                                #region Download the root certificate (When it was not retrieved from the boot endpoint)
                                                  Switch (([System.String]::IsNullOrEmpty($RootCertificateContent) -eq $True) -or ([System.String]::IsNullOrWhiteSpace($RootCertificateContent) -eq $True))
                                                    {
                                                        {($_ -eq $True)}
                                                          {
                                                              [System.IO.FileInfo]$RootCertificatePath = [System.IO.Path]::Combine("$($StagingDirectory.FullName)", 'RootCertificate.pem')

                                                              $Null = $DownloadFile.InvokeReturnAsIs($RootCertificateURL, $RootCertificatePath)

                                                              [String]$RootCertificateContent = [System.IO.File]::ReadAllText($RootCertificatePath.FullName).Trim()

                                                              Switch ($RootCertificateContent -imatch '(?s)(^.*-----BEGIN CERTIFICATE-----.*-----END CERTIFICATE-----.*$)')
                                                                {
                                                                    {($_ -eq $False)}
                                                                      {
                                                                          Throw "The content downloaded from `"$($RootCertificateURL.AbsoluteUri)`" does not appear to be a PEM encoded certificate."
                                                                      }
                                                                }

                                                              Try
                                                                {
                                                                    $RootCertificateObject = New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Certificate2' -ArgumentList @("$($RootCertificatePath.FullName)")

                                                                    $WriteLogMessage.Invoke(0, @("Root Certificate Subject: $($RootCertificateObject.Subject)", "Root Certificate Thumbprint: $($RootCertificateObject.Thumbprint)", "Root Certificate Expiration: $($RootCertificateObject.NotAfter.ToString('o'))"))

                                                                    Switch ($True)
                                                                      {
                                                                          {($RootCertificateObject.PublicKey.Oid.Value -ine '1.2.840.113549.1.1.1')}
                                                                            {
                                                                                $WriteLogMessage.Invoke(2, @("The root certificate downloaded from `"$($RootCertificateURL.AbsoluteUri)`" does not use an RSA public key. Dell BIOS HTTP boot profile certificate import requires RSA certificates, so the BIOS may reject this certificate with a `"not RSA format`" error. The certificate will still be embedded."))
                                                                            }

                                                                          {($RootCertificateObject.NotAfter -lt (Get-Date))}
                                                                            {
                                                                                $WriteLogMessage.Invoke(2, @("The root certificate downloaded from `"$($RootCertificateURL.AbsoluteUri)`" has expired. The BIOS may not be able to validate the HTTP(s) boot server."))
                                                                            }
                                                                      }
                                                                }
                                                              Catch
                                                                {
                                                                    $WriteLogMessage.Invoke(2, @("The downloaded root certificate could not be parsed for informational logging purposes. The certificate content will still be embedded within the HTTP boot profile.", "Message: $($_.Exception.Message)"))
                                                                }
                                                          }
                                                    }
                                                #endregion
                                            }

                                          Default
                                            {
                                                $WriteLogMessage.Invoke(0, @("The boot URL scheme is `"$($BootURL.Scheme)`". A certificate authority root certificate is not required and will not be included within the HTTP boot profile."))
                                            }
                                      }
                                  #endregion

                                  #region Determine the boot image digest (The BIOS requires a non-empty digest value)
                                    #Verified on hardware: applying a profile with an empty digest, or without the IntegrityInfo element entirely, fails with CCTK exit code 157 ("some or all fields missing"). A digest value is therefore mandatory. It is computed from the boot image by default, or placed directly when the BootImageDigest parameter is specified.
                                    Switch (([System.String]::IsNullOrEmpty($BootImageDigest) -eq $False) -and ([System.String]::IsNullOrWhiteSpace($BootImageDigest) -eq $False))
                                      {
                                          {($_ -eq $True)}
                                            {
                                                [String]$BootImageDigest = $BootImageDigest.Trim().ToLower()

                                                $WriteLogMessage.Invoke(0, @("The specified boot image digest will be placed within the HTTP boot profile without downloading the boot image. [Digest: $($BootImageDigest)]"))

                                                Switch ($BootImageDigest -inotmatch '(^[0-9a-f]{64}$)')
                                                  {
                                                      {($_ -eq $True)}
                                                        {
                                                            $WriteLogMessage.Invoke(2, @("The specified boot image digest does not appear to be a valid SHA-256 value (64 hexadecimal characters). The BIOS may reject the profile."))
                                                        }
                                                  }
                                            }

                                          Default
                                            {
                                                [String]$BootImageFileName = [System.IO.Path]::GetFileName($BootURL.LocalPath)

                                                [System.IO.FileInfo]$BootImagePath = [System.IO.Path]::Combine("$($StagingDirectory.FullName)", $BootImageFileName)

                                                $Null = $DownloadFile.InvokeReturnAsIs($BootURL, $BootImagePath)

                                                [String]$BootImageDigest = (Get-FileHash -Path ($BootImagePath.FullName) -Algorithm SHA256).Hash.ToLower()

                                                $WriteLogMessage.Invoke(0, @("Boot Image Digest (SHA-256): $($BootImageDigest)"))
                                            }
                                      }
                                  #endregion

                                  #region Generate the HTTP boot profile document
                                    #The document is built with an XmlDocument and written through an XmlWriter.
                                    #Verified on hardware: the BIOS certificate field accepts a maximum of 2047 characters, so only a single certificate (the root) can be embedded - a multiple certificate bundle does not fit and is rejected by CCTK with "field certificate max allowed characters are 2047".
                                    Switch (([System.String]::IsNullOrWhiteSpace($RootCertificateContent) -eq $False) -and ($RootCertificateContent.Length -gt 2047))
                                      {
                                          {($_ -eq $True)}
                                            {
                                                $WriteLogMessage.Invoke(2, @("The certificate content is $($RootCertificateContent.Length) characters long, which exceeds the BIOS certificate field maximum of 2047 characters. The profile application will likely fail."))
                                            }
                                      }

                                    [System.IO.FileInfo]$HttpBootProfilePath = [System.IO.Path]::Combine("$($StagingDirectory.FullName)", 'HttpBootProfile.xml')

                                    $HttpBootProfileDocument = New-Object -TypeName 'System.Xml.XmlDocument'

                                    $Null = $HttpBootProfileDocument.AppendChild($HttpBootProfileDocument.CreateXmlDeclaration('1.0', 'utf-8', $Null))

                                    $HttpBootProfileElement = $HttpBootProfileDocument.CreateElement('HttpBootProfile')

                                    $Null = $HttpBootProfileDocument.AppendChild($HttpBootProfileElement)

                                    $UrlInfoElement = $HttpBootProfileDocument.CreateElement('UrlInfo')
                                      $Null = $UrlInfoElement.SetAttribute('Type', "$($BootURL.Scheme.ToLower())")

                                    $Null = $HttpBootProfileElement.AppendChild($UrlInfoElement)

                                    $UrlElement = $HttpBootProfileDocument.CreateElement('Url')
                                      $UrlElement.InnerText = "$($BootURL.AbsoluteUri)"

                                    $Null = $UrlInfoElement.AppendChild($UrlElement)

                                    Switch (([System.String]::IsNullOrEmpty($RootCertificateContent) -eq $False) -and ([System.String]::IsNullOrWhiteSpace($RootCertificateContent) -eq $False))
                                      {
                                          {($_ -eq $True)}
                                            {
                                                $CertInfoElement = $HttpBootProfileDocument.CreateElement('CertInfo')
                                                  $Null = $CertInfoElement.SetAttribute('Type', 'pem')

                                                $Null = $UrlInfoElement.AppendChild($CertInfoElement)

                                                #The PEM content ends with a line break so that the closing tag begins on its own line, which matches the profile format that the BIOS accepts.
                                                $CertElement = $HttpBootProfileDocument.CreateElement('cert')
                                                  $CertElement.InnerText = "$($RootCertificateContent)`n"

                                                $Null = $CertInfoElement.AppendChild($CertElement)
                                            }
                                      }

                                    $IntegrityInfoElement = $HttpBootProfileDocument.CreateElement('IntegrityInfo')

                                    $Null = $HttpBootProfileElement.AppendChild($IntegrityInfoElement)

                                    $AlgorithmElement = $HttpBootProfileDocument.CreateElement('Algorithm')
                                      $AlgorithmElement.InnerText = 'sha256'

                                    $Null = $IntegrityInfoElement.AppendChild($AlgorithmElement)

                                    $DigestElement = $HttpBootProfileDocument.CreateElement('Digest')
                                      $DigestElement.InnerText = "$($BootImageDigest)"

                                    $Null = $IntegrityInfoElement.AppendChild($DigestElement)

                                    $SignValueElement = $HttpBootProfileDocument.CreateElement('SignValue')

                                    $Null = $IntegrityInfoElement.AppendChild($SignValueElement)

                                    $WriteLogMessage.Invoke(0, @("Attempting to write the HTTP boot profile document to `"$($HttpBootProfilePath.FullName)`". Please Wait..."))

                                    $XmlWriterSettings = New-Object -TypeName 'System.Xml.XmlWriterSettings'
                                      $XmlWriterSettings.Indent = $True
                                      $XmlWriterSettings.IndentChars = '  '
                                      $XmlWriterSettings.Encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($False)

                                    $HttpBootProfileXmlWriter = [System.Xml.XmlWriter]::Create("$($HttpBootProfilePath.FullName)", $XmlWriterSettings)

                                    Try
                                      {
                                          $Null = $HttpBootProfileDocument.Save($HttpBootProfileXmlWriter)
                                      }
                                    Finally
                                      {
                                          $Null = $HttpBootProfileXmlWriter.Close()
                                      }

                                    $WriteLogMessage.Invoke(0, @("HTTP Boot Profile Content:", "$([System.IO.File]::ReadAllText($HttpBootProfilePath.FullName))"))
                                  #endregion

                                  #region Define the ordered CCTK command list
                                    #A CCTK exit code of 150 means "Profile Not Present" and is acceptable for the profile deletion command, because a device that has never been configured will not have an existing profile.
                                    $CCTKCommandList = New-Object -TypeName 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'

                                    $CCTKCommandProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                      $CCTKCommandProperties.CommandID = 'DisplayVersion'
                                      $CCTKCommandProperties.Enabled = $True
                                      $CCTKCommandProperties.Description = 'Display the Dell Command | Configure version information'
                                      $CCTKCommandProperties.ArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.ArgumentList.Add('--Version')
                                      $CCTKCommandProperties.AcceptableExitCodeList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.AcceptableExitCodeList.Add('0')
                                      $CCTKCommandProperties.AppendSetupPassword = $False
                                    $CCTKCommandList.Add($CCTKCommandProperties)

                                    $CCTKCommandProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                      $CCTKCommandProperties.CommandID = 'EnableHttpsBoot'
                                      $CCTKCommandProperties.Enabled = $True
                                      $CCTKCommandProperties.Description = 'Enable the HTTPS boot BIOS feature'
                                      $CCTKCommandProperties.ArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.ArgumentList.Add('--HttpsBoot=Enabled')
                                      $CCTKCommandProperties.AcceptableExitCodeList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.AcceptableExitCodeList.Add('0')
                                      $CCTKCommandProperties.AppendSetupPassword = $True
                                    $CCTKCommandList.Add($CCTKCommandProperties)

                                    $CCTKCommandProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                      $CCTKCommandProperties.CommandID = 'SetHttpsBootMode'
                                      $CCTKCommandProperties.Enabled = $True
                                      $CCTKCommandProperties.Description = 'Set the HTTPS boot mode to manual'
                                      $CCTKCommandProperties.ArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.ArgumentList.Add('--HttpsBootMode=ManualMode')
                                      $CCTKCommandProperties.AcceptableExitCodeList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.AcceptableExitCodeList.Add('0')
                                      $CCTKCommandProperties.AppendSetupPassword = $True
                                    $CCTKCommandList.Add($CCTKCommandProperties)

                                    $CCTKCommandProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                      $CCTKCommandProperties.CommandID = 'DeleteHttpBootProfile'
                                      $CCTKCommandProperties.Enabled = ($SkipProfileDeletion.IsPresent -eq $False)
                                      $CCTKCommandProperties.Description = 'Delete the existing HTTP boot profile (Updating the URL within an existing profile has been observed to not always apply)'
                                      $CCTKCommandProperties.ArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.ArgumentList.Add('HttpBootProfile')
                                        $CCTKCommandProperties.ArgumentList.Add('--Delete')
                                      $CCTKCommandProperties.AcceptableExitCodeList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.AcceptableExitCodeList.Add('0')
                                        $CCTKCommandProperties.AcceptableExitCodeList.Add('150')
                                      $CCTKCommandProperties.AppendSetupPassword = $True
                                    $CCTKCommandList.Add($CCTKCommandProperties)

                                    $CCTKCommandProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                      $CCTKCommandProperties.CommandID = 'SetHttpBootProfile'
                                      $CCTKCommandProperties.Enabled = $True
                                      $CCTKCommandProperties.Description = 'Apply the generated HTTP boot profile'
                                      $CCTKCommandProperties.ArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.ArgumentList.Add('HttpBootProfile')
                                        $CCTKCommandProperties.ArgumentList.Add("`"--Set=$($HttpBootProfilePath.FullName)`"")
                                      $CCTKCommandProperties.AcceptableExitCodeList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.AcceptableExitCodeList.Add('0')
                                      $CCTKCommandProperties.AppendSetupPassword = $True
                                    $CCTKCommandList.Add($CCTKCommandProperties)

                                    $CCTKCommandProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                      $CCTKCommandProperties.CommandID = 'GetHttpBootProfile'
                                      $CCTKCommandProperties.Enabled = $True
                                      $CCTKCommandProperties.Description = 'Read the applied HTTP boot profile for verification'
                                      $CCTKCommandProperties.ArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.ArgumentList.Add('HttpBootProfile')
                                        $CCTKCommandProperties.ArgumentList.Add('--Get')
                                      $CCTKCommandProperties.AcceptableExitCodeList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                        $CCTKCommandProperties.AcceptableExitCodeList.Add('0')
                                      $CCTKCommandProperties.AppendSetupPassword = $False
                                    $CCTKCommandList.Add($CCTKCommandProperties)
                                  #endregion

                                  #region Execute the CCTK command list
                                    $CCTKCommandResultTable = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

                                    For ($CCTKCommandListIndex = 0; $CCTKCommandListIndex -lt $CCTKCommandList.Count; $CCTKCommandListIndex++)
                                      {
                                          $CCTKCommand = $CCTKCommandList[$CCTKCommandListIndex]

                                          Switch ($CCTKCommand.Enabled)
                                            {
                                                {($_ -eq $True)}
                                                  {
                                                      $WriteLogMessage.Invoke(0, @("CCTK command $($CCTKCommandListIndex + 1) of $($CCTKCommandList.Count): $($CCTKCommand.Description). Please Wait..."))

                                                      $StartProcessWithOutputParameters = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                                        $StartProcessWithOutputParameters.FilePath = "$($CCTKExecutablePath.FullName)"
                                                        $StartProcessWithOutputParameters.WorkingDirectory = "$($CCTKExecutablePath.Directory.FullName)"
                                                        $StartProcessWithOutputParameters.ArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                          $StartProcessWithOutputParameters.ArgumentList.AddRange($CCTKCommand.ArgumentList)
                                                        $StartProcessWithOutputParameters.AcceptableExitCodeList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                          $StartProcessWithOutputParameters.AcceptableExitCodeList.AddRange($CCTKCommand.AcceptableExitCodeList)
                                                        $StartProcessWithOutputParameters.CreateNoWindow = $True
                                                        $StartProcessWithOutputParameters.ExecutionTimeout = [System.TimeSpan]::FromMinutes(5)
                                                        $StartProcessWithOutputParameters.LogOutput = $True
                                                        $StartProcessWithOutputParameters.SecureArgumentList = $False
                                                        $StartProcessWithOutputParameters.Verbose = $True

                                                        Switch (($CCTKCommand.AppendSetupPassword -eq $True) -and ([System.String]::IsNullOrEmpty($SetupPassword) -eq $False) -and ([System.String]::IsNullOrWhiteSpace($SetupPassword) -eq $False))
                                                          {
                                                              {($_ -eq $True)}
                                                                {
                                                                    $StartProcessWithOutputParameters.ArgumentList.Add("--ValSetupPwd=$($SetupPassword)")

                                                                    $StartProcessWithOutputParameters.SecureArgumentList = $True
                                                                }
                                                          }

                                                      $StartProcessWithOutputResult = Start-ProcessWithOutput @StartProcessWithOutputParameters

                                                      $CCTKCommandResultTable."$($CCTKCommand.CommandID)" = $StartProcessWithOutputResult
                                                  }

                                                Default
                                                  {
                                                      $WriteLogMessage.Invoke(0, @("CCTK command $($CCTKCommandListIndex + 1) of $($CCTKCommandList.Count): $($CCTKCommand.Description). [Skipped]"))
                                                  }
                                            }
                                      }
                                  #endregion

                                  #region Verify that the applied HTTP boot profile contains the specified boot URL
                                    $HttpBootProfileGetResult = $CCTKCommandResultTable.'GetHttpBootProfile'

                                    Switch ($Null -ine $HttpBootProfileGetResult)
                                      {
                                          {($_ -eq $True)}
                                            {
                                                Switch ("$($HttpBootProfileGetResult.StandardOutput)" -imatch [Regex]::Escape($BootURL.AbsoluteUri))
                                                  {
                                                      {($_ -eq $True)}
                                                        {
                                                            $WriteLogMessage.Invoke(0, @("The applied HTTP boot profile was successfully verified. The configured boot URL matches `"$($BootURL.AbsoluteUri)`"."))
                                                        }

                                                      Default
                                                        {
                                                            $WriteLogMessage.Invoke(2, @("The applied HTTP boot profile does not contain the specified boot URL of `"$($BootURL.AbsoluteUri)`". The BIOS may not have accepted the profile. Review the profile output above, and verify the configuration within the BIOS setup interface."))

                                                            Throw 'The verification of the applied HTTP boot profile was unsuccessful.'
                                                        }
                                                  }
                                            }
                                      }
                                  #endregion

                                  Break DeviceManufacturerSwitch
                              }

                            '(^.*(Hewlett|HP).*$)'
                              {
                                  $WriteLogMessage.Invoke(2, @("The device manufacturer `"$($DeviceManufacturer)`" is not implemented yet. No HTTP(s) boot BIOS configuration will be performed."))

                                  Break DeviceManufacturerSwitch
                              }

                            '(^.*Lenovo.*$)'
                              {
                                  $WriteLogMessage.Invoke(2, @("The device manufacturer `"$($DeviceManufacturer)`" is not implemented yet. No HTTP(s) boot BIOS configuration will be performed."))

                                  Break DeviceManufacturerSwitch
                              }

                            Default
                              {
                                  $WriteLogMessage.Invoke(2, @("The device manufacturer `"$($DeviceManufacturer)`" is not supported. No HTTP(s) boot BIOS configuration will be performed."))
                              }
                        }
                    #endregion
                  #endregion
              }
            Catch
              {
                  #region Perform error handling actions
                    $ErrorHandlingDefinition.Invoke($Error[0], 2, $ContinueOnError.IsPresent)
                  #endregion
              }
            Finally
              {
                  #region Perform finalization actions
                    $FinalizationActions.Invoke()
                  #endregion
              }
        }

      {($_ -eq $False)}
        {
            [System.IO.FileInfo]$ScriptPath = "$($MyInvocation.MyCommand.Definition)"

            #$CurrentExecutionPolicy = Get-ExecutionPolicy -Scope Process

            $CurrentExecutionPolicy = 'Bypass'

            $ArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
              $ArgumentList.Add("-ExecutionPolicy $($CurrentExecutionPolicy)")
              $ArgumentList.Add('-NonInteractive')
              $ArgumentList.Add('-NoProfile')
              $ArgumentList.Add('-NoLogo')
              $ArgumentList.Add('-NoExit')
              $ArgumentList.Add('-Command')
              $ArgumentList.Add("`"`& {. `"$($ScriptPath.FullName)`"")

            $MyInvocation.UnboundArguments.GetEnumerator() | ForEach-Object {$ArgumentList.Add("-$($_.Key) @($($_.Value | ForEach-Object {`"$($_)`"}))")}

            $PSBoundParameters.GetEnumerator() | ForEach-Object {$ArgumentList.Add("-$($_.Key) @($($_.Value | ForEach-Object {`"$($_)`"}))")}

            $ArgumentListTargetIndex = $ArgumentList.Count - 1

            $ArgumentListIndexItem = $ArgumentList[$ArgumentListTargetIndex]

            $Null = $ArgumentList.RemoveAt($ArgumentListTargetIndex)

            $Null = $ArgumentList.Insert($ArgumentListTargetIndex, ($ArgumentListIndexItem + ';'))

            $ArgumentList.Add("[System.Environment]::Exit((`$LASTEXITCODE -Bor [Int](-Not `$? -And -Not `$LASTEXITCODE)))}`"")

            $ScriptInterpreterList = New-Object -TypeName 'System.Collections.Generic.List[System.String]'
              $ScriptInterpreterList.Add('powershell.exe')
              $ScriptInterpreterList.Add('pwsh.exe')

            :ScriptInterpreterListLoop ForEach ($ScriptInterpreter In $ScriptInterpreterList)
              {
                  $ScriptInterpreterObject = Try {Get-Command -Name ($ScriptInterpreter) -ErrorAction SilentlyContinue} Catch {$Null}

                  Switch ($Null -ine $ScriptInterpreterObject)
                    {
                        {($_ -eq $True)}
                          {
                              $Null = Start-Process -FilePath ($ScriptInterpreterObject.Path) -WorkingDirectory "$($Env:Temp.TrimEnd('\'))" -ArgumentList ($ArgumentList.ToArray()) -WindowStyle Normal -Verb RunAs -PassThru

                              Break ScriptInterpreterListLoop
                          }
                    }
              }
        }
  }
