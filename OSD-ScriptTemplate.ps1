#Requires -Version 5

<#
    .SYNOPSIS
    A short synopsis of of what the script does
          
    .DESCRIPTION
    A meaningful description of what the script does
          
    .PARAMETER TaskSequenceVariables
    One or more task sequence variable(s) to retrieve during task sequence execution.
    If this parameter is not specified, all task sequence variable(s) will be stored into the variable 'TSVariableTable'.
    Any task sequence variables that are new or have been updated will be saved back to the task sequence engine for futher usage.

    $TSVariable.MyCustomVariableName = "MyCustomVariableValue"
    $TSVariable.Make = "MyDeviceModel"

    .PARAMETER LogDir
    A valid folder path. If the folder does not exist, it will be created. This parameter can also be specified by the alias "LogPath".

    .PARAMETER ContinueOnError
    Ignore failures.
          
    .EXAMPLE
    Use this command to execute a VBSCript that will launch this powershell script automatically with the specified parameters. This is useful to avoid powershell execution complexities.
    
    cscript.exe /nologo "%FolderPathContainingScript%\%ScriptName%.vbs" /SwitchParameter /ScriptParameter:"%ScriptParameterValue%" /ScriptParameterArray:"%ScriptParameterValue1%,%ScriptParameterValue2%"

    wscript.exe /nologo "%FolderPathContainingScript%\%ScriptName%.vbs" /SwitchParameter /ScriptParameter:"%ScriptParameterValue%" /ScriptParameterArray:"%ScriptParameterValue1%,%ScriptParameterValue2%"

    .EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -NoLogo -File "%FolderPathContainingScript%\%ScriptName%.ps1" -SwitchParameter -ScriptParameter "%ScriptParameterValue%"

    .EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NonInteractive -NoProfile -NoLogo -WindowStyle Hidden -Command "& '%FolderPathContainingScript%\%ScriptName%.ps1' -ScriptParameter1 '%ScriptParameter1Value%' -ScriptParameter2 %ScriptParameter2Value% -SwitchParameter"
  
    .NOTES
    Any useful tidbits
          
    .LINK
    A useful link    
#>

[CmdletBinding(SupportsShouldProcess=$True)]
  Param
    (        	     
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
                          {([System.String]::IsNullOrEmpty($ExampleVariable) -eq $True) -or ([System.String]::IsNullOrWhiteSpace($ExampleVariable) -eq $True)}
                            {

                            }
                      }
                  #endregion

                  #region Perform Script Actions
                    #Place custom code here
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