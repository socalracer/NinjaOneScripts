#Requires -Version 5.1
<#
.SYNOPSIS
    Runs a script the way NinjaOne does: no command-line parameters, options supplied only as
    environment variables (NinjaOne Script Variables), 64-bit Windows PowerShell, exit code reported.

.PARAMETER ScriptPath
    Path to the script to run.

.PARAMETER Variables
    Hashtable of NinjaOne Script Variable values, keyed by the variable's calculated (camelCase)
    name. Values are passed as strings, exactly as NinjaOne does (checkbox = 'true'/'false').

.PARAMETER Use32Bit
    Run under 32-bit Windows PowerShell, to test a script's 64-bit relaunch logic.

.EXAMPLE
    .\Invoke-AsNinja.ps1 -ScriptPath ..\..\..\..\Peak-HP-Update.ps1 -Variables @{ scanOnly = 'true' }

.EXAMPLE
    .\Invoke-AsNinja.ps1 -ScriptPath C:\Scripts\Peak-HP-Debloat.ps1 -Variables @{ previewOnly = 'true' }

.NOTES
    Run from an elevated prompt. For a true SYSTEM context, launch the prompt with
    psexec -s -i powershell.exe first. Environment variables are set only for the child process.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [hashtable]$Variables = @{},
    [switch]$Use32Bit
)

$ErrorActionPreference = 'Stop'
$full = (Resolve-Path -LiteralPath $ScriptPath).Path

$exe = if ($Use32Bit) {
    Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
} elseif ([Environment]::Is64BitProcess) {
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
} else {
    Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $full
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
foreach ($k in $Variables.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Variables[$k] }

Write-Output ('Running {0} as NinjaOne would ({1})' -f $full, $(if ($Use32Bit) { '32-bit' } else { '64-bit' }))
foreach ($k in ($Variables.Keys | Sort-Object)) { Write-Output ('  $env:{0} = "{1}"' -f $k, $Variables[$k]) }
Write-Output ('-' * 60)

$proc = [System.Diagnostics.Process]::Start($psi)
$stderr = $proc.StandardError.ReadToEndAsync()
while (-not $proc.StandardOutput.EndOfStream) { Write-Output $proc.StandardOutput.ReadLine() }
$proc.WaitForExit()
$err = $stderr.Result
if ($err) { Write-Output '--- stderr ---'; Write-Output $err }

Write-Output ('-' * 60)
Write-Output ('Exit code: {0} ({1})' -f $proc.ExitCode, $(switch ($proc.ExitCode) { 0 { 'NinjaOne: success' } default { 'NinjaOne: failure' } }))
exit $proc.ExitCode
