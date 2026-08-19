#region Invoke-ToolStaging
Function Invoke-ToolStaging
  {
      <#
          .SYNOPSIS
          Dynamically stages external tool binaries into the toolkit tools directory so that they travel with the script and repeat executions use the cached bits.

          .DESCRIPTION
          Some vendor binaries cannot be redistributed with this repository, so they are downloaded and extracted at execution time instead. This function downloads each defined tool, extracts it when necessary, and places the binaries into the toolkit tools directory structure (All, X86, X64, ARM64). Once staged, the binaries travel with the script folder (for example on a deployment share), so subsequent executions on any device use the cached bits without downloading anything.

          The following tool types are supported:

            RawFile           - The downloaded file is placed directly at the destination (no extraction).
            Archive           - A .zip archive (extracted with the built in compression classes) or a .7z archive (extracted with the 7-Zip console executable).
            MSI               - An MSI package expanded by using an MSI administrative extraction (msiexec /a), which produces the installed file tree without installing anything.
            DellUpdatePackage - A Dell Update Package (DUP) executable. The embedded 7-Zip payload is carved out of the package by binary signature, extracted with the 7-Zip console executable, and the resulting MSI is expanded by using an MSI administrative extraction.

          .PARAMETER ToolList
          One or more tool definitions. Each definition is an ordered dictionary with the following properties:

            Enabled                 - Boolean. Disabled definitions are skipped.
            Name                    - The tool name. Used for logging and for the working folder name.
            Type                    - RawFile, Archive, MSI, or DellUpdatePackage.
            DownloadURL             - The URL the tool content is downloaded from.
            DestinationMappingTable - An ordered dictionary that maps content within the extracted tree to a destination relative to the tools directory. The key is a folder or file name to locate within the extracted tree (or "." for the downloaded file itself), and the value is the destination path relative to the tools directory. Mappings whose source cannot be located are logged and skipped, which allows a single definition to include architecture folders that are not present within every source.
            CompletionTestPathList  - One or more paths relative to the tools directory. When ANY of them exists, the tool is considered already staged and is skipped (unless the Force parameter is specified).

          .PARAMETER ToolsDirectory
          The root toolkit tools directory that the binaries are staged into (the folder containing the All, X86, X64, and ARM64 subdirectories).

          .PARAMETER StagingDirectory
          The working directory used for downloads and extraction. Keep this path short, because MSI administrative extractions can fail with "path too long" errors when the working path is deep. The working content for each tool is removed after it has been staged successfully.

          .PARAMETER SevenZipExecutablePath
          The path to the 7-Zip console executable (7zr.exe). Required to extract Dell Update Package payloads and .7z archives. Defaults to "All\7-Zip\7zr.exe" within the tools directory, so a RawFile definition that stages 7-Zip should be placed before any definition that requires it.

          .PARAMETER WebProxy
          An optional web proxy that is applied to every download. When not specified, no proxy is used.

          .PARAMETER Force
          Stages each tool even when its completion test paths indicate that it has already been staged.

          .PARAMETER ContinueOnError
          Continue with the remaining tool definitions instead of throwing a terminating error when a tool cannot be staged.

          .EXAMPLE
          $ToolStagingList = New-Object -TypeName 'System.Collections.Generic.List[System.Collections.IDictionary]'

          $ToolDefinition = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
            $ToolDefinition.Enabled = $True
            $ToolDefinition.Name = 'SevenZip'
            $ToolDefinition.Type = 'RawFile'
            $ToolDefinition.DownloadURL = [System.URI]'https://www.7-zip.org/a/7zr.exe'
            $ToolDefinition.DestinationMappingTable = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
              $ToolDefinition.DestinationMappingTable['.'] = [System.IO.Path]::Combine('All', '7-Zip', '7zr.exe')
            $ToolDefinition.CompletionTestPathList = New-Object -TypeName 'System.Collections.Generic.List[String]'
              $ToolDefinition.CompletionTestPathList.Add([System.IO.Path]::Combine('All', '7-Zip', '7zr.exe'))
          $ToolStagingList.Add($ToolDefinition)

          $InvokeToolStagingResult = Invoke-ToolStaging -ToolList ($ToolStagingList.ToArray()) -ToolsDirectory ($ToolsDirectory) -Verbose

          .NOTES
          The download logic always sends a user agent header, because some download servers (such as dl.dell.com) reject anonymous requests.

          .LINK
          https://www.dell.com/support/kbdoc/en-us/000178000/dell-command-configure
      #>

      [CmdletBinding()]
        Param
          (
              [Parameter(Mandatory=$True)]
              [ValidateNotNullOrEmpty()]
              [Alias('TL')]
              [System.Collections.IDictionary[]]$ToolList,

              [Parameter(Mandatory=$True)]
              [ValidateNotNullOrEmpty()]
              [Alias('TD')]
              [System.IO.DirectoryInfo]$ToolsDirectory,

              [Parameter(Mandatory=$False)]
              [ValidateNotNullOrEmpty()]
              [Alias('SD')]
              [System.IO.DirectoryInfo]$StagingDirectory,

              [Parameter(Mandatory=$False)]
              [ValidateNotNullOrEmpty()]
              [Alias('SZEP')]
              [System.IO.FileInfo]$SevenZipExecutablePath,

              [Parameter(Mandatory=$False)]
              [ValidateNotNullOrEmpty()]
              [Alias('WP')]
              [System.Net.IWebProxy]$WebProxy,

              [Parameter(Mandatory=$False)]
              [Alias('F')]
              [Switch]$Force,

              [Parameter(Mandatory=$False)]
              [Alias('COE')]
              [Switch]$ContinueOnError
          )

      Try
        {
            $ErrorActionPreference = 'Stop'

            [String]$CmdletName = $MyInvocation.MyCommand.Name

            $WriteLogMessage.Invoke(0, @("Function `'$($CmdletName)`' is beginning. Please Wait..."))

            #region Set default parameter values
              Switch ($True)
                {
                    {([System.String]::IsNullOrEmpty($StagingDirectory) -eq $True) -or ([System.String]::IsNullOrWhiteSpace($StagingDirectory) -eq $True)}
                      {
                          [System.IO.DirectoryInfo]$StagingDirectory = [System.IO.Path]::Combine("$($Env:Windir)", 'Temp', 'ToolStaging')
                      }

                    {([System.String]::IsNullOrEmpty($SevenZipExecutablePath) -eq $True) -or ([System.String]::IsNullOrWhiteSpace($SevenZipExecutablePath) -eq $True)}
                      {
                          [System.IO.FileInfo]$SevenZipExecutablePath = [System.IO.Path]::Combine("$($ToolsDirectory.FullName)", 'All', '7-Zip', '7zr.exe')
                      }
                }
            #endregion

            #region Define the internal download scriptblock
              [ScriptBlock]$DownloadToolFile = {
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

                                                         Switch ($Null -ine $WebProxy)
                                                           {
                                                               {($_ -eq $True)}
                                                                 {
                                                                     $WebClient.Proxy = $WebProxy
                                                                 }

                                                               Default
                                                                 {
                                                                     $WebClient.Proxy = $Null
                                                                 }
                                                           }

                                                         $Null = $WebClient.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ToolStaging')

                                                         $Null = $WebClient.DownloadFile($SourceURL.AbsoluteUri, $DestinationPath.FullName)

                                                         $WriteLogMessage.Invoke(0, @("The download completed successfully. [Size: $([System.Math]::Round((Get-Item -Path $DestinationPath.FullName).Length / 1MB, 2)) MB]"))
                                                     }
                                                   Finally
                                                     {
                                                         $Null = $WebClient.Dispose()
                                                     }
                                               }
            #endregion

            #region Define the MSI administrative extraction scriptblock
              [ScriptBlock]$ExpandMSIPackage = {
                                                   Param
                                                     (
                                                         [System.IO.FileInfo]$MSIPackagePath,
                                                         [System.IO.DirectoryInfo]$DestinationDirectory
                                                     )

                                                   $MSIExecCommandObject = Try {Get-Command -Name 'msiexec.exe' -ErrorAction SilentlyContinue} Catch {$Null}

                                                   Switch ($Null -ieq $MSIExecCommandObject)
                                                     {
                                                         {($_ -eq $True)}
                                                           {
                                                               Throw 'The msiexec.exe executable could not be located, so the MSI cannot be expanded. Within Windows PE, either add the WinPE-MSI optional component to the boot image, or stage the tools by executing the script once from a full Windows operating system so that the staged binaries travel with the script folder.'
                                                           }
                                                     }

                                                   $WriteLogMessage.Invoke(0, @("Attempting to expand `"$($MSIPackagePath.FullName)`" into `"$($DestinationDirectory.FullName)`". Please Wait..."))

                                                   $StartProcessWithOutputParameters = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                                     $StartProcessWithOutputParameters.FilePath = "$($MSIExecCommandObject.Path)"
                                                     $StartProcessWithOutputParameters.WorkingDirectory = "$($MSIPackagePath.Directory.FullName)"
                                                     $StartProcessWithOutputParameters.ArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                       $StartProcessWithOutputParameters.ArgumentList.Add('/a')
                                                       $StartProcessWithOutputParameters.ArgumentList.Add("`"$($MSIPackagePath.FullName)`"")
                                                       $StartProcessWithOutputParameters.ArgumentList.Add("TARGETDIR=`"$($DestinationDirectory.FullName)`"")
                                                       $StartProcessWithOutputParameters.ArgumentList.Add('/qn')
                                                     $StartProcessWithOutputParameters.AcceptableExitCodeList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                       $StartProcessWithOutputParameters.AcceptableExitCodeList.Add('0')
                                                     $StartProcessWithOutputParameters.CreateNoWindow = $True
                                                     $StartProcessWithOutputParameters.ExecutionTimeout = [System.TimeSpan]::FromMinutes(10)
                                                     $StartProcessWithOutputParameters.LogOutput = $True
                                                     $StartProcessWithOutputParameters.Verbose = $True

                                                   $Null = Start-ProcessWithOutput @StartProcessWithOutputParameters
                                               }
            #endregion

            #region Define the 7-Zip extraction scriptblock
              [ScriptBlock]$ExpandSevenZipArchive = {
                                                        Param
                                                          (
                                                              [System.IO.FileInfo]$ArchivePath,
                                                              [System.IO.DirectoryInfo]$DestinationDirectory
                                                          )

                                                        Switch ([System.IO.File]::Exists($SevenZipExecutablePath.FullName))
                                                          {
                                                              {($_ -eq $False)}
                                                                {
                                                                    Throw "The 7-Zip console executable does not exist at `"$($SevenZipExecutablePath.FullName)`". Ensure that a RawFile tool definition that stages 7-Zip is placed before any definition that requires it."
                                                                }
                                                          }

                                                        $WriteLogMessage.Invoke(0, @("Attempting to extract `"$($ArchivePath.FullName)`" into `"$($DestinationDirectory.FullName)`". Please Wait..."))

                                                        #An exit code of 1 is a 7-Zip warning (such as trailing bytes after the end of a carved archive) and is acceptable.
                                                        $StartProcessWithOutputParameters = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                                          $StartProcessWithOutputParameters.FilePath = "$($SevenZipExecutablePath.FullName)"
                                                          $StartProcessWithOutputParameters.WorkingDirectory = "$($ArchivePath.Directory.FullName)"
                                                          $StartProcessWithOutputParameters.ArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                            $StartProcessWithOutputParameters.ArgumentList.Add('x')
                                                            $StartProcessWithOutputParameters.ArgumentList.Add("`"$($ArchivePath.FullName)`"")
                                                            $StartProcessWithOutputParameters.ArgumentList.Add("`"-o$($DestinationDirectory.FullName)`"")
                                                            $StartProcessWithOutputParameters.ArgumentList.Add('-y')
                                                          $StartProcessWithOutputParameters.AcceptableExitCodeList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                            $StartProcessWithOutputParameters.AcceptableExitCodeList.Add('0')
                                                            $StartProcessWithOutputParameters.AcceptableExitCodeList.Add('1')
                                                          $StartProcessWithOutputParameters.CreateNoWindow = $True
                                                          $StartProcessWithOutputParameters.ExecutionTimeout = [System.TimeSpan]::FromMinutes(10)
                                                          $StartProcessWithOutputParameters.LogOutput = $True
                                                          $StartProcessWithOutputParameters.Verbose = $True

                                                        $Null = Start-ProcessWithOutput @StartProcessWithOutputParameters
                                                    }
            #endregion

            $OutputObjectList = New-Object -TypeName 'System.Collections.Generic.List[PSObject]'

            [Int]$ToolStagingErrorCount = 0

            :ToolListLoop For ($ToolListIndex = 0; $ToolListIndex -lt $ToolList.Count; $ToolListIndex++)
              {
                  Try
                    {
                        $ToolDefinition = $ToolList[$ToolListIndex]

                        $OutputObjectProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                          $OutputObjectProperties.Name = "$($ToolDefinition.Name)"
                          $OutputObjectProperties.Staged = $False
                          $OutputObjectProperties.FromCache = $False
                          $OutputObjectProperties.DestinationPathList = New-Object -TypeName 'System.Collections.Generic.List[String]'

                        Switch ($ToolDefinition.Enabled)
                          {
                              {($_ -eq $False)}
                                {
                                    $WriteLogMessage.Invoke(0, @("Tool $($ToolListIndex + 1) of $($ToolList.Count) `"$($ToolDefinition.Name)`" is disabled and will be skipped."))

                                    $OutputObjectList.Add((New-Object -TypeName 'PSObject' -Property ($OutputObjectProperties)))

                                    Continue ToolListLoop
                                }
                          }

                        $WriteLogMessage.Invoke(0, @("Tool $($ToolListIndex + 1) of $($ToolList.Count): Attempting to stage `"$($ToolDefinition.Name)`" [Type: $($ToolDefinition.Type)]. Please Wait..."))

                        #region Determine whether the tool has already been staged
                          [Boolean]$ToolIsCached = $False

                          Switch (($Force.IsPresent -eq $False) -and ($Null -ine $ToolDefinition.CompletionTestPathList))
                            {
                                {($_ -eq $True)}
                                  {
                                      :CompletionTestPathLoop ForEach ($CompletionTestPath In $ToolDefinition.CompletionTestPathList)
                                        {
                                            [String]$CompletionTestFullPath = [System.IO.Path]::Combine("$($ToolsDirectory.FullName)", "$($CompletionTestPath)")

                                            Switch (([System.IO.File]::Exists($CompletionTestFullPath) -eq $True) -or ([System.IO.Directory]::Exists($CompletionTestFullPath) -eq $True))
                                              {
                                                  {($_ -eq $True)}
                                                    {
                                                        [Boolean]$ToolIsCached = $True

                                                        $WriteLogMessage.Invoke(0, @("Tool `"$($ToolDefinition.Name)`" has already been staged. The cached bits will be used. [Path: $($CompletionTestFullPath)]"))

                                                        Break CompletionTestPathLoop
                                                    }
                                              }
                                        }
                                  }
                            }

                          Switch ($ToolIsCached)
                            {
                                {($_ -eq $True)}
                                  {
                                      $OutputObjectProperties.Staged = $True
                                      $OutputObjectProperties.FromCache = $True

                                      $OutputObjectList.Add((New-Object -TypeName 'PSObject' -Property ($OutputObjectProperties)))

                                      Continue ToolListLoop
                                  }
                            }
                        #endregion

                        #region Download the tool content
                          [System.URI]$ToolDownloadURL = $ToolDefinition.DownloadURL

                          [System.IO.DirectoryInfo]$ToolWorkingDirectory = [System.IO.Path]::Combine("$($StagingDirectory.FullName)", "$($ToolDefinition.Name)")

                          [System.IO.FileInfo]$ToolDownloadPath = [System.IO.Path]::Combine("$($ToolWorkingDirectory.FullName)", [System.IO.Path]::GetFileName($ToolDownloadURL.LocalPath))

                          Switch ([System.IO.File]::Exists($ToolDownloadPath.FullName))
                            {
                                {($_ -eq $True)}
                                  {
                                      $WriteLogMessage.Invoke(0, @("The tool content has already been downloaded to `"$($ToolDownloadPath.FullName)`". The existing file will be reused."))
                                  }

                                Default
                                  {
                                      $Null = $DownloadToolFile.InvokeReturnAsIs($ToolDownloadURL, $ToolDownloadPath)
                                  }
                            }
                        #endregion

                        #region Extract the tool content based on the tool type
                          [System.IO.DirectoryInfo]$ToolExtractionDirectory = [System.IO.Path]::Combine("$($ToolWorkingDirectory.FullName)", 'Extracted')

                          Switch -Regex ("$($ToolDefinition.Type)")
                            {
                                '(^RawFile$)'
                                  {
                                      #No extraction is necessary. The destination mapping key "." refers to the downloaded file itself.
                                  }

                                '(^Archive$)'
                                  {
                                      Switch ([System.IO.Path]::GetExtension($ToolDownloadPath.FullName).ToLower())
                                        {
                                            {($_ -iin @('.zip'))}
                                              {
                                                  $WriteLogMessage.Invoke(0, @("Attempting to extract the ZIP archive `"$($ToolDownloadPath.FullName)`" into `"$($ToolExtractionDirectory.FullName)`". Please Wait..."))

                                                  $Null = Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

                                                  $Null = [System.IO.Compression.ZipFile]::ExtractToDirectory("$($ToolDownloadPath.FullName)", "$($ToolExtractionDirectory.FullName)")
                                              }

                                            {($_ -iin @('.7z'))}
                                              {
                                                  $Null = $ExpandSevenZipArchive.InvokeReturnAsIs($ToolDownloadPath, $ToolExtractionDirectory)
                                              }

                                            Default
                                              {
                                                  Throw "The archive extension of `"$($_)`" is not supported. Supported extensions: .zip, .7z"
                                              }
                                        }
                                  }

                                '(^MSI$)'
                                  {
                                      $Null = $ExpandMSIPackage.InvokeReturnAsIs($ToolDownloadPath, $ToolExtractionDirectory)
                                  }

                                '(^DellUpdatePackage$)'
                                  {
                                      #region Carve the embedded 7-Zip payload out of the Dell Update Package
                                        #A Dell Update Package is a portable executable with a 7-Zip archive embedded within it. The archive begins at the first occurrence of the 7-Zip binary signature (37 7A BC AF 27 1C) that is followed by the format version bytes (00 04). Candidate signatures without the version bytes are false positives within the executable code.
                                        $WriteLogMessage.Invoke(0, @("Attempting to locate the embedded 7-Zip payload within `"$($ToolDownloadPath.FullName)`". Please Wait..."))

                                        [System.Byte[]]$ToolPackageByteList = [System.IO.File]::ReadAllBytes($ToolDownloadPath.FullName)

                                        [Int64]$SevenZipArchiveSignatureOffset = -1

                                        [Int64]$SevenZipArchiveSignatureCandidateIndex = [System.Array]::IndexOf($ToolPackageByteList, [System.Byte]0x37, 0)

                                        :SevenZipArchiveSignatureScanLoop While ($SevenZipArchiveSignatureCandidateIndex -gt -1)
                                          {
                                              Switch (($SevenZipArchiveSignatureCandidateIndex + 8) -lt $ToolPackageByteList.Length)
                                                {
                                                    {($_ -eq $True)}
                                                      {
                                                          Switch (($ToolPackageByteList[$SevenZipArchiveSignatureCandidateIndex + 1] -eq 0x7A) -and ($ToolPackageByteList[$SevenZipArchiveSignatureCandidateIndex + 2] -eq 0xBC) -and ($ToolPackageByteList[$SevenZipArchiveSignatureCandidateIndex + 3] -eq 0xAF) -and ($ToolPackageByteList[$SevenZipArchiveSignatureCandidateIndex + 4] -eq 0x27) -and ($ToolPackageByteList[$SevenZipArchiveSignatureCandidateIndex + 5] -eq 0x1C) -and ($ToolPackageByteList[$SevenZipArchiveSignatureCandidateIndex + 6] -eq 0x00) -and ($ToolPackageByteList[$SevenZipArchiveSignatureCandidateIndex + 7] -eq 0x04))
                                                            {
                                                                {($_ -eq $True)}
                                                                  {
                                                                      [Int64]$SevenZipArchiveSignatureOffset = $SevenZipArchiveSignatureCandidateIndex

                                                                      Break SevenZipArchiveSignatureScanLoop
                                                                  }
                                                            }
                                                      }

                                                    Default
                                                      {
                                                          Break SevenZipArchiveSignatureScanLoop
                                                      }
                                                }

                                              [Int64]$SevenZipArchiveSignatureCandidateIndex = [System.Array]::IndexOf($ToolPackageByteList, [System.Byte]0x37, $SevenZipArchiveSignatureCandidateIndex + 1)
                                          }

                                        Switch ($SevenZipArchiveSignatureOffset -gt -1)
                                          {
                                              {($_ -eq $True)}
                                                {
                                                    $WriteLogMessage.Invoke(0, @("The embedded 7-Zip payload was located at byte offset $($SevenZipArchiveSignatureOffset)."))
                                                }

                                              Default
                                                {
                                                    Throw "An embedded 7-Zip payload could not be located within `"$($ToolDownloadPath.FullName)`". The downloaded file may not be a Dell Update Package."
                                                }
                                          }

                                        [System.IO.FileInfo]$ToolPayloadArchivePath = [System.IO.Path]::Combine("$($ToolWorkingDirectory.FullName)", 'Payload.7z')

                                        $ToolPayloadArchiveStream = New-Object -TypeName 'System.IO.FileStream' -ArgumentList @("$($ToolPayloadArchivePath.FullName)", [System.IO.FileMode]::Create)

                                        Try
                                          {
                                              $Null = $ToolPayloadArchiveStream.Write($ToolPackageByteList, $SevenZipArchiveSignatureOffset, $ToolPackageByteList.Length - $SevenZipArchiveSignatureOffset)
                                          }
                                        Finally
                                          {
                                              $Null = $ToolPayloadArchiveStream.Dispose()
                                          }
                                      #endregion

                                      #region Extract the carved payload and expand the MSI that it contains
                                        [System.IO.DirectoryInfo]$ToolPayloadDirectory = [System.IO.Path]::Combine("$($ToolWorkingDirectory.FullName)", 'Payload')

                                        $Null = $ExpandSevenZipArchive.InvokeReturnAsIs($ToolPayloadArchivePath, $ToolPayloadDirectory)

                                        $ToolPayloadMSIObject = Get-ChildItem -Path ($ToolPayloadDirectory.FullName) -Filter '*.msi' | Select-Object -First 1

                                        Switch ($Null -ieq $ToolPayloadMSIObject)
                                          {
                                              {($_ -eq $True)}
                                                {
                                                    Throw "An MSI could not be located within the extracted Dell Update Package payload at `"$($ToolPayloadDirectory.FullName)`"."
                                                }
                                          }

                                        $Null = $ExpandMSIPackage.InvokeReturnAsIs(([System.IO.FileInfo]$ToolPayloadMSIObject.FullName), $ToolExtractionDirectory)
                                      #endregion
                                  }

                                Default
                                  {
                                      Throw "The tool type of `"$($ToolDefinition.Type)`" is not supported. Supported types: RawFile, Archive, MSI, DellUpdatePackage"
                                  }
                            }
                        #endregion

                        #region Place the extracted content into the tools directory based on the destination mapping table
                          ForEach ($DestinationMapping In $ToolDefinition.DestinationMappingTable.GetEnumerator())
                            {
                                [String]$DestinationMappingSource = "$($DestinationMapping.Key)"

                                [String]$DestinationMappingTarget = [System.IO.Path]::Combine("$($ToolsDirectory.FullName)", "$($DestinationMapping.Value)")

                                #region Resolve the source within the extracted tree
                                  $DestinationMappingSourceObject = $Null

                                  Switch ($True)
                                    {
                                        {($DestinationMappingSource -ieq '.')}
                                          {
                                              $DestinationMappingSourceObject = Get-Item -Path ($ToolDownloadPath.FullName)
                                          }

                                        {($DestinationMappingSource -ine '.') -and ([System.IO.Directory]::Exists([System.IO.Path]::Combine("$($ToolExtractionDirectory.FullName)", $DestinationMappingSource)) -eq $True)}
                                          {
                                              $DestinationMappingSourceObject = Get-Item -Path ([System.IO.Path]::Combine("$($ToolExtractionDirectory.FullName)", $DestinationMappingSource))
                                          }

                                        {($DestinationMappingSource -ine '.') -and ($Null -ieq $DestinationMappingSourceObject)}
                                          {
                                              $DestinationMappingSourceObject = Get-ChildItem -Path ($ToolExtractionDirectory.FullName) -Recurse -Filter ($DestinationMappingSource) | Select-Object -First 1
                                          }
                                    }
                                #endregion

                                Switch ($Null -ine $DestinationMappingSourceObject)
                                  {
                                      {($_ -eq $True)}
                                        {
                                            $WriteLogMessage.Invoke(0, @("Attempting to place `"$($DestinationMappingSourceObject.FullName)`" at `"$($DestinationMappingTarget)`". Please Wait..."))

                                            Switch ($DestinationMappingSourceObject.PSIsContainer)
                                              {
                                                  {($_ -eq $True)}
                                                    {
                                                        Switch ([System.IO.Directory]::Exists($DestinationMappingTarget))
                                                          {
                                                              {($_ -eq $True)}
                                                                {
                                                                    $Null = [System.IO.Directory]::Delete($DestinationMappingTarget, $True)
                                                                }
                                                          }

                                                        $Null = [System.IO.Directory]::CreateDirectory($DestinationMappingTarget)

                                                        $Null = Copy-Item -Path "$($DestinationMappingSourceObject.FullName)\*" -Destination ($DestinationMappingTarget) -Recurse -Force
                                                    }

                                                  Default
                                                    {
                                                        $Null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($DestinationMappingTarget))

                                                        $Null = Copy-Item -Path ($DestinationMappingSourceObject.FullName) -Destination ($DestinationMappingTarget) -Force
                                                    }
                                              }

                                            $OutputObjectProperties.DestinationPathList.Add($DestinationMappingTarget)
                                        }

                                      Default
                                        {
                                            $WriteLogMessage.Invoke(2, @("The destination mapping source of `"$($DestinationMappingSource)`" could not be located within `"$($ToolExtractionDirectory.FullName)`". The mapping will be skipped. This is expected when the source content does not contain that architecture."))
                                        }
                                  }
                            }
                        #endregion

                        #region Remove the tool working directory
                          Switch ([System.IO.Directory]::Exists($ToolWorkingDirectory.FullName))
                            {
                                {($_ -eq $True)}
                                  {
                                      $WriteLogMessage.Invoke(0, @("Attempting to remove the tool working directory `"$($ToolWorkingDirectory.FullName)`". Please Wait..."))

                                      $Null = Try {[System.IO.Directory]::Delete($ToolWorkingDirectory.FullName, $True)} Catch {$Null}
                                  }
                            }
                        #endregion

                        $OutputObjectProperties.Staged = ($OutputObjectProperties.DestinationPathList.Count -gt 0)

                        Switch ($OutputObjectProperties.Staged)
                          {
                              {($_ -eq $True)}
                                {
                                    $WriteLogMessage.Invoke(0, @("Tool `"$($ToolDefinition.Name)`" was staged successfully. [Destination(s): $($OutputObjectProperties.DestinationPathList -Join '; ')]"))
                                }

                              Default
                                {
                                    Throw "None of the destination mappings for tool `"$($ToolDefinition.Name)`" could be staged."
                                }
                          }

                        $OutputObjectList.Add((New-Object -TypeName 'PSObject' -Property ($OutputObjectProperties)))
                    }
                  Catch
                    {
                        [Int]$ToolStagingErrorCount = $ToolStagingErrorCount + 1

                        $WriteLogMessage.Invoke(2, @("Tool `"$($ToolDefinition.Name)`" could not be staged.", "Message: $($_.Exception.Message)"))

                        $OutputObjectList.Add((New-Object -TypeName 'PSObject' -Property ($OutputObjectProperties)))

                        Switch ($ContinueOnError.IsPresent)
                          {
                              {($_ -eq $False)}
                                {
                                    Throw
                                }
                          }
                    }
              }

            Write-Output -InputObject ($OutputObjectList.ToArray())
        }
      Catch
        {
            $ExceptionPropertyDictionary = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
              $ExceptionPropertyDictionary.Add('Message', $_.Exception.Message)
              $ExceptionPropertyDictionary.Add('Category', $_.Exception.ErrorRecord.FullyQualifiedErrorID)
              $ExceptionPropertyDictionary.Add('LineNumber', $_.InvocationInfo.ScriptLineNumber)
              $ExceptionPropertyDictionary.Add('LinePosition', $_.InvocationInfo.OffsetInLine)
              $ExceptionPropertyDictionary.Add('Code', $_.InvocationInfo.Line.Trim())

            $ExceptionMessageList = New-Object -TypeName 'System.Collections.Generic.List[String]'

            ForEach ($ExceptionProperty In $ExceptionPropertyDictionary.GetEnumerator())
              {
                  $ExceptionMessageList.Add("[$($ExceptionProperty.Key): $($ExceptionProperty.Value)]")
              }

            $WriteLogMessage.Invoke(2, @("$($ExceptionMessageList -Join ' ')"))

            Throw
        }
      Finally
        {
            $WriteLogMessage.Invoke(0, @("Function `'$($CmdletName)`' is completed."))
        }
  }
#endregion
