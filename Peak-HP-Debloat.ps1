#Requires -Version 5.1
<#
.SYNOPSIS
    Peak Networks - removes unneeded HP OEM software from HP business PCs.

.DESCRIPTION
    Provisioning-time cleanup for HP workstations, run through NinjaOne as SYSTEM.

    The script removes only the applications and AppX packages that are listed
    explicitly in $RemovalTargets below. It does NOT wildcard-match on HP's
    publisher name or on the AD2F1837 Microsoft Store publisher ID, it never
    removes drivers, and it never reboots the device.

    Safety checks before anything is removed:
      * The manufacturer must be HP / Hewlett-Packard, otherwise the script exits 0 (skipped).
      * The script must run elevated.
      * A Win32 match must have both an exact DisplayName on the list AND an HP/Poly publisher.
      * Anything that matches the protected list (HP Image Assistant, CMSL, drivers,
        hotkey, audio, etc.) is refused even if it is later added to the removal list
        by mistake.

    Use -WhatIf (or the NinjaOne "previewOnly" variable) to see exactly what would be removed.

.PARAMETER RemovePolyLens
    Also remove Poly Lens Desktop and Poly Lens Control Service. Default: false.
    Leave this off for clients that use Poly headsets, cameras, or speakerphones.

.PARAMETER KeepApps
    Comma-separated target names (as listed in $RemovalTargets, e.g. "HP Power Manager")
    to skip on this run.

.PARAMETER UninstallTimeoutMinutes
    Maximum time to wait for any single uninstaller. Default 15.

.EXAMPLE
    .\Peak-HP-Debloat.ps1 -WhatIf
    Preview: list everything that would be removed. Nothing is changed.

.EXAMPLE
    .\Peak-HP-Debloat.ps1
    Standard HP cleanup.

.EXAMPLE
    .\Peak-HP-Debloat.ps1 -RemovePolyLens
    Standard cleanup and Poly Lens removal.

.NOTES
    NinjaOne script variables (environment variables) are honored when the matching
    parameter is not passed on the command line:
        removePolyLens  (checkbox)  -> -RemovePolyLens
        previewOnly     (checkbox)  -> -WhatIf
        keepApps        (text)      -> -KeepApps

    Exit codes:
        0 = success, partial success, nothing to remove, or non-HP device (skipped)
        1 = cleanup fundamentally failed (every attempted removal failed, or a fatal error)
        2 = prerequisite problem (not elevated, cannot read installed software)

    Logs: C:\ProgramData\Peak Networks\Logs\HP-Debloat-yyyyMMdd-HHmmss.log (30 days retained)
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$RemovePolyLens,

    [ValidatePattern('^[\w\s\-,\.\(\)]*$')]
    [string]$KeepApps = '',

    [ValidateRange(1, 120)]
    [int]$UninstallTimeoutMinutes = 15
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

#region ---------------------------------------------------------------- Configuration

$ScriptName    = 'Peak HP Debloat'
$LogDirectory  = Join-Path $env:ProgramData 'Peak Networks\Logs'
$LogRetainDays = 30
$LogFile       = Join-Path $LogDirectory ('HP-Debloat-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# Publishers we accept for a Win32 match. A DisplayName match from any other publisher is ignored.
$HpPublisherPattern   = '^\s*(HP|HP Inc\.?|Hewlett[\s-]?Packard.*|HP Development Company.*|Bromium.*)\s*$'
$PolyPublisherPattern = '^\s*(Poly|Plantronics.*|HP|HP Inc\.?)\s*$'

<#
    Explicit removal targets.

    Win32   = exact DisplayName values from the Uninstall registry keys (case-insensitive, no wildcards).
    Appx    = exact AppX package names. Each is removed for all users AND de-provisioned so it does
              not return for new profiles.
    Order matters: Wolf Security components are removed in HP's supported order (product first,
    then its support components, then the console and the update service).
#>
$RemovalTargets = @(
    @{ Name = 'HP Wolf Security';               Optional = $false
       Win32 = @('HP Wolf Security', 'HP Wolf Security Application Support for Sure Sense',
                 'HP Wolf Security Application Support for Windows', 'HP Wolf Security Application Support for Chrome',
                 'HP Wolf Security Application Support for Office')
       Appx  = @() }
    @{ Name = 'HP Wolf Security Console';       Optional = $false
       Win32 = @('HP Wolf Security - Console', 'HP Wolf Security Console'); Appx = @() }
    @{ Name = 'HP Sure Click';                  Optional = $false; Win32 = @('HP Sure Click');                       Appx = @() }
    @{ Name = 'HP Sure Sense';                  Optional = $false
       Win32 = @('HP Sure Sense', 'HP Sure Sense Installer'); Appx = @('AD2F1837.HPSureShieldAI') }
    @{ Name = 'HP Security Update Service';     Optional = $false; Win32 = @('HP Security Update Service');          Appx = @() }
    @{ Name = 'HP Sure Run';                    Optional = $false; Win32 = @('HP Sure Run');                         Appx = @() }
    @{ Name = 'HP Sure Run Module';             Optional = $false; Win32 = @('HP Sure Run Module');                  Appx = @() }
    @{ Name = 'HP Sure Recover';                Optional = $false; Win32 = @('HP Sure Recover');                     Appx = @() }
    @{ Name = 'HP Notifications';               Optional = $false; Win32 = @('HP Notifications');                    Appx = @() }
    @{ Name = 'HP Connection Optimizer';        Optional = $false; Win32 = @('HP Connection Optimizer');             Appx = @() }
    @{ Name = 'HP Documentation';               Optional = $false; Win32 = @('HP Documentation');                    Appx = @() }
    @{ Name = 'HP Support Assistant';           Optional = $false; Win32 = @('HP Support Assistant');                Appx = @('AD2F1837.HPSupportAssistant') }
    @{ Name = 'HP Support Solutions Framework'; Optional = $false; Win32 = @('HP Support Solutions Framework');      Appx = @() }
    @{ Name = 'HP QuickDrop';                   Optional = $false; Win32 = @('HP QuickDrop', 'HP Quick Drop');       Appx = @('AD2F1837.HPQuickDrop') }
    @{ Name = 'HP Privacy Settings';            Optional = $false; Win32 = @('HP Privacy Settings');                 Appx = @('AD2F1837.HPPrivacySettings') }
    @{ Name = 'HP Welcome';                     Optional = $false; Win32 = @('HP Welcome');                          Appx = @('AD2F1837.HPWelcome') }
    @{ Name = 'HP JumpStarts';                  Optional = $false
       Win32 = @('HP JumpStarts', 'HP JumpStart Apps', 'HP JumpStart Bridge', 'HP JumpStart Launch'); Appx = @('AD2F1837.HPJumpStarts') }
    @{ Name = 'HP System Information';          Optional = $false; Win32 = @('HP System Information');               Appx = @('AD2F1837.HPSystemInformation') }
    @{ Name = 'HP Power Manager';               Optional = $false; Win32 = @('HP Power Manager');                    Appx = @('AD2F1837.HPPowerManager') }
    @{ Name = 'myHP';                           Optional = $false; Win32 = @('myHP');                                Appx = @('AD2F1837.myHP') }
    # Poly Lens is only removed with -RemovePolyLens.
    @{ Name = 'Poly Lens Desktop';              Optional = $true;  Win32 = @('Poly Lens Desktop', 'Poly Lens');      Appx = @() }
    @{ Name = 'Poly Lens Control Service';      Optional = $true;  Win32 = @('Poly Lens Control Service');           Appx = @() }
)

# Defense in depth: never remove anything matching these, even if it is added to the list above by mistake.
$ProtectedNamePattern = '(?i)(Image Assistant|Client Management Script Library|\bCMSL\b|Driver|Chipset|Audio|Realtek|' +
                        'Graphics|Display|Intel|AMD|NVIDIA|Network|Wireless|WLAN|Wi-?Fi|Bluetooth|Ethernet|LAN|Touchpad|' +
                        'Synaptics|Elan|Camera|Webcam|Thunderbolt|Dock|Hotkey|Programmable Key|System Event|Firmware|BIOS|' +
                        'Accelerometer|Smart Card|Fingerprint|Biometric|Hello|Pen|Presence|Universal Camera)'

#endregion

#region ---------------------------------------------------------------- Logging

function Write-PeakLog {
    <# Writes to the log file and to the output stream so NinjaOne captures it. Never returns data. #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$Level = 'INFO',
        [switch]$LogOnly
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.PadRight(7), $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -WhatIf:$false -ErrorAction Stop } catch { }
    if (-not $LogOnly) {
        switch ($Level) {
            'WARNING' { Write-Output "WARNING: $Message" }
            'ERROR'   { Write-Output "ERROR: $Message" }
            default   { Write-Output $Message }
        }
    }
}

function Initialize-Log {
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force -WhatIf:$false | Out-Null
    }
    Get-ChildItem -LiteralPath $LogDirectory -Filter 'HP-Debloat-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetainDays) } |
        Remove-Item -Force -WhatIf:$false -ErrorAction SilentlyContinue
}

#endregion

#region ---------------------------------------------------------------- Helpers (no logging, return data)

function Get-EnvSetting {
    <# Reads a NinjaOne script variable. Returns $null when it is not set. #>
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    $value = $value.Trim()
    # An empty NinjaOne text/drop-down variable can arrive as the literal string "null".
    if ($value -eq 'null') { return $null }
    return $value
}

function ConvertTo-Bool {
    param([string]$Value)
    return ($Value -match '^(?i)(1|true|yes|y|on|checked)$')
}

function Test-IsElevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DeviceInfo {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $displayVersion = $null
    try {
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($cv.PSObject.Properties['DisplayVersion']) { $displayVersion = $cv.DisplayVersion }
        elseif ($cv.PSObject.Properties['ReleaseId']) { $displayVersion = $cv.ReleaseId }
    } catch { }
    [pscustomobject]@{
        Manufacturer = ([string]$cs.Manufacturer).Trim()
        Model        = ([string]$cs.Model).Trim()
        OSCaption    = ([string]$os.Caption).Trim()
        OSVersion    = [string]$os.Version
        OSDisplay    = $displayVersion
        ComputerName = $env:COMPUTERNAME
    }
}

function Test-IsHPManufacturer {
    param([string]$Manufacturer)
    # Matches "HP", "HP Inc.", "Hewlett-Packard". Does not match "HPE" (servers).
    return ($Manufacturer -match '^\s*(HP\b|Hewlett[\s-]?Packard)')
}

function Get-InstalledWin32App {
    <# Enumerates machine-wide uninstall entries (64-bit and 32-bit views). #>
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction Stop) {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { continue }
            $get = { param($n) if ($p.PSObject.Properties[$n]) { [string]$p.$n } else { $null } }
            $displayName = & $get 'DisplayName'
            if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
            [pscustomobject]@{
                DisplayName          = $displayName.Trim()
                DisplayVersion       = & $get 'DisplayVersion'
                Publisher            = & $get 'Publisher'
                UninstallString      = & $get 'UninstallString'
                QuietUninstallString = & $get 'QuietUninstallString'
                WindowsInstaller     = ((& $get 'WindowsInstaller') -eq '1')
                SystemComponent      = ((& $get 'SystemComponent') -eq '1')
                KeyName              = $key.PSChildName
                RegistryPath         = $key.Name
                ProductGuid          = & $get 'ProductGuid'
            }
        }
    }
}

function Split-CommandLine {
    <#
        Splits an uninstall command line into executable + arguments.
        Handles: "C:\Path With Spaces\x.exe" /args, C:\Path With Spaces\x.exe /args (unquoted), and bare msiexec.
    #>
    param([string]$CommandLine)
    $cmd = $CommandLine.Trim()
    if ($cmd.StartsWith('"')) {
        $end = $cmd.IndexOf('"', 1)
        if ($end -gt 1) {
            return [pscustomobject]@{ FilePath = $cmd.Substring(1, $end - 1); Arguments = $cmd.Substring($end + 1).Trim() }
        }
    }
    # Unquoted: find the first ".exe" / ".cmd" / ".bat" and split after it, so spaces in the path survive.
    $m = [regex]::Match($cmd, '^(?<exe>.+?\.(exe|cmd|bat))(?=\s|$)(?<args>.*)$', 'IgnoreCase')
    if ($m.Success) {
        return [pscustomobject]@{ FilePath = $m.Groups['exe'].Value.Trim(); Arguments = $m.Groups['args'].Value.Trim() }
    }
    $parts = $cmd -split '\s+', 2
    return [pscustomobject]@{ FilePath = $parts[0]; Arguments = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
}

function Get-MsiProductCode {
    param($App)
    foreach ($candidate in @($App.UninstallString, $App.QuietUninstallString, $App.KeyName, $App.ProductGuid)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $m = [regex]::Match($candidate, '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}')
        if ($m.Success) { return $m.Value.ToUpperInvariant() }
    }
    return $null
}

function New-InstallShieldResponseFile {
    <#
        HP Connection Optimizer uses a non-MSI InstallShield uninstaller that only runs silently with an
        answer file. This mirrors the response file used in the homotechsual reference script.
    #>
    param($App, [string]$Path)
    $guid    = if ($App.ProductGuid) { $App.ProductGuid } else { Get-MsiProductCode -App $App }
    $version = $App.DisplayVersion
    if (-not $guid) { return $false }
    $iss = @"
[InstallShield Silent]
Version=v7.00
File=Response File
[File Transfer]
OverwrittenReadOnly=NoToAll
[-DlgOrder]
Dlg0=$guid-SdWelcomeMaint-0
Count=3
Dlg1=$guid-MessageBox-0
Dlg2=$guid-SdFinishReboot-0
[$guid-SdWelcomeMaint-0]
Result=303
[$guid-MessageBox-0]
Result=6
[Application]
Name=HP Connection Optimizer
Version=$version
Company=HP Inc.
Lang=0409
[$guid-SdFinishReboot-0]
Result=1
BootOption=0
"@
    Set-Content -LiteralPath $Path -Value $iss -Encoding ASCII -Force -WhatIf:$false
    return $true
}

function Get-UninstallPlan {
    <#
        Decides HOW to uninstall a Win32 app. Returns $null if there is no known silent method,
        so we never launch an interactive uninstaller as SYSTEM.
    #>
    param($App, [string]$TempDirectory, [string]$MsiLogPath)

    $productCode = Get-MsiProductCode -App $App
    $uninst      = [string]$App.UninstallString
    $isMsi       = $App.WindowsInstaller -or ($uninst -match '(?i)msiexec')

    # 1. MSI: always use our own /x command so we control /qn and /norestart.
    if ($isMsi -and $productCode) {
        return [pscustomobject]@{
            Method    = 'MSI'
            FilePath  = Join-Path $env:SystemRoot 'System32\msiexec.exe'
            Arguments = ('/x {0} /qn /norestart REBOOT=ReallySuppress /l*v "{1}"' -f $productCode, $MsiLogPath)
        }
    }

    # 2. Known special case: HP Connection Optimizer (InstallShield, needs an answer file).
    if ($App.DisplayName -eq 'HP Connection Optimizer' -and $uninst) {
        $issPath = Join-Path $TempDirectory 'HPConnectionOptimizer.iss'
        if (New-InstallShieldResponseFile -App $App -Path $issPath) {
            # As in the reference script, the original InstallShield switches (-runfromtemp etc.) are replaced:
            # -runfromtemp makes setup.exe hand off and exit early, which would defeat the wait/verify step.
            $split = Split-CommandLine -CommandLine $uninst
            return [pscustomobject]@{
                Method    = 'InstallShield (response file)'
                FilePath  = $split.FilePath
                Arguments = ('/s /f1"{0}"' -f $issPath)
            }
        }
    }

    # 3. Vendor-supplied quiet uninstall string.
    if (-not [string]::IsNullOrWhiteSpace($App.QuietUninstallString)) {
        $split = Split-CommandLine -CommandLine $App.QuietUninstallString
        return [pscustomobject]@{ Method = 'QuietUninstallString'; FilePath = $split.FilePath; Arguments = $split.Arguments }
    }

    if ([string]::IsNullOrWhiteSpace($uninst)) { return $null }
    $split = Split-CommandLine -CommandLine $uninst
    $leaf  = [regex]::Match($split.FilePath, '[^\\/]+$').Value

    # 4. Inno Setup uninstallers (unins000.exe) have well-known silent switches.
    if ($leaf -match '(?i)^unins\d{3}\.exe$') {
        return [pscustomobject]@{
            Method    = 'Inno Setup'
            FilePath  = $split.FilePath
            Arguments = ('{0} /VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -f $split.Arguments).Trim()
        }
    }

    # 5. Uninstall scripts (e.g. HP Documentation's Doc_Uninstall.cmd) take no UI switches.
    if ($leaf -match '(?i)\.(cmd|bat)$') {
        return [pscustomobject]@{
            Method    = 'Uninstall script'
            FilePath  = Join-Path $env:SystemRoot 'System32\cmd.exe'
            Arguments = ('/c "{0}"' -f $(if ($split.Arguments) { '"{0}" {1}' -f $split.FilePath, $split.Arguments } else { '"{0}"' -f $split.FilePath }))
        }
    }

    # 5b. Same, when the vendor already wrapped the script in cmd, e.g. HP Documentation:
    #     CMD /C "C:\Program Files\HP\Documentation\Doc_Uninstall.cmd"
    if ($leaf -match '(?i)^cmd(\.exe)?$' -and $split.Arguments -match '(?i)^/c\s+"?[^"]+\.(cmd|bat)"?\s*$') {
        return [pscustomobject]@{
            Method    = 'Uninstall script'
            FilePath  = Join-Path $env:SystemRoot 'System32\cmd.exe'
            Arguments = $split.Arguments
        }
    }

    # 6. Uninstall strings that already carry a silent switch.
    if ($split.Arguments -match '(?i)(^|\s)(/s|/silent|/quiet|/qn|-silent|-s|/verysilent|--silent|--quiet)(\s|$)') {
        return [pscustomobject]@{ Method = 'EXE (silent switch present)'; FilePath = $split.FilePath; Arguments = $split.Arguments }
    }

    # Unknown EXE: do not guess /quiet - an interactive uninstaller would hang as SYSTEM.
    return $null
}

function Invoke-ProcessWithTimeout {
    <# Runs a process hidden with a hard timeout. Kills the process tree on timeout. #>
    param([string]$FilePath, [string]$Arguments, [int]$TimeoutSeconds)
    $startArgs = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden'; ErrorAction = 'Stop' }
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) { $startArgs.ArgumentList = $Arguments }
    $proc = Start-Process @startArgs
    $null = $proc.Handle   # Caches the handle so ExitCode is available in Windows PowerShell 5.1.
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
        return [pscustomobject]@{ ExitCode = $null; TimedOut = $true }
    }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; TimedOut = $false }
}

function Test-PendingReboot {
    $reasons = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('Component Based Servicing')
    }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('Windows Update')
    }
    return ,$reasons
}

#endregion

#region ---------------------------------------------------------------- Main

function Invoke-Main {
    <#
        Writes status to the output stream and sets $script:ExitCode. It deliberately returns no data,
        so nothing written with Write-Output is captured by the caller instead of reaching NinjaOne.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [bool]$RemovePoly,
        [bool]$Preview,
        [string[]]$Keep
    )
    $script:ExitCode = 0
    Initialize-Log

    Write-Output '=================================================='
    Write-Output $ScriptName
    Write-Output '=================================================='
    Write-PeakLog "Log file: $LogFile"
    if ($Preview) { Write-PeakLog 'MODE: PREVIEW (-WhatIf). Nothing will be removed.' }

    # Device information and HP check
    $device = Get-DeviceInfo
    Write-PeakLog "Computer:      $($device.ComputerName)"
    Write-PeakLog "Manufacturer:  $($device.Manufacturer)"
    Write-PeakLog "Model:         $($device.Model)"
    Write-PeakLog ("Windows:       {0} {1} (build {2})" -f $device.OSCaption, $device.OSDisplay, $device.OSVersion)

    if (-not (Test-IsHPManufacturer -Manufacturer $device.Manufacturer)) {
        Write-PeakLog "SKIPPED: manufacturer '$($device.Manufacturer)' is not HP. No changes made."
        Write-Output 'Result: Skipped (not an HP device)'
        return
    }

    if (-not (Test-IsElevated)) {
        Write-PeakLog 'This script must run elevated (SYSTEM or administrator).' -Level ERROR
        Write-Output 'Result: Failed (not elevated)'
        $script:ExitCode = 2
        return
    }

    Write-PeakLog ("Remove Poly Lens: {0}" -f $(if ($RemovePoly) { 'Yes' } else { 'No (default)' }))
    if ($Keep.Count -gt 0) { Write-PeakLog ("Keeping (skipped by request): {0}" -f ($Keep -join ', ')) }

    # Build the active target list.
    $targets = @($RemovalTargets | Where-Object {
        ((-not $_.Optional) -or $RemovePoly) -and ($Keep -notcontains $_.Name)
    })

    $tempDir = Join-Path $env:TEMP ('PeakHPDebloat-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    New-Item -Path $tempDir -ItemType Directory -Force -WhatIf:$false | Out-Null

    $stats = @{ Found = 0; Removed = 0; Failed = 0; Skipped = 0; NotFound = 0; RebootRequired = $false }
    $failedItems  = New-Object System.Collections.Generic.List[string]
    $removedItems = New-Object System.Collections.Generic.List[string]

    try {
        #------------------------------------------------------------ Inventory
        try {
            $installed = @(Get-InstalledWin32App)
        } catch {
            Write-PeakLog "Unable to read installed software from the registry: $($_.Exception.Message)" -Level ERROR
            Write-Output 'Result: Failed (cannot enumerate installed software)'
            $script:ExitCode = 2
            return
        }
        Write-PeakLog ("Installed Win32 entries enumerated: {0}" -f $installed.Count) -LogOnly

        $appxAvailable = $true
        $provisioned = @(); $appxInstalled = @()
        try {
            $provisioned   = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
            $appxInstalled = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
        } catch {
            $appxAvailable = $false
            Write-PeakLog "AppX enumeration failed; AppX cleanup will be skipped: $($_.Exception.Message)" -Level WARNING
        }

        Write-Output ''
        Write-Output '--- Targeted items ---'

        foreach ($target in $targets) {
            $targetFound = $false

            #-------------------------------------------------------- Win32
            foreach ($wantedName in $target.Win32) {
                $publisherPattern = if ($target.Optional) { $PolyPublisherPattern } else { $HpPublisherPattern }
                $hits = @($installed | Where-Object {
                    $_.DisplayName -ieq $wantedName
                })
                foreach ($app in $hits) {
                    if ([string]$app.Publisher -notmatch $publisherPattern) {
                        Write-PeakLog ("[Win32] '{0}' found but publisher '{1}' is not HP/Poly - ignored." -f $app.DisplayName, $app.Publisher) -Level WARNING
                        continue
                    }
                    if ($app.DisplayName -match $ProtectedNamePattern) {
                        Write-PeakLog ("[Win32] '{0}' matches the protected list - refusing to remove." -f $app.DisplayName) -Level WARNING
                        $stats.Skipped++
                        continue
                    }
                    $targetFound = $true
                    $stats.Found++
                    Write-PeakLog ("[Win32] FOUND: {0} {1} (Publisher: {2})" -f $app.DisplayName, $app.DisplayVersion, $app.Publisher)

                    $msiLog = Join-Path $LogDirectory ('HP-Debloat-MSI-{0}-{1}.log' -f ($app.DisplayName -replace '[^\w]', ''), (Get-Date -Format 'yyyyMMdd-HHmmss'))
                    $plan = Get-UninstallPlan -App $app -TempDirectory $tempDir -MsiLogPath $msiLog
                    if (-not $plan) {
                        Write-PeakLog ("[Win32] FAILED: {0} - no known silent uninstall method (UninstallString: {1}). Not attempted to avoid an interactive prompt." -f $app.DisplayName, $app.UninstallString) -Level WARNING
                        $stats.Failed++; $failedItems.Add($app.DisplayName)
                        continue
                    }
                    Write-PeakLog ("[Win32] Method: {0} -> {1} {2}" -f $plan.Method, $plan.FilePath, $plan.Arguments) -LogOnly

                    if (-not $PSCmdlet.ShouldProcess($app.DisplayName, "Uninstall ($($plan.Method))")) {
                        Write-PeakLog ("[Win32] WOULD REMOVE: {0} via {1}" -f $app.DisplayName, $plan.Method)
                        continue
                    }

                    try {
                        $result = Invoke-ProcessWithTimeout -FilePath $plan.FilePath -Arguments $plan.Arguments -TimeoutSeconds ($UninstallTimeoutMinutes * 60)
                    } catch {
                        Write-PeakLog ("[Win32] FAILED: {0} - could not start uninstaller: {1}" -f $app.DisplayName, $_.Exception.Message) -Level WARNING
                        $stats.Failed++; $failedItems.Add($app.DisplayName)
                        continue
                    }

                    if ($result.TimedOut) {
                        Write-PeakLog ("[Win32] FAILED: {0} - uninstaller exceeded {1} minutes and was terminated." -f $app.DisplayName, $UninstallTimeoutMinutes) -Level WARNING
                        $stats.Failed++; $failedItems.Add($app.DisplayName)
                        continue
                    }

                    $code = $result.ExitCode
                    switch ($code) {
                        0       { $ok = $true }
                        3010    { $ok = $true; $stats.RebootRequired = $true }
                        1641    { $ok = $true; $stats.RebootRequired = $true }
                        1605    { $ok = $true }   # MSI: product no longer installed
                        default { $ok = $false }
                    }
                    # Confirm the uninstall entry is actually gone (EXE uninstallers sometimes exit 0 without removing).
                    Start-Sleep -Seconds 2
                    $stillThere = Test-Path -LiteralPath ('Registry::' + $app.RegistryPath)
                    if ($ok -and -not $stillThere) {
                        $msg = "[Win32] REMOVED: $($app.DisplayName) (exit $code)"
                        if ($code -in 3010, 1641) { $msg += ' - reboot required' }
                        Write-PeakLog $msg
                        $stats.Removed++; $removedItems.Add($app.DisplayName)
                        if ($plan.Method -eq 'MSI' -and (Test-Path -LiteralPath $msiLog)) { Remove-Item -LiteralPath $msiLog -Force -WhatIf:$false -ErrorAction SilentlyContinue }
                    } elseif ($ok -and $stillThere -and $code -in 3010, 1641) {
                        Write-PeakLog "[Win32] REMOVED (pending reboot): $($app.DisplayName) (exit $code)"
                        $stats.Removed++; $removedItems.Add($app.DisplayName); $stats.RebootRequired = $true
                    } else {
                        $why = if ($ok) { 'uninstaller reported success but the entry is still registered' } else { "exit code $code" }
                        $extra = if ($plan.Method -eq 'MSI') { " (MSI log: $msiLog)" } else { '' }
                        Write-PeakLog ("[Win32] FAILED: {0} - {1}{2}" -f $app.DisplayName, $why, $extra) -Level WARNING
                        $stats.Failed++; $failedItems.Add($app.DisplayName)
                    }
                }
            }

            #-------------------------------------------------------- AppX
            if ($appxAvailable) {
                foreach ($pkgName in $target.Appx) {
                    if ($pkgName -match $ProtectedNamePattern) {
                        Write-PeakLog "[AppX] '$pkgName' matches the protected list - refusing to remove." -Level WARNING
                        continue
                    }
                    $prov = @($provisioned   | Where-Object { $_.DisplayName -ieq $pkgName })
                    $inst = @($appxInstalled | Where-Object { $_.Name -ieq $pkgName })

                    foreach ($p in $prov) {
                        $targetFound = $true; $stats.Found++
                        Write-PeakLog "[AppX provisioned] FOUND: $($p.DisplayName) $($p.Version)"
                        if (-not $PSCmdlet.ShouldProcess($p.PackageName, 'Remove provisioned AppX package')) {
                            Write-PeakLog "[AppX provisioned] WOULD REMOVE: $($p.DisplayName)"
                            continue
                        }
                        try {
                            $removeArgs = @{ Online = $true; PackageName = $p.PackageName; ErrorAction = 'Stop' }
                            if ((Get-Command Remove-AppxProvisionedPackage).Parameters.ContainsKey('AllUsers')) { $removeArgs.AllUsers = $true }
                            Remove-AppxProvisionedPackage @removeArgs | Out-Null
                            Write-PeakLog "[AppX provisioned] REMOVED: $($p.DisplayName)"
                            $stats.Removed++; $removedItems.Add("$($p.DisplayName) (provisioned)")
                        } catch {
                            Write-PeakLog "[AppX provisioned] FAILED: $($p.DisplayName) - $($_.Exception.Message)" -Level WARNING
                            $stats.Failed++; $failedItems.Add("$($p.DisplayName) (provisioned)")
                        }
                    }

                    foreach ($a in $inst) {
                        $targetFound = $true; $stats.Found++
                        Write-PeakLog "[AppX installed] FOUND: $($a.Name) $($a.Version)"
                        if (-not $PSCmdlet.ShouldProcess($a.PackageFullName, 'Remove AppX package for all users')) {
                            Write-PeakLog "[AppX installed] WOULD REMOVE: $($a.Name)"
                            continue
                        }
                        try {
                            $removeArgs = @{ Package = $a.PackageFullName; ErrorAction = 'Stop' }
                            if ((Get-Command Remove-AppxPackage).Parameters.ContainsKey('AllUsers')) { $removeArgs.AllUsers = $true }
                            Remove-AppxPackage @removeArgs
                            Write-PeakLog "[AppX installed] REMOVED: $($a.Name)"
                            $stats.Removed++; $removedItems.Add("$($a.Name) (AppX)")
                        } catch {
                            Write-PeakLog "[AppX installed] FAILED: $($a.Name) - $($_.Exception.Message)" -Level WARNING
                            $stats.Failed++; $failedItems.Add("$($a.Name) (AppX)")
                        }
                    }
                }
            }

            if (-not $targetFound) {
                $stats.NotFound++
                Write-PeakLog "[--] Not found: $($target.Name)"
            }
        }

        #------------------------------------------------------------ Visibility: HP software we are NOT touching
        $knownNames = @($RemovalTargets | ForEach-Object { $_.Win32 }) | ForEach-Object { $_.ToLowerInvariant() }
        $untouched = @($installed | Where-Object {
            ([string]$_.Publisher -match $HpPublisherPattern) -and -not $_.SystemComponent -and
            ($knownNames -notcontains $_.DisplayName.ToLowerInvariant())
        } | Sort-Object DisplayName -Unique)
        if ($untouched.Count -gt 0) {
            Write-PeakLog '--- Other HP-published software left in place (not on the removal list) ---' -LogOnly:(-not $Preview)
            foreach ($u in $untouched) {
                Write-PeakLog ("    {0} {1}" -f $u.DisplayName, $u.DisplayVersion) -LogOnly:(-not $Preview)
            }
        }

        #------------------------------------------------------------ Reboot state
        $pending = Test-PendingReboot
        if ($pending.Count -gt 0) {
            $stats.RebootRequired = $true
            Write-PeakLog ("Windows reports a pending reboot: {0}" -f ($pending -join ', ')) -LogOnly
        }

        #------------------------------------------------------------ Summary
        $attempted = $stats.Removed + $stats.Failed
        if (-not $Preview -and $attempted -gt 0 -and $stats.Removed -eq 0) { $script:ExitCode = 1 }

        Write-Output ''
        Write-Output '--- Summary ---'
        Write-Output "Model: $($device.Model)"
        if ($Preview) {
            Write-Output "Items found (would be removed): $($stats.Found)"
        } else {
            Write-Output "Removed: $($stats.Removed)"
            foreach ($r in $removedItems) { Write-Output "  $r" }
            Write-Output "Failed: $($stats.Failed)"
            if ($failedItems.Count -eq 0) { Write-Output '  None' } else { foreach ($f in $failedItems) { Write-Output "  $f" } }
        }
        Write-Output "Targets not present: $($stats.NotFound)"
        if ($stats.Skipped -gt 0) { Write-Output "Protected (refused): $($stats.Skipped)" }
        Write-Output ("Reboot Required: {0}" -f $(if ($stats.RebootRequired) { 'Yes (not rebooting automatically)' } else { 'No' }))

        $resultText = if ($Preview) { 'Preview complete' }
                      elseif ($script:ExitCode -ne 0) { 'Failed (no attempted removal succeeded)' }
                      elseif ($stats.Failed -gt 0) { 'Partial success (see failures above)' }
                      else { 'Success' }
        Write-Output "Result: $resultText"
        Write-PeakLog ("Final: Found={0} Removed={1} Failed={2} NotFound={3} Reboot={4} Result={5}" -f `
            $stats.Found, $stats.Removed, $stats.Failed, $stats.NotFound, $stats.RebootRequired, $resultText) -LogOnly
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue
    }
}

#endregion

#region ---------------------------------------------------------------- Entry point

# NinjaOne can launch 32-bit PowerShell. Relaunch as 64-bit so the 64-bit registry and AppX cmdlets are used.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $native = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $native) {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        foreach ($kv in $PSBoundParameters.GetEnumerator()) {
            if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
                if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
            } else {
                $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`""
            }
        }
        & $native @argList
        exit $LASTEXITCODE
    }
}

# Resolve settings: explicit parameters win, then NinjaOne script variables, then defaults.
$resolvedRemovePoly = [bool]$RemovePolyLens
if (-not $PSBoundParameters.ContainsKey('RemovePolyLens')) {
    $v = Get-EnvSetting 'removePolyLens'
    if ($null -ne $v) { $resolvedRemovePoly = ConvertTo-Bool $v }
}
if (-not $PSBoundParameters.ContainsKey('WhatIf')) {
    $v = Get-EnvSetting 'previewOnly'
    if ($null -ne $v -and (ConvertTo-Bool $v)) { $WhatIfPreference = $true }
}
$resolvedKeep = $KeepApps
if (-not $PSBoundParameters.ContainsKey('KeepApps')) {
    $v = Get-EnvSetting 'keepApps'
    if ($null -ne $v) { $resolvedKeep = $v }
}
$resolvedKeepList = @($resolvedKeep -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$script:ExitCode = 1
try {
    Invoke-Main -RemovePoly $resolvedRemovePoly -Preview ([bool]$WhatIfPreference) -Keep $resolvedKeepList -WhatIf:([bool]$WhatIfPreference)
} catch {
    try { Write-PeakLog ("Unhandled error: {0} (line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) -Level ERROR } catch { Write-Output "ERROR: $($_.Exception.Message)" }
    Write-Output 'Result: Failed (unhandled error)'
    $script:ExitCode = 1
}
exit $script:ExitCode

#endregion
