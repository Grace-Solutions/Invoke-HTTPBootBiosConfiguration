#region Get-EndpointCertificateChain
Function Get-EndpointCertificateChain
  {
      <#
          .SYNOPSIS
          Retrieves the TLS certificate chain presented by an HTTPS endpoint and exports it to PEM format.

          .DESCRIPTION
          A synchronous TLS handshake is performed directly against the endpoint (TcpClient and SslStream) and the certificate chain is captured within the certificate validation callback. Validation always succeeds for the purposes of the capture, so untrusted, expired, or self signed endpoints can still be harvested. Each certificate within the chain is converted to PEM format by using the X509 classes, and the full chain can optionally be written to a PEM file.

          The connection is deliberately made directly (never through a proxy), because the BIOS HTTP(s) boot feature contacts the endpoint directly as well - the probe therefore represents exactly what the firmware will experience. The handshake is performed synchronously so that the capture callback executes on the calling thread, which is required for it to work within both Windows PowerShell 5.1 and PowerShell 7.

          The chain is returned leaf first. The root certificate is the last self signed certificate within the chain; when the chain does not resolve to a self signed certificate (for example when the issuing root is not present within the local certificate store), the topmost available certificate is returned as the root with a warning.

          Dell BIOS HTTP boot profile certificate import requires RSA certificates. Certificates that do not use an RSA public key (for example ECDSA) are logged with a warning, but they are still converted and exported.

          .PARAMETER URL
          The HTTPS URL of the endpoint to retrieve the certificate chain from. Only the scheme, host, and port are relevant - the path is not downloaded.

          .PARAMETER Timeout
          The maximum duration to wait for the endpoint connection and handshake. Defaults to 15 seconds.

          .PARAMETER ExportPath
          An optional file path that the full certificate chain is written to in PEM format (UTF-8 without a byte order mark).

          .PARAMETER ContinueOnError
          Return a result object with the Succeeded property set to false instead of throwing a terminating error when the chain cannot be retrieved.

          .EXAMPLE
          $GetEndpointCertificateChainResult = Get-EndpointCertificateChain -URL 'https://prod.ipxe.example.com/2PXE/boot/x64/snponly_x64.efi' -ExportPath 'C:\Windows\Temp\Chain.pem' -ContinueOnError

          Switch ($GetEndpointCertificateChainResult.Succeeded)
            {
                {($_ -eq $True)}
                  {
                      Write-Output -InputObject ($GetEndpointCertificateChainResult.RootCertificate.PEMContent)
                  }
            }

          .NOTES
          The returned object contains: Succeeded, URL, ChainList (one entry per certificate: Index, Subject, Issuer, Thumbprint, NotBefore, NotAfter, KeyAlgorithm, IsSelfSigned, PEMContent, Certificate), LeafCertificate, RootCertificate, FullChainPEM, and ExportPath.

          .LINK
          https://learn.microsoft.com/dotnet/api/system.security.cryptography.x509certificates.x509certificate2
      #>

      [CmdletBinding()]
        Param
          (
              [Parameter(Mandatory=$True)]
              [ValidateNotNullOrEmpty()]
              [Alias('U')]
              [System.URI]$URL,

              [Parameter(Mandatory=$False)]
              [ValidateNotNullOrEmpty()]
              [Alias('T')]
              [System.TimeSpan]$Timeout,

              [Parameter(Mandatory=$False)]
              [ValidateNotNullOrEmpty()]
              [Alias('EP')]
              [System.IO.FileInfo]$ExportPath,

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
                    {($Null -ieq $Timeout)}
                      {
                          [System.TimeSpan]$Timeout = [System.TimeSpan]::FromSeconds(15)
                      }
                }
            #endregion

            $OutputObjectProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
              $OutputObjectProperties.Succeeded = $False
              $OutputObjectProperties.URL = $URL
              $OutputObjectProperties.ChainList = New-Object -TypeName 'System.Collections.Generic.List[PSObject]'
              $OutputObjectProperties.LeafCertificate = $Null
              $OutputObjectProperties.RootCertificate = $Null
              $OutputObjectProperties.FullChainPEM = [System.String]::Empty
              $OutputObjectProperties.ExportPath = $Null

            Switch ($URL.Scheme -ieq 'https')
              {
                  {($_ -eq $False)}
                    {
                        Throw "The URL scheme must be https in order to retrieve a TLS certificate chain. [URL: $($URL.AbsoluteUri)]"
                    }
              }

            #region Define the PEM conversion scriptblock
              [ScriptBlock]$ConvertToPEM = {
                                               Param
                                                 (
                                                     [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
                                                 )

                                               [String]$CertificateBase64 = [System.Convert]::ToBase64String($Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))

                                               $PEMBuilder = New-Object -TypeName 'System.Text.StringBuilder'
                                                 $Null = $PEMBuilder.Append('-----BEGIN CERTIFICATE-----')
                                                 $Null = $PEMBuilder.Append("`n")

                                               For ($CertificateBase64Index = 0; $CertificateBase64Index -lt $CertificateBase64.Length; $CertificateBase64Index = $CertificateBase64Index + 64)
                                                 {
                                                     $Null = $PEMBuilder.Append($CertificateBase64.Substring($CertificateBase64Index, [System.Math]::Min(64, $CertificateBase64.Length - $CertificateBase64Index)))
                                                     $Null = $PEMBuilder.Append("`n")
                                                 }

                                                 $Null = $PEMBuilder.Append('-----END CERTIFICATE-----')

                                               Write-Output -InputObject ($PEMBuilder.ToString())
                                           }
            #endregion

            #region Perform the TLS handshake and capture the certificate chain
              $ChainCaptureList = New-Object -TypeName 'System.Collections.Generic.List[System.Security.Cryptography.X509Certificates.X509Certificate2]'

              #The callback always returns true so that untrusted, expired, or self signed endpoints can still be harvested. The certificates are cloned from their raw data so that they remain usable after the handshake completes. The closure is created within an isolated child scope so that only the capture list is captured, because within Windows PowerShell 5.1, GetNewClosure() clones every local variable including unbound validated parameters, which otherwise fails validation.
              [System.Net.Security.RemoteCertificateValidationCallback]$CertificateCaptureCallback = & {
                                                                                                           Param
                                                                                                             (
                                                                                                                 $CaptureList
                                                                                                             )

                                                                                                           #The closure is emitted as a bare expression, because Write-Output treats a script block argument as a delay-bind block and refuses it without pipeline input.
                                                                                                           ({
                                                                                                                                          Param
                                                                                                                                            (
                                                                                                                                                $SenderObject,
                                                                                                                                                $Certificate,
                                                                                                                                                $Chain,
                                                                                                                                                $SslPolicyErrors
                                                                                                                                            )

                                                                                                                                          Try
                                                                                                                                            {
                                                                                                                                                Switch (($Null -ine $Chain) -and ($Chain.ChainElements.Count -gt 0))
                                                                                                                                                  {
                                                                                                                                                      {($_ -eq $True)}
                                                                                                                                                        {
                                                                                                                                                            ForEach ($ChainElement In $Chain.ChainElements)
                                                                                                                                                              {
                                                                                                                                                                  $CaptureList.Add((New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Certificate2' -ArgumentList @(, $ChainElement.Certificate.RawData)))
                                                                                                                                                              }
                                                                                                                                                        }

                                                                                                                                                      Default
                                                                                                                                                        {
                                                                                                                                                            Switch ($Null -ine $Certificate)
                                                                                                                                                              {
                                                                                                                                                                  {($_ -eq $True)}
                                                                                                                                                                    {
                                                                                                                                                                        $CaptureList.Add((New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Certificate2' -ArgumentList @(, $Certificate.GetRawCertData())))
                                                                                                                                                                    }
                                                                                                                                                              }
                                                                                                                                                        }
                                                                                                                                                  }
                                                                                                                                            }
                                                                                                                                          Catch
                                                                                                                                            {

                                                                                                                                            }

                                                                                                                                          Write-Output -InputObject ($True)
                                                                                                                                      }.GetNewClosure())
                                                                                                       } $ChainCaptureList


              $WriteLogMessage.Invoke(0, @("Attempting to retrieve the TLS certificate chain from `"$($URL.Host):$($URL.Port)`". Please Wait..."))

              $TcpClient = New-Object -TypeName 'System.Net.Sockets.TcpClient'
                $TcpClient.ReceiveTimeout = $Timeout.TotalMilliseconds
                $TcpClient.SendTimeout = $Timeout.TotalMilliseconds

              $SslStream = $Null

              Try
                {
                    $TcpClientConnectTask = $TcpClient.ConnectAsync($URL.Host, $URL.Port)

                    Switch ($TcpClientConnectTask.Wait($Timeout.TotalMilliseconds))
                      {
                          {($_ -eq $False)}
                            {
                                Throw "A TCP connection to `"$($URL.Host):$($URL.Port)`" could not be established within $($Timeout.TotalSeconds) second(s)."
                            }
                      }

                    #The handshake is performed synchronously so that the capture callback executes on the calling thread, which is required within both Windows PowerShell 5.1 and PowerShell 7.
                    $SslStream = New-Object -TypeName 'System.Net.Security.SslStream' -ArgumentList @($TcpClient.GetStream(), $False, $CertificateCaptureCallback)
                      $SslStream.ReadTimeout = $Timeout.TotalMilliseconds
                      $SslStream.WriteTimeout = $Timeout.TotalMilliseconds

                    $Null = $SslStream.AuthenticateAsClient($URL.Host)
                }
              Finally
                {
                    Switch ($Null -ine $SslStream)
                      {
                          {($_ -eq $True)}
                            {
                                $Null = $SslStream.Dispose()
                            }
                      }

                    $Null = $TcpClient.Dispose()
                }

              Switch ($ChainCaptureList.Count -gt 0)
                {
                    {($_ -eq $False)}
                      {
                          Throw "A TLS certificate chain could not be retrieved from `"$($URL.Scheme)://$($URL.Authority)`". The endpoint may be unreachable."
                      }
                }
            #endregion

            #region Convert the captured certificate chain to PEM format
              $KeyAlgorithmOIDTable = New-Object -TypeName 'System.Collections.Generic.Dictionary[[String], [String]]'
                $KeyAlgorithmOIDTable.'1.2.840.113549.1.1.1' = 'RSA'
                $KeyAlgorithmOIDTable.'1.2.840.10045.2.1' = 'ECDSA'
                $KeyAlgorithmOIDTable.'1.2.840.10040.4.1' = 'DSA'

              $FullChainPEMBuilder = New-Object -TypeName 'System.Text.StringBuilder'

              For ($ChainCaptureListIndex = 0; $ChainCaptureListIndex -lt $ChainCaptureList.Count; $ChainCaptureListIndex++)
                {
                    $ChainCertificate = $ChainCaptureList[$ChainCaptureListIndex]

                    [String]$ChainCertificateKeyAlgorithm = "$($ChainCertificate.PublicKey.Oid.Value)"

                    Switch ($KeyAlgorithmOIDTable.ContainsKey($ChainCertificateKeyAlgorithm))
                      {
                          {($_ -eq $True)}
                            {
                                [String]$ChainCertificateKeyAlgorithm = $KeyAlgorithmOIDTable[$ChainCertificateKeyAlgorithm]
                            }
                      }

                    $ChainEntryProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                      $ChainEntryProperties.Index = $ChainCaptureListIndex
                      $ChainEntryProperties.Subject = "$($ChainCertificate.Subject)"
                      $ChainEntryProperties.Issuer = "$($ChainCertificate.Issuer)"
                      $ChainEntryProperties.Thumbprint = "$($ChainCertificate.Thumbprint)"
                      $ChainEntryProperties.NotBefore = $ChainCertificate.NotBefore
                      $ChainEntryProperties.NotAfter = $ChainCertificate.NotAfter
                      $ChainEntryProperties.KeyAlgorithm = $ChainCertificateKeyAlgorithm
                      $ChainEntryProperties.IsSelfSigned = ($ChainCertificate.Subject -ieq $ChainCertificate.Issuer)
                      $ChainEntryProperties.PEMContent = $ConvertToPEM.InvokeReturnAsIs($ChainCertificate)
                      $ChainEntryProperties.Certificate = $ChainCertificate

                    $ChainEntry = New-Object -TypeName 'System.Management.Automation.PSObject' -Property ($ChainEntryProperties)

                    $OutputObjectProperties.ChainList.Add($ChainEntry)

                    $Null = $FullChainPEMBuilder.Append($ChainEntry.PEMContent)
                    $Null = $FullChainPEMBuilder.Append("`n")

                    $WriteLogMessage.Invoke(0, @("Chain certificate $($ChainCaptureListIndex + 1) of $($ChainCaptureList.Count): [Subject: $($ChainEntry.Subject)] [Issuer: $($ChainEntry.Issuer)] [Key Algorithm: $($ChainEntry.KeyAlgorithm)] [Self Signed: $($ChainEntry.IsSelfSigned)] [Expiration: $($ChainEntry.NotAfter.ToString('o'))] [Thumbprint: $($ChainEntry.Thumbprint)]"))

                    Switch ($True)
                      {
                          {($ChainEntry.KeyAlgorithm -ine 'RSA')}
                            {
                                $WriteLogMessage.Invoke(2, @("The certificate `"$($ChainEntry.Subject)`" uses the `"$($ChainEntry.KeyAlgorithm)`" key algorithm.", "Dell BIOS HTTP boot profile certificate import requires RSA certificates, so the BIOS may reject this certificate with a `"not RSA format`" error. The certificate will still be exported."))
                            }

                          {($ChainEntry.NotAfter -lt (Get-Date))}
                            {
                                $WriteLogMessage.Invoke(2, @("The certificate `"$($ChainEntry.Subject)`" has expired. [Expiration: $($ChainEntry.NotAfter.ToString('o'))]"))
                            }
                      }
                }

              $OutputObjectProperties.FullChainPEM = $FullChainPEMBuilder.ToString()

              $OutputObjectProperties.LeafCertificate = $OutputObjectProperties.ChainList[0]
            #endregion

            #region Determine the root certificate (The last self signed certificate within the chain)
              For ($ChainListIndex = $OutputObjectProperties.ChainList.Count - 1; $ChainListIndex -ge 0; $ChainListIndex--)
                {
                    Switch (($Null -ieq $OutputObjectProperties.RootCertificate) -and ($OutputObjectProperties.ChainList[$ChainListIndex].IsSelfSigned -eq $True))
                      {
                          {($_ -eq $True)}
                            {
                                $OutputObjectProperties.RootCertificate = $OutputObjectProperties.ChainList[$ChainListIndex]
                            }
                      }
                }

              Switch ($Null -ieq $OutputObjectProperties.RootCertificate)
                {
                    {($_ -eq $True)}
                      {
                          $OutputObjectProperties.RootCertificate = $OutputObjectProperties.ChainList[$OutputObjectProperties.ChainList.Count - 1]

                          $WriteLogMessage.Invoke(2, @("The retrieved certificate chain does not resolve to a self signed root certificate. The topmost available certificate will be used instead, which may stop working when the certificate authority rotates its intermediate certificates. [Subject: $($OutputObjectProperties.RootCertificate.Subject)]"))
                      }
                }

              $WriteLogMessage.Invoke(0, @("Root Certificate: [Subject: $($OutputObjectProperties.RootCertificate.Subject)] [Key Algorithm: $($OutputObjectProperties.RootCertificate.KeyAlgorithm)] [Thumbprint: $($OutputObjectProperties.RootCertificate.Thumbprint)]"))
            #endregion

            #region Export the full certificate chain to a PEM file (When requested)
              Switch (([System.String]::IsNullOrEmpty($ExportPath) -eq $False) -and ([System.String]::IsNullOrWhiteSpace($ExportPath) -eq $False))
                {
                    {($_ -eq $True)}
                      {
                          Switch ([System.IO.Directory]::Exists($ExportPath.Directory.FullName))
                            {
                                {($_ -eq $False)}
                                  {
                                      $Null = [System.IO.Directory]::CreateDirectory($ExportPath.Directory.FullName)
                                  }
                            }

                          $WriteLogMessage.Invoke(0, @("Attempting to export the full certificate chain to `"$($ExportPath.FullName)`". Please Wait..."))

                          $Null = [System.IO.File]::WriteAllText("$($ExportPath.FullName)", $OutputObjectProperties.FullChainPEM, (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($False)))

                          $OutputObjectProperties.ExportPath = $ExportPath
                      }
                }
            #endregion

            $OutputObjectProperties.Succeeded = $True

            Write-Output -InputObject (New-Object -TypeName 'System.Management.Automation.PSObject' -Property ($OutputObjectProperties))
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

            Switch ($ContinueOnError.IsPresent)
              {
                  {($_ -eq $True)}
                    {
                        Write-Output -InputObject (New-Object -TypeName 'System.Management.Automation.PSObject' -Property ($OutputObjectProperties))
                    }

                  Default
                    {
                        Throw
                    }
              }
        }
      Finally
        {
            $WriteLogMessage.Invoke(0, @("Function `'$($CmdletName)`' is completed."))
        }
  }
#endregion
