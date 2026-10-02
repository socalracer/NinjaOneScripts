#Requires -Version 5.1
<#
.SYNOPSIS
    Peak Networks - HP BIOS / firmware / driver maintenance using HP Image Assistant (HPIA).

.DESCRIPTION
    HP equivalent of our Dell Command Update automation. Designed to run repeatedly through
    NinjaOne as SYSTEM with no user logged on.

    Flow:
      1. Verify the device is HP (non-HP devices exit 0, skipped).
      2. Make sure the current HP Image Assistant is present in <WorkingDirectory>\bin.
         The latest version is discovered from HP's own HPIA update manifest every run and HPIA is
         only re-downloaded when the installed copy is older. HP CMSL (Install-HPImageAssistant)
         is used when it is available; otherwise HPIA is downloaded from the URL HP publishes in
         the manifest. Every downloaded binary must carry a valid HP Inc. Authenticode signature.
      3. Run a fresh HPIA analysis (never re-uses an old recommendation file).
      4. Filter the recommendations: categories BIOS / Drivers / Firmware only, Critical and
         Recommended only (Routine = "optional" only with -IncludeOptional), minus any SoftPaq IDs
         in -ExcludedSoftPaqIDs, minus HP applications we deliberately do not deploy.
      5. Have HPIA install exactly that list, with a hard timeout.
      6. Parse HPIA's report, detect reboot requirements, and report a concise summary.

    The script never reboots, never changes BIOS settings, never touches BitLocker, Secure Boot, or
    Windows Update policy, and never installs HP Support Assistant, Wolf Security, or other HP apps.

.PARAMETER ScanOnly
    Analyze and report only. Nothing is downloaded or installed.

.PARAMETER IncludeOptional
    Also install HPIA "Routine" (optional) updates.

.PARAMETER ExcludeBIOS
    Do not scan for or install BIOS updates.

.PARAMETER ExcludeFirmware
    Do not scan for or install firmware updates (Thunderbolt, dock, storage, etc.).

.PARAMETER ExcludedSoftPaqIDs
    Comma/semicolon/space separated SoftPaq IDs (e.g. "sp123456,sp654321") to exclude from
    reporting and installation.

.PARAMETER WorkingDirectory
    HPIA binaries, reports and temporary downloads. Default: C:\ProgramData\Peak Networks\HPIA

.PARAMETER HPIASource
    Auto   (default) use HP CMSL if it is already installed, otherwise HP's published download.
    CMSL   install the HPCMSL module if needed and use Install-HPImageAssistant (falls back to Direct).
    Direct use HP's published HPIA download only (no PowerShell module changes).

.PARAMETER TimeoutMinutes
    Hard limit for any single HPIA run. Default 60. Total HPIA time is capped at twice this value.

.PARAMETER StatusField
    NinjaOne custom field (text) to receive a one-line status. Only used when Ninja-Property-Set
    exists. Set to an empty string to disable. Default: hpUpdateStatus

.EXAMPLE
    .\Peak-HP-Update.ps1 -ScanOnly

.EXAMPLE
    .\Peak-HP-Update.ps1

.EXAMPLE
    .\Peak-HP-Update.ps1 -ExcludeBIOS

.EXAMPLE
    .\Peak-HP-Update.ps1 -IncludeOptional

.NOTES
    NinjaOne script variables (environment variables) are honored when the matching parameter is
    not passed on the command line: scanOnly, includeOptional, excludeBIOS, excludeFirmware,
    excludedSoftPaqIDs, workingDirectory, hpiaSource, timeoutMinutes, statusField.

    Exit codes:
        0 = success / nothing to do / scan complete / non-HP device skipped (reboot pending is still 0)
        1 = HPIA or update failure (an update failed, HPIA errored, or HPIA timed out)
        2 = unsupported or prerequisite problem (not elevated, HPIA unobtainable, platform not supported by HPIA)

    Log: C:\ProgramData\Peak Networks\Logs\HP-Update-yyyyMMdd-HHmmss.log (30 days retained)
    HPIA reports: <WorkingDirectory>\Reports\<timestamp>\ (30 days retained)
#>
[CmdletBinding()]
param(
    [switch]$ScanOnly,
    [switch]$IncludeOptional,
    [switch]$ExcludeBIOS,
    [switch]$ExcludeFirmware,

    [ValidatePattern('^[\sSsPp0-9,;]*$')]
    [string]$ExcludedSoftPaqIDs = '',

    [ValidateNotNullOrEmpty()]
    [string]$WorkingDirectory = (Join-Path $env:ProgramData 'Peak Networks\HPIA'),

    [ValidateSet('Auto', 'CMSL', 'Direct')]
    [string]$HPIASource = 'Auto',

    [ValidateRange(5, 240)]
    [int]$TimeoutMinutes = 60,

    [ValidatePattern('^[A-Za-z0-9_]*$')]
    [string]$StatusField = 'hpUpdateStatus'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

#region ---------------------------------------------------------------- Configuration

$ScriptName    = 'Peak HP Update'
$LogDirectory  = Join-Path $env:ProgramData 'Peak Networks\Logs'
$RetainDays    = 30
$RunStamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile       = Join-Path $LogDirectory "HP-Update-$RunStamp.log"

# HP's HPIA self-update manifest (the same feed HPIA and CMSL use to find the current release).
$HpiaManifestUrls = @(
    'https://hpia.hpcloud.hp.com/HPIAMsg.cab',
    'https://ftp.hp.com/pub/caps-softpaq/cmit/imagepal/HPIAMsg.cab'
)

# HP applications we never deploy through this script, even if HPIA offers them inside an allowed
# category. Kept in sync with the Peak-HP-Debloat.ps1 removal list.
$BlockedUpdateNamePattern = '(?i)(Support Assistant|Wolf Security|Sure Click|Sure Sense|Sure Run|Sure Recover|' +
                            '\bmyHP\b|HP Notifications|Connection Optimizer|Quick ?Drop|Privacy Settings|JumpStart|' +
                            'HP Power Manager|HP System Information|HP Welcome|HP Documentation|' +
                            'Support Solutions Framework|Security Update Service)'

# HPIA exit codes (HP Image Assistant user guide).
$HpiaExitText = @{
    0     = 'Success'
    256   = 'The analysis returned no recommendations'
    257   = 'There were no recommendations selected for the analysis'
    3010  = 'Install complete - reboot required'
    3020  = 'Install failed - one or more SoftPaq installations failed'
    4096  = 'This platform is not supported by HPIA'
    4097  = 'The parameters are invalid'
    4098  = 'There is no Internet connection'
    4102  = 'Secure connection error (TLS 1.2 or higher is required)'
    4103  = 'A complete request could not be sent to the remote server'
    4104  = 'No supported OS reference file for this platform; HPIA used a generic reference file'
    16384 = 'The reference file failed to open'
    16385 = 'The reference file is invalid'
    16386 = 'The reference file is not supported on platforms running this operating system'
    16387 = 'The reference file does not match the target System ID or OS version'
    16388 = 'HPIA encountered an error processing the reference file'
    16389 = 'HPIA could not find the reference file'
}

#endregion

#region ---------------------------------------------------------------- Logging / Ninja

function Write-PeakLog {
    <# Writes to the log file and (unless -LogOnly) to the output stream for NinjaOne. Returns no data. #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$Level = 'INFO',
        [switch]$LogOnly
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.PadRight(7), $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    if (-not $LogOnly) {
        switch ($Level) {
            'WARNING' { Write-Output "WARNING: $Message" }
            'ERROR'   { Write-Output "ERROR: $Message" }
            default   { Write-Output $Message }
        }
    }
}

function Set-NinjaStatus {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($script:Settings.StatusField)) { return }
    if (-not (Get-Command -Name 'Ninja-Property-Set' -ErrorAction SilentlyContinue)) { return }
    $value = '{0} ({1})' -f $Text, (Get-Date -Format 'yyyy-MM-dd HH:mm')
    try {
        Ninja-Property-Set $script:Settings.StatusField $value | Out-Null
        Write-PeakLog "NinjaOne field '$($script:Settings.StatusField)' set to: $value" -LogOnly
    } catch {
        Write-PeakLog "Could not set NinjaOne field '$($script:Settings.StatusField)': $($_.Exception.Message)" -Level WARNING -LogOnly
    }
}

#endregion

#region ---------------------------------------------------------------- Helpers (no logging, return data)

function Get-EnvSetting {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value.Trim()
}

function ConvertTo-Bool {
    param([string]$Value)
    return ($Value -match '^(?i)(1|true|yes|y|on|checked)$')
}

function Test-IsElevated {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsHPManufacturer {
    param([string]$Manufacturer)
    return ($Manufacturer -match '^\s*(HP\b|Hewlett[\s-]?Packard)')   # not "HPE" servers
}

function Get-DeviceInfo {
    $cs   = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $os   = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $bb   = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Manufacturer = ([string]$cs.Manufacturer).Trim()
        Model        = ([string]$cs.Model).Trim()
        PlatformId   = $(if ($bb) { [string]$bb.Product } else { '' })
        BIOSVersion  = $(if ($bios) { [string]$bios.SMBIOSBIOSVersion } else { '' })
        OSCaption    = ([string]$os.Caption).Trim()
        OSVersion    = [string]$os.Version
    }
}

function ConvertTo-SoftPaqId {
    <# "sp123456", "SP123456", "123456" -> "SP123456". Returns $null for anything else. #>
    param([string]$Value)
    if ($null -eq $Value) { return $null }
    $m = [regex]::Match($Value.Trim(), '^(?i)(sp)?(\d{4,7})$')
    if ($m.Success) { return 'SP' + $m.Groups[2].Value }
    return $null
}

function ConvertTo-LooseVersion {
    <# Normalises "5.3.7", "5.3.7.123", "5.03.007" to a comparable [version] (major.minor.build). #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $nums = @([regex]::Matches($Text, '\d+') | ForEach-Object { [int]$_.Value })
    if ($nums.Count -eq 0) { return $null }
    while ($nums.Count -lt 3) { $nums += 0 }
    return New-Object Version($nums[0], $nums[1], $nums[2])
}

function Test-HPSignature {
    <# True only for a valid Authenticode signature issued to HP Inc. / Hewlett-Packard. #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid' -or $null -eq $sig.SignerCertificate) { return $false }
    return ($sig.SignerCertificate.Subject -match '(?i)(O=|CN=)"?(HP Inc|Hewlett[\s-]?Packard)')
}

function Get-Prop {
    <# StrictMode-safe property lookup: first non-empty value among the candidate names. #>
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    }
    return $null
}

function Get-XmlText {
    param([System.Xml.XmlNode]$Node, [string]$LocalPath)
    if ($null -eq $Node) { return $null }
    $xpath = ($LocalPath -split '/' | ForEach-Object { "*[local-name()='$_']" }) -join '/'
    $n = $Node.SelectSingleNode($xpath)
    if ($n) { return $n.InnerText.Trim() }
    return $null
}

function ConvertTo-RecommendationValue {
    param([string]$Value)
    switch -Regex ([string]$Value) {
        '(?i)critical'          { return 'Critical' }
        '(?i)recommended'       { return 'Recommended' }
        '(?i)routine|optional'  { return 'Routine' }
        default                 { return 'Unknown' }
    }
}

function ConvertTo-CategoryName {
    param([string]$Value)
    switch -Regex ([string]$Value) {
        '(?i)^bios'      { return 'BIOS' }
        '(?i)^driver'    { return 'Drivers' }
        '(?i)^firmware'  { return 'Firmware' }
        '(?i)^software'  { return 'Software' }
        '(?i)^accessor'  { return 'Accessories' }
        default          { return 'Unknown' }
    }
}

function Read-HpiaReport {
    <#
        Parses the JSON (and XML, when present) report HPIA wrote to a report folder.
        Returns $null when no report exists. Recommendation items are keyed by SoftPaq ID.
    #>
    param([string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder)) { return $null }
    $jsonFile = Get-ChildItem -LiteralPath $Folder -Filter '*.json' -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $xmlFile  = Get-ChildItem -LiteralPath $Folder -Filter '*.xml' -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $jsonFile -and -not $xmlFile) { return $null }

    $items = [ordered]@{}
    $reportExit = $null
    $parseErrors = New-Object System.Collections.Generic.List[string]

    # XML first: it groups recommendations by category (<Recommendations><BIOS>, <Drivers>, ...).
    if ($xmlFile) {
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.Load($xmlFile.FullName)
            $groups = $doc.SelectNodes("//*[local-name()='Recommendations']/*")
            foreach ($group in $groups) {
                $category = ConvertTo-CategoryName $group.LocalName
                foreach ($rec in $group.SelectNodes("*[local-name()='Recommendation']")) {
                    $rawId = Get-XmlText $rec 'Solution/Softpaq/Id'
                    if (-not $rawId) { $rawId = Get-XmlText $rec 'SoftPaqNumber' }
                    if (-not $rawId -and $rec.Attributes -and $rec.Attributes['SoftPaqNumber']) { $rawId = $rec.Attributes['SoftPaqNumber'].Value }
                    $id = ConvertTo-SoftPaqId $rawId
                    if (-not $id) { continue }
                    $name = Get-XmlText $rec 'Solution/Softpaq/Name'
                    if (-not $name) { $name = Get-XmlText $rec 'TargetComponent' }
                    # First field that maps to Critical/Recommended/Routine wins (see the JSON section below).
                    $value = 'Unknown'
                    foreach ($field in 'Severity', 'RecommendationValue', 'Comments') {
                        $raw = Get-XmlText $rec $field
                        if (-not $raw -and $rec.Attributes -and $rec.Attributes[$field]) { $raw = $rec.Attributes[$field].Value }
                        if ($field -eq 'Comments' -and $raw -notmatch '^(?i)HP_(INSTALL|UPDATE)_') { continue }
                        $value = ConvertTo-RecommendationValue $raw
                        if ($value -ne 'Unknown') { break }
                    }
                    $items[$id] = [pscustomobject]@{
                        Id                = $id
                        Name              = $name
                        Category          = $category
                        Value             = $value
                        CurrentVersion    = Get-XmlText $rec 'TargetVersion'
                        AvailableVersion  = Get-XmlText $rec 'ReferenceVersion'
                        Status            = $null
                        ReturnCode        = $null
                        ReturnDescription = $null
                    }
                }
            }
        } catch { $parseErrors.Add("XML $($xmlFile.Name): $($_.Exception.Message)") }
    }

    # JSON: recommendation value and per-item install results (Remediation).
    if ($jsonFile) {
        try {
            $json = Get-Content -LiteralPath $jsonFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            $root = Get-Prop $json @('HPIA')
            if ($null -eq $root) { $root = $json }
            $reportExit = Get-Prop $root @('ExitCode')
            foreach ($rec in @(Get-Prop $root @('Recommendations'))) {
                if ($null -eq $rec) { continue }
                $rawId = Get-Prop $rec @('SoftPaqId', 'SoftpaqId', 'SoftPaqID', 'Id')
                if (-not $rawId) {
                    $sol = Get-Prop $rec @('Solution'); $sp = Get-Prop $sol @('Softpaq', 'SoftPaq')
                    $rawId = Get-Prop $sp @('Id')
                }
                $id = ConvertTo-SoftPaqId ([string]$rawId)
                if (-not $id) { continue }
                $rem = Get-Prop $rec @('Remediation')
                $existing = $null
                if ($items.Contains($id)) { $existing = $items[$id] }
                # HPIA reports the release type in Severity (e.g. RELEASE_TYPE_CRITICAL). RecommendationValue and
                # Comments (e.g. HP_UPDATE_RECOMMENDED) are fallbacks. A field holding something else (e.g. a
                # version string) maps to 'Unknown' and is skipped.
                $value = 'Unknown'
                foreach ($field in 'Severity', 'RecommendationValue', 'Recommendation', 'Comments') {
                    $raw = [string](Get-Prop $rec @($field))
                    if ($field -eq 'Comments' -and $raw -notmatch '^(?i)HP_(INSTALL|UPDATE)_') { continue }
                    $value = ConvertTo-RecommendationValue $raw
                    if ($value -ne 'Unknown') { break }
                }
                $category = ConvertTo-CategoryName ([string](Get-Prop $rec @('Category', 'SoftPaqCategory', 'Type')))
                $item = if ($existing) { $existing } else {
                    [pscustomobject]@{
                        Id = $id; Name = $null; Category = 'Unknown'; Value = 'Unknown'
                        CurrentVersion = $null; AvailableVersion = $null
                        Status = $null; ReturnCode = $null; ReturnDescription = $null
                    }
                }
                if (-not $item.Name) { $item.Name = [string](Get-Prop $rec @('Name', 'TargetComponent', 'SoftPaqName')) }
                if ($value -ne 'Unknown') { $item.Value = $value }
                if ($item.Category -eq 'Unknown' -and $category -ne 'Unknown') { $item.Category = $category }
                if (-not $item.CurrentVersion)   { $item.CurrentVersion   = [string](Get-Prop $rec @('TargetVersion')) }
                if (-not $item.AvailableVersion) { $item.AvailableVersion = [string](Get-Prop $rec @('ReferenceVersion')) }
                if ($rem) {
                    $item.Status            = [string](Get-Prop $rem @('Status'))
                    $rc                     = Get-Prop $rem @('ReturnCode')
                    if ($null -ne $rc -and "$rc" -match '^-?\d+$') { $item.ReturnCode = [int64]"$rc" }
                    $item.ReturnDescription = [string](Get-Prop $rem @('ReturnDescription'))
                }
                $items[$id] = $item
            }
        } catch { $parseErrors.Add("JSON $($jsonFile.Name): $($_.Exception.Message)") }
    }

    [pscustomobject]@{
        Folder     = $Folder
        JsonFile   = $(if ($jsonFile) { $jsonFile.FullName } else { $null })
        XmlFile    = $(if ($xmlFile) { $xmlFile.FullName } else { $null })
        ExitCode   = $reportExit
        Items      = @($items.Values)
        Errors     = @($parseErrors)
    }
}

function Invoke-ProcessWithTimeout {
    <# Runs a process hidden with a hard timeout; kills the whole process tree on timeout. #>
    param([string]$FilePath, [string]$Arguments, [int]$TimeoutSeconds, [string]$WorkingDirectory)
    $startArgs = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden'; ErrorAction = 'Stop' }
    if ($Arguments) { $startArgs.ArgumentList = $Arguments }
    if ($WorkingDirectory) { $startArgs.WorkingDirectory = $WorkingDirectory }
    $started = Get-Date
    $proc = Start-Process @startArgs
    $null = $proc.Handle   # cache the handle so ExitCode is populated in Windows PowerShell 5.1
    $timedOut = -not $proc.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
    if ($timedOut) {
        try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
    }
    [pscustomobject]@{
        ExitCode = $(if ($timedOut) { $null } else { $proc.ExitCode })
        TimedOut = $timedOut
        Minutes  = [Math]::Round(((Get-Date) - $started).TotalMinutes, 1)
    }
}

function Get-PendingRebootState {
    $sources = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $sources.Add('Component Based Servicing RebootPending')
    }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $sources.Add('Windows Update RebootRequired')
    }
    $pfro = $false
    try {
        $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        if ($sm.PSObject.Properties['PendingFileRenameOperations'] -and @($sm.PendingFileRenameOperations | Where-Object { $_ }).Count -gt 0) { $pfro = $true }
    } catch { }
    [pscustomobject]@{ Sources = @($sources); PendingFileRename = $pfro }
}

function Get-PowerSummary {
    try {
        $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
        if ($batteries.Count -eq 0) { return 'AC (no battery)' }
        $b = $batteries[0]
        $onAc = ($b.BatteryStatus -in 2, 3, 6, 7, 8, 9, 11)
        return ('{0}, battery {1}%' -f $(if ($onAc) { 'AC power' } else { 'ON BATTERY' }), $b.EstimatedChargeRemaining)
    } catch { return 'unknown' }
}

function Get-BitLockerSummary {
    <# Read-only. Reports OS-volume protection so a suspended state after a BIOS update is visible in the log. #>
    try {
        $vol = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
                -Filter ("DriveLetter='{0}'" -f $env:SystemDrive) -ErrorAction Stop
        if (-not $vol) { return 'not available' }
        switch ([int]$vol.ProtectionStatus) { 0 { 'Protection Off / suspended' } 1 { 'Protection On' } default { 'Unknown' } }
    } catch { return 'not available' }
}

#endregion

#region ---------------------------------------------------------------- HPIA acquisition

function Get-HpiaLatestRelease {
    <# Reads HP's HPIA manifest. Returns @{Version; Url} or throws. #>
    param([string]$TempDirectory)
    $cab = Join-Path $TempDirectory 'HPIAMsg.cab'
    $extractDir = Join-Path $TempDirectory 'HPIAMsg'
    $lastError = $null
    foreach ($url in $HpiaManifestUrls) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $cab -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            break
        } catch { $lastError = $_.Exception.Message; Remove-Item -LiteralPath $cab -Force -ErrorAction SilentlyContinue }
    }
    if (-not (Test-Path -LiteralPath $cab)) { throw "Unable to download the HPIA manifest: $lastError" }

    New-Item -Path $extractDir -ItemType Directory -Force | Out-Null
    $expand = Join-Path $env:SystemRoot 'System32\expand.exe'
    & $expand $cab '-F:*' $extractDir 2>&1 | Out-Null
    $xmlFile = Get-ChildItem -LiteralPath $extractDir -Filter '*.xml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $xmlFile) { throw 'The HPIA manifest could not be extracted.' }

    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($xmlFile.FullName)
    $latest  = $doc.SelectSingleNode("//*[local-name()='HPIALatest']")
    $version = Get-XmlText $latest 'Version'
    $url     = Get-XmlText $latest 'SoftpaqURL'
    if (-not $version -or -not $url) { throw 'The HPIA manifest did not contain a version/URL.' }
    if ($url -notmatch '^(?i)https?://') { $url = 'https://' + $url.TrimStart('/') }
    $url = $url -replace '^(?i)http://', 'https://'
    $uri = [Uri]$url
    if ($uri.Host -notmatch '(?i)(^|\.)hp\.com$' -and $uri.Host -notmatch '(?i)(^|\.)hpcloud\.hp\.com$') {
        throw "Refusing HPIA download from unexpected host '$($uri.Host)'."
    }
    [pscustomobject]@{ Version = $version; Url = $url }
}

function Get-InstalledHpiaVersion {
    param([string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
    $vi = (Get-Item -LiteralPath $ExePath).VersionInfo
    $text = if ($vi.ProductVersion) { $vi.ProductVersion } else { $vi.FileVersion }
    return [pscustomobject]@{ Text = $text; Version = (ConvertTo-LooseVersion $text) }
}

function Install-HpiaWithCmsl {
    <# Uses HP CMSL Install-HPImageAssistant to extract HPIA into $Destination. Logs; returns nothing. #>
    param([string]$Destination, [bool]$InstallModuleIfMissing)

    $cmd = Get-Command -Name 'Install-HPImageAssistant' -ErrorAction SilentlyContinue
    if (-not $cmd -and $InstallModuleIfMissing) {
        Write-PeakLog 'HP CMSL not found. Installing the HPCMSL module from the PowerShell Gallery (AllUsers).'
        $nuget = Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -eq 'NuGet' -and $_.Version -ge [version]'2.8.5.201' }
        if (-not $nuget) {
            Write-PeakLog 'NuGet package provider missing - installing it (required by Install-Module).'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope AllUsers -Force -ErrorAction Stop | Out-Null
        }
        # -Force installs from PSGallery without prompting and WITHOUT changing the repository's trust policy.
        $im = @{ Name = 'HPCMSL'; Scope = 'AllUsers'; Force = $true; AllowClobber = $true; Repository = 'PSGallery'; ErrorAction = 'Stop' }
        if ((Get-Command Install-Module).Parameters.ContainsKey('AcceptLicense')) { $im.AcceptLicense = $true }
        Install-Module @im
        $cmd = Get-Command -Name 'Install-HPImageAssistant' -ErrorAction SilentlyContinue
    }
    if (-not $cmd) { throw 'Install-HPImageAssistant (HP CMSL) is not available.' }
    foreach ($p in 'Extract', 'DestinationPath') {
        if (-not $cmd.Parameters.ContainsKey($p)) { throw "This CMSL version's Install-HPImageAssistant has no -$p parameter." }
    }
    Write-PeakLog "Obtaining HPIA via HP CMSL ($($cmd.Source) $($cmd.Version))."
    $ia = @{ Extract = $true; DestinationPath = $Destination; ErrorAction = 'Stop' }
    if ($cmd.Parameters.ContainsKey('Quiet')) { $ia.Quiet = $true }
    Install-HPImageAssistant @ia | Out-Null
}

function Install-HpiaDirect {
    <# Downloads the HPIA SoftPaq published in HP's manifest, verifies the signature, extracts it. #>
    param($Release, [string]$Destination, [string]$TempDirectory)
    $file = Join-Path $TempDirectory ([IO.Path]::GetFileName(([Uri]$Release.Url).AbsolutePath))
    Write-PeakLog "Downloading HPIA $($Release.Version) from $($Release.Url)"
    Invoke-WebRequest -Uri $Release.Url -OutFile $file -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
    if (-not (Test-HPSignature -Path $file)) {
        throw 'The downloaded HPIA package does not have a valid HP Inc. signature. It was not run.'
    }
    $r = Invoke-ProcessWithTimeout -FilePath $file -Arguments ('/s /e /f "{0}"' -f $Destination) -TimeoutSeconds 600
    if ($r.TimedOut) { throw 'Extracting the HPIA package timed out.' }
}

function Initialize-Hpia {
    <#
        Ensures <WorkingDirectory>\bin\HPImageAssistant.exe is present and current.
        Sets $script:HpiaExe / $script:HpiaVersion. Returns nothing; throws if HPIA is unobtainable.
    #>
    $binDir  = Join-Path $script:Settings.WorkingDirectory 'bin'
    $exe     = Join-Path $binDir 'HPImageAssistant.exe'
    $temp    = $script:Paths.Temp
    $current = Get-InstalledHpiaVersion -ExePath $exe

    $release = $null
    try {
        $release = Get-HpiaLatestRelease -TempDirectory $temp
        Write-PeakLog "Latest HPIA published by HP: $($release.Version)"
    } catch {
        Write-PeakLog "Could not determine the latest HPIA version: $($_.Exception.Message)" -Level WARNING
    }

    $needInstall = $true
    if ($current) {
        Write-PeakLog "Installed HPIA: $($current.Text)"
        if (-not $release) {
            Write-PeakLog 'Using the installed HPIA because the latest version could not be checked.' -Level WARNING
            $needInstall = $false
        } elseif ($current.Version -and $current.Version -ge (ConvertTo-LooseVersion $release.Version)) {
            Write-PeakLog 'HPIA is current.'
            $needInstall = $false
        } else {
            Write-PeakLog "HPIA update required ($($current.Text) -> $($release.Version))."
        }
    } else {
        Write-PeakLog 'HPIA is not installed in the working directory.'
    }

    if ($needInstall) {
        $staging = Join-Path $temp 'hpia-staging'
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $staging -ItemType Directory -Force | Out-Null
        $ok = $false
        $source = $script:Settings.HPIASource

        if ($source -eq 'CMSL' -or ($source -eq 'Auto' -and (Get-Command -Name 'Install-HPImageAssistant' -ErrorAction SilentlyContinue))) {
            try {
                Install-HpiaWithCmsl -Destination $staging -InstallModuleIfMissing ($source -eq 'CMSL')
                $ok = $true
            } catch {
                Write-PeakLog "HP CMSL method failed: $($_.Exception.Message). Falling back to HP's direct download." -Level WARNING
            }
        }
        if (-not $ok -and $release) {
            try {
                Install-HpiaDirect -Release $release -Destination $staging -TempDirectory $temp
                $ok = $true
            } catch {
                Write-PeakLog "Direct HPIA download failed: $($_.Exception.Message)" -Level WARNING
            }
        }

        $stagedExe = Get-ChildItem -LiteralPath $staging -Filter 'HPImageAssistant.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ok -and $stagedExe -and (Test-HPSignature -Path $stagedExe.FullName)) {
            # Swap in the new copy only after it is fully extracted and verified.
            if (Test-Path -LiteralPath $binDir) { Remove-Item -LiteralPath $binDir -Recurse -Force -ErrorAction Stop }
            Move-Item -LiteralPath $stagedExe.Directory.FullName -Destination $binDir -Force -ErrorAction Stop
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            $current = Get-InstalledHpiaVersion -ExePath $exe
            Write-PeakLog "HPIA $($current.Text) is ready."
        } elseif ($current) {
            Write-PeakLog 'Could not update HPIA; continuing with the installed version.' -Level WARNING
        } else {
            throw 'HP Image Assistant could not be obtained (CMSL and direct download both unavailable or unverified).'
        }
    }

    if (-not (Test-HPSignature -Path $exe)) { throw "HPImageAssistant.exe at '$exe' is not validly signed by HP. Refusing to run it." }
    $script:HpiaExe     = $exe
    $script:HpiaVersion = $current.Text
}

#endregion

#region ---------------------------------------------------------------- HPIA execution

function Invoke-Hpia {
    <#
        Runs one HPIA analysis with a fresh report folder. Returns an object with the exit code,
        timeout flag and parsed report. Does not log (the caller does).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string[]]$Category,
        [string]$Selection = 'All',
        [ValidateSet('List', 'Install')][string]$Action = 'List',
        [string]$SPListFile
    )
    $reportDir = Join-Path $script:Paths.RunReports $Label
    New-Item -Path $reportDir -ItemType Directory -Force | Out-Null

    $argParts = @(
        '/Operation:Analyze',
        ('/Category:{0}' -f ($Category -join ',')),
        ('/Selection:{0}' -f $Selection),
        ('/Action:{0}' -f $Action),
        '/Silent',
        ('/ReportFolder:"{0}"' -f $reportDir)
    )
    if ($Action -eq 'Install') { $argParts += ('/SoftpaqDownloadFolder:"{0}"' -f $script:Paths.SoftPaqs) }
    if ($SPListFile) { $argParts += ('/SPList:"{0}"' -f $SPListFile) }
    $arguments = $argParts -join ' '

    $remaining = [int]($script:HpiaDeadline - (Get-Date)).TotalSeconds
    $timeout   = [Math]::Min($script:Settings.TimeoutMinutes * 60, $remaining)
    if ($timeout -le 0) {
        return [pscustomobject]@{ Label = $Label; Arguments = $arguments; ExitCode = $null; TimedOut = $true; Minutes = 0; Report = $null }
    }

    $r = Invoke-ProcessWithTimeout -FilePath $script:HpiaExe -Arguments $arguments -TimeoutSeconds $timeout -WorkingDirectory $script:Paths.Temp
    [pscustomobject]@{
        Label     = $Label
        Arguments = $arguments
        ExitCode  = $r.ExitCode
        TimedOut  = $r.TimedOut
        Minutes   = $r.Minutes
        Report    = (Read-HpiaReport -Folder $reportDir)
    }
}

function Write-HpiaRunLog {
    param($Run)
    Write-PeakLog ("HPIA [{0}] args: {1}" -f $Run.Label, $Run.Arguments) -LogOnly
    if ($Run.TimedOut) {
        Write-PeakLog ("HPIA [{0}] exceeded the time limit and was terminated." -f $Run.Label) -Level ERROR
        return
    }
    $text = if ($HpiaExitText.ContainsKey([int]$Run.ExitCode)) { $HpiaExitText[[int]$Run.ExitCode] } else { 'Unrecognised exit code' }
    Write-PeakLog ("HPIA [{0}] finished in {1} min, exit {2}: {3}" -f $Run.Label, $Run.Minutes, $Run.ExitCode, $text) -LogOnly
    if ($Run.Report) {
        Write-PeakLog ("HPIA [{0}] report: {1} ({2} item(s))" -f $Run.Label, $Run.Report.Folder, @($Run.Report.Items).Count) -LogOnly
        foreach ($e in $Run.Report.Errors) { Write-PeakLog ("HPIA [{0}] report parse problem: {1}" -f $Run.Label, $e) -Level WARNING }
    }
}

function Test-ScanExitOk {
    param($Run)
    if ($Run.TimedOut) { return $false }
    return ([int]$Run.ExitCode -in 0, 256, 257, 4104)
}

function Get-ItemOutcome {
    <# 'Installed', 'Failed', or 'Unknown' for one item of an install report. #>
    param($Item)
    if ($null -ne $Item.ReturnCode) {
        if ($Item.ReturnCode -in 0, 3010, 1641) { return 'Installed' }
        return 'Failed'
    }
    if ($Item.Status -match '(?i)success|installed|complete') { return 'Installed' }
    if ($Item.Status -match '(?i)fail|error|cancel') { return 'Failed' }
    return 'Unknown'
}

#endregion

#region ---------------------------------------------------------------- Main

function Invoke-Main {
    $s = $script:Settings
    $script:ExitCode = 0
    $status = $null

    Write-Output '=================================================='
    Write-Output $ScriptName
    Write-Output '=================================================='
    Write-PeakLog "Log file: $LogFile"

    #------------------------------------------------------------ Device checks
    $device = Get-DeviceInfo
    Write-PeakLog "Manufacturer: $($device.Manufacturer)" -LogOnly
    Write-PeakLog "Model: $($device.Model) (platform $($device.PlatformId))"
    Write-PeakLog "BIOS: $($device.BIOSVersion)"
    Write-PeakLog "Windows: $($device.OSCaption) ($($device.OSVersion))" -LogOnly

    if (-not (Test-IsHPManufacturer -Manufacturer $device.Manufacturer)) {
        Write-PeakLog "SKIPPED: manufacturer '$($device.Manufacturer)' is not HP. No changes made."
        Write-Output 'Result: Skipped (not an HP device)'
        return
    }
    if (-not (Test-IsElevated)) {
        Write-PeakLog 'This script must run elevated (SYSTEM or administrator).' -Level ERROR
        Write-Output 'Result: Failed (not elevated)'
        $script:ExitCode = 2; return
    }
    if (Get-Process -Name 'HPImageAssistant' -ErrorAction SilentlyContinue) {
        Write-PeakLog 'HP Image Assistant is already running on this device. Not starting a second instance.' -Level ERROR
        Set-NinjaStatus 'HPIA failed - another HPIA instance was running'
        Write-Output 'Result: Failed (HPIA already running)'
        $script:ExitCode = 1; return
    }

    $categories = @('BIOS', 'Drivers', 'Firmware')
    if ($s.ExcludeBIOS)     { $categories = @($categories | Where-Object { $_ -ne 'BIOS' }) }
    if ($s.ExcludeFirmware) { $categories = @($categories | Where-Object { $_ -ne 'Firmware' }) }
    $selections = @('Critical', 'Recommended')
    if ($s.IncludeOptional) { $selections += 'Routine' }

    Write-PeakLog ("Mode: {0} | Categories: {1} | Selection: {2}" -f $(if ($s.ScanOnly) { 'Scan only' } else { 'Install' }), ($categories -join ','), ($selections -join ','))
    if ($s.ExcludedIds.Count -gt 0) { Write-PeakLog ("Excluded SoftPaqs: {0}" -f ($s.ExcludedIds -join ', ')) -LogOnly }
    Write-PeakLog "Power: $(Get-PowerSummary)" -LogOnly
    Write-PeakLog "BitLocker (OS volume) before run: $(Get-BitLockerSummary)" -LogOnly
    $preReboot = Get-PendingRebootState
    if ($preReboot.Sources.Count -gt 0) {
        Write-PeakLog ("A reboot was already pending before this run: {0}" -f ($preReboot.Sources -join ', ')) -Level WARNING
    }

    #------------------------------------------------------------ Folders
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { Write-PeakLog 'Unable to enable TLS 1.2 for this process.' -Level WARNING }

    $reportsRoot = Join-Path $s.WorkingDirectory 'Reports'
    $script:Paths = @{
        Temp       = Join-Path $s.WorkingDirectory 'Temp'
        SoftPaqs   = Join-Path $s.WorkingDirectory 'SoftPaqs'
        RunReports = Join-Path $reportsRoot $RunStamp
    }
    foreach ($leftover in @($script:Paths.Temp, $script:Paths.SoftPaqs)) {
        if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue }
    }
    foreach ($d in @($s.WorkingDirectory, $script:Paths.Temp, $script:Paths.SoftPaqs, $script:Paths.RunReports)) {
        New-Item -Path $d -ItemType Directory -Force | Out-Null
    }
    Get-ChildItem -LiteralPath $reportsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetainDays) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    try {
        #-------------------------------------------------------- HPIA
        try {
            Initialize-Hpia
        } catch {
            Write-PeakLog $_.Exception.Message -Level ERROR
            Set-NinjaStatus 'HPIA failed - HP Image Assistant unavailable'
            Write-Output 'Result: Failed (HP Image Assistant unavailable)'
            $script:ExitCode = 2; return
        }
        $script:HpiaDeadline = (Get-Date).AddMinutes($s.TimeoutMinutes * 2)

        #-------------------------------------------------------- Fresh analysis
        Write-PeakLog 'Running HPIA analysis...'
        $scan = Invoke-Hpia -Label '1-Scan' -Category $categories -Selection 'All' -Action 'List'
        Write-HpiaRunLog $scan
        if ($scan.TimedOut) {
            Set-NinjaStatus 'HPIA failed - analysis timed out'
            Write-Output 'Result: Failed (HPIA analysis timed out)'
            $script:ExitCode = 1; return
        }
        $scanExit = [int]$scan.ExitCode
        if ($scanExit -in 4096, 16386, 16387) {
            Write-PeakLog "HPIA does not support this platform/OS: $($HpiaExitText[$scanExit])" -Level ERROR
            Set-NinjaStatus 'HPIA failed - platform not supported'
            Write-Output 'Result: Failed (platform not supported by HPIA)'
            $script:ExitCode = 2; return
        }
        if (-not (Test-ScanExitOk $scan)) {
            $why = if ($HpiaExitText.ContainsKey($scanExit)) { $HpiaExitText[$scanExit] } else { "exit code $scanExit" }
            Write-PeakLog "HPIA analysis failed: $why" -Level ERROR
            Set-NinjaStatus "HPIA failed - $why"
            Write-Output 'Result: Failed (HPIA analysis error)'
            $script:ExitCode = 1; return
        }
        if ($scanExit -eq 4104) { Write-PeakLog $HpiaExitText[4104] -Level WARNING }
        if ($null -eq $scan.Report -and $scanExit -notin 256, 257) {
            Write-PeakLog 'HPIA finished but produced no readable report.' -Level ERROR
            Set-NinjaStatus 'HPIA failed - no analysis report'
            Write-Output 'Result: Failed (no HPIA report)'
            $script:ExitCode = 1; return
        }
        $found = @(); if ($scan.Report) { $found = @($scan.Report.Items) }

        # If HPIA's report did not say which selection an item belongs to, ask HPIA per selection.
        if (@($found | Where-Object { $_.Value -eq 'Unknown' }).Count -gt 0) {
            Write-PeakLog 'Classifying recommendations by selection with targeted HPIA scans...' -LogOnly
            foreach ($sel in 'Critical', 'Recommended', 'Routine') {
                $cls = Invoke-Hpia -Label "1-Scan-$sel" -Category $categories -Selection $sel -Action 'List'
                Write-HpiaRunLog $cls
                if (-not (Test-ScanExitOk $cls) -or $null -eq $cls.Report) { continue }
                $ids = @($cls.Report.Items | ForEach-Object { $_.Id })
                foreach ($it in $found) { if ($it.Value -eq 'Unknown' -and $ids -contains $it.Id) { $it.Value = $sel } }
            }
        }

        #-------------------------------------------------------- Filter
        $policyExcluded = @($found | Where-Object { $s.ExcludedIds -contains $_.Id })
        $candidates     = @($found | Where-Object { $s.ExcludedIds -notcontains $_.Id })
        $blocked        = @($candidates | Where-Object { $_.Name -match $BlockedUpdateNamePattern -or $_.Category -in 'Software', 'Accessories' })
        $candidates     = @($candidates | Where-Object { $blocked -notcontains $_ })
        $critical       = @($candidates | Where-Object { $_.Value -eq 'Critical' })
        $recommended    = @($candidates | Where-Object { $_.Value -eq 'Recommended' })
        $routine        = @($candidates | Where-Object { $_.Value -eq 'Routine' })
        $unknown        = @($candidates | Where-Object { $_.Value -eq 'Unknown' })
        $toInstall      = @($candidates | Where-Object { $selections -contains $_.Value })

        foreach ($x in $policyExcluded) { Write-PeakLog ("Excluded by policy: {0} - {1}" -f $x.Id, $x.Name) -LogOnly }
        foreach ($x in $blocked)        { Write-PeakLog ("Not deployed (HP application, not a driver/firmware): {0} - {1}" -f $x.Id, $x.Name) }
        foreach ($x in $unknown)        { Write-PeakLog ("Skipped (HPIA did not classify as Critical/Recommended/Routine): {0} - {1}" -f $x.Id, $x.Name) -Level WARNING }
        foreach ($x in $candidates) {
            Write-PeakLog ("Found [{0}/{1}] {2} - {3} | installed {4} -> available {5}" -f $x.Category, $x.Value, $x.Id, $x.Name, $x.CurrentVersion, $x.AvailableVersion) -LogOnly
        }

        $detected = $critical.Count + $recommended.Count + $(if ($s.IncludeOptional) { $routine.Count } else { 0 })

        #-------------------------------------------------------- Install
        $installed = New-Object System.Collections.Generic.List[object]
        $failed    = New-Object System.Collections.Generic.List[object]
        $unverified = New-Object System.Collections.Generic.List[object]
        $rebootRequired = $false
        $hpiaFailure = $null

        if (-not $s.ScanOnly -and $toInstall.Count -gt 0) {
            $allowedIds = @($toInstall | ForEach-Object { $_.Id })
            $installRuns = New-Object System.Collections.Generic.List[object]

            # Method A: hand HPIA the exact SoftPaq list. Verified with a List pass first, so if this HPIA
            # build ignores /SPList we find out before anything is installed.
            $spListFile = Join-Path $script:Paths.Temp 'SoftPaqList.txt'
            Set-Content -LiteralPath $spListFile -Value ($allowedIds | ForEach-Object { $_.Substring(2) }) -Encoding ASCII
            Write-PeakLog 'Verifying HPIA honours the filtered SoftPaq list...' -LogOnly
            $verify = Invoke-Hpia -Label '2-Verify-SPList' -Category $categories -Selection 'All' -Action 'List' -SPListFile $spListFile
            Write-HpiaRunLog $verify
            $verifyIds = @(); if ($verify.Report) { $verifyIds = @($verify.Report.Items | ForEach-Object { $_.Id }) }
            $spListOk = (Test-ScanExitOk $verify) -and $verifyIds.Count -gt 0 -and
                        (@($verifyIds | Where-Object { $allowedIds -notcontains $_ }).Count -eq 0)

            if ($verify.TimedOut) {
                $hpiaFailure = 'HPIA timed out'
            } elseif ($spListOk) {
                Write-PeakLog ("Installing {0} update(s)..." -f $toInstall.Count)
                $run = Invoke-Hpia -Label '3-Install' -Category $categories -Selection 'All' -Action 'Install' -SPListFile $spListFile
                Write-HpiaRunLog $run
                $installRuns.Add($run)
            } else {
                # Method B: let HPIA filter natively, one category/selection bucket at a time. A bucket is only
                # installed when HPIA's own list for it contains nothing excluded or blocked.
                Write-PeakLog 'SoftPaq list filtering not confirmed; installing per category/selection instead.' -LogOnly
                foreach ($cat in $categories) {
                    foreach ($sel in $selections) {
                        if ($hpiaFailure) { break }
                        $planned = @($toInstall | Where-Object { ($_.Category -eq $cat -or $_.Category -eq 'Unknown') -and $_.Value -eq $sel })
                        if ($planned.Count -eq 0) { continue }
                        $probe = Invoke-Hpia -Label "2-Probe-$cat-$sel" -Category @($cat) -Selection $sel -Action 'List'
                        Write-HpiaRunLog $probe
                        if ($probe.TimedOut) { $hpiaFailure = 'HPIA timed out'; break }
                        if (-not (Test-ScanExitOk $probe) -or $null -eq $probe.Report) { continue }
                        $bucket = @($probe.Report.Items)
                        $bad = @($bucket | Where-Object { $allowedIds -notcontains $_.Id })
                        if ($bad.Count -gt 0) {
                            Write-PeakLog ("Deferred {0}/{1}: contains excluded or blocked item(s) {2}; other updates in this group were not installed." -f `
                                $cat, $sel, (($bad | ForEach-Object { $_.Id }) -join ', ')) -Level WARNING
                            foreach ($b in $bucket | Where-Object { $allowedIds -contains $_.Id }) {
                                $unverified.Add([pscustomobject]@{ Id = $b.Id; Name = $b.Name; Note = 'deferred (shares a group with an excluded update)' })
                            }
                            continue
                        }
                        if ($bucket.Count -eq 0) { continue }
                        Write-PeakLog ("Installing {0} {1} update(s) ({2})..." -f $bucket.Count, $sel, $cat)
                        $run = Invoke-Hpia -Label "3-Install-$cat-$sel" -Category @($cat) -Selection $sel -Action 'Install'
                        Write-HpiaRunLog $run
                        $installRuns.Add($run)
                        if ($run.TimedOut) { $hpiaFailure = 'HPIA timed out'; break }
                    }
                }
            }

            #---------------------------------------------------- Results
            $reported = @{}
            foreach ($run in $installRuns) {
                if ($run.TimedOut) { $hpiaFailure = 'HPIA timed out'; continue }
                $code = [int]$run.ExitCode
                if ($code -eq 3010) { $rebootRequired = $true }
                if ($code -notin 0, 256, 257, 3010, 3020, 4104) {
                    $hpiaFailure = if ($HpiaExitText.ContainsKey($code)) { $HpiaExitText[$code] } else { "HPIA exit code $code" }
                }
                if ($run.Report) {
                    foreach ($it in $run.Report.Items) {
                        if ($allowedIds -notcontains $it.Id) {
                            $outcome = Get-ItemOutcome $it
                            if ($outcome -eq 'Installed') {
                                Write-PeakLog ("HPIA installed {0} - {1}, which was NOT in the approved list." -f $it.Id, $it.Name) -Level ERROR
                                $hpiaFailure = 'HPIA installed an unapproved update'
                            }
                            continue
                        }
                        $reported[$it.Id] = @{ Item = $it; ExitCode = $code }
                    }
                }
            }

            foreach ($plan in $toInstall) {
                if ($unverified | Where-Object { $_.Id -eq $plan.Id }) { continue }
                if (-not $reported.ContainsKey($plan.Id)) {
                    $unverified.Add([pscustomobject]@{ Id = $plan.Id; Name = $plan.Name; Note = 'not in HPIA install report' })
                    continue
                }
                $entry   = $reported[$plan.Id]
                $outcome = Get-ItemOutcome $entry.Item
                if ($outcome -eq 'Unknown') {
                    $outcome = if ($entry.ExitCode -in 0, 3010) { 'Installed' } else { 'Failed' }
                }
                $rc = $entry.Item.ReturnCode
                if ($outcome -eq 'Installed') {
                    $installed.Add($plan)
                    if ($rc -in 3010, 1641 -or $plan.Category -eq 'BIOS' -or $plan.Category -eq 'Firmware') { $rebootRequired = $true }
                    Write-PeakLog ("Installed {0} - {1} (return {2})" -f $plan.Id, $plan.Name, $rc) -LogOnly
                } else {
                    $failed.Add([pscustomobject]@{ Id = $plan.Id; Name = $plan.Name; Note = ("return {0} {1}" -f $rc, $entry.Item.ReturnDescription).Trim() })
                    Write-PeakLog ("FAILED {0} - {1}: return {2} {3}" -f $plan.Id, $plan.Name, $rc, $entry.Item.ReturnDescription) -Level WARNING -LogOnly
                }
            }
            if (@($installRuns | Where-Object { -not $_.TimedOut -and [int]$_.ExitCode -eq 3020 }).Count -gt 0 -and $failed.Count -eq 0) {
                $hpiaFailure = $HpiaExitText[3020]
            }
        }

        #-------------------------------------------------------- Reboot state
        $post = Get-PendingRebootState
        foreach ($src in $post.Sources) { $rebootRequired = $true; Write-PeakLog "Reboot signal: $src" -LogOnly }
        if ($post.PendingFileRename) { Write-PeakLog 'PendingFileRenameOperations present (informational; not counted on its own).' -LogOnly }
        if (-not $s.ScanOnly -and $installed.Count -gt 0) { Write-PeakLog "BitLocker (OS volume) after run: $(Get-BitLockerSummary)" -LogOnly }

        #-------------------------------------------------------- Summary
        $fmt = { param($x) '{0} - {1}' -f $x.Id, $x.Name }
        Write-Output ''
        Write-Output $ScriptName
        Write-Output "Model: $($device.Model)"
        Write-Output "HPIA: $script:HpiaVersion"
        Write-Output ''
        Write-Output "Updates detected: $detected"
        Write-Output "Critical: $($critical.Count)"
        Write-Output "Recommended: $($recommended.Count)"
        if ($s.IncludeOptional) { Write-Output "Optional: $($routine.Count)" } else { Write-Output "Optional ignored: $($routine.Count)" }
        if ($policyExcluded.Count -gt 0) { Write-Output "Excluded by policy: $($policyExcluded.Count)" }
        if ($blocked.Count -gt 0)        { Write-Output "HP apps not deployed: $($blocked.Count)" }

        if ($s.ScanOnly) {
            Write-Output ''
            Write-Output 'Available (not installed - scan only):'
            if ($toInstall.Count -eq 0) { Write-Output 'None' } else { foreach ($x in $toInstall) { Write-Output ("{0} [{1}/{2}]" -f (& $fmt $x), $x.Category, $x.Value) } }
        } else {
            Write-Output ''
            Write-Output 'Installed:'
            if ($installed.Count -eq 0) { Write-Output 'None' } else { foreach ($x in $installed) { Write-Output (& $fmt $x) } }
            Write-Output ''
            Write-Output 'Failed:'
            if ($failed.Count -eq 0) { Write-Output 'None' } else { foreach ($x in $failed) { Write-Output ("{0} ({1})" -f (& $fmt $x), $x.Note) } }
            if ($unverified.Count -gt 0) {
                Write-Output ''
                Write-Output 'Not installed / unverified:'
                foreach ($x in $unverified) { Write-Output ("{0} ({1})" -f (& $fmt $x), $x.Note) }
            }
            if ($hpiaFailure) { Write-Output ''; Write-Output "HPIA: $hpiaFailure" }
        }

        Write-Output ''
        Write-Output ("Reboot Required: {0}" -f $(if ($rebootRequired) { 'Yes' } else { 'No' }))

        $resultFailed = (-not $s.ScanOnly) -and ($failed.Count -gt 0 -or $hpiaFailure)
        if ($resultFailed) { $script:ExitCode = 1 }
        $resultText = if ($resultFailed) { 'Failed' }
                      elseif ($unverified.Count -gt 0) { 'Success with warnings' }
                      else { 'Success' }
        Write-Output "Result: $resultText"
        Write-Output "Log: $LogFile"

        # One-line status for NinjaOne.
        $rebootSuffix = if ($rebootRequired) { ' - reboot required' } else { '' }
        if ($s.ScanOnly) {
            if ($toInstall.Count -eq 0) { $status = 'Up to date' }
            else {
                $parts = @()
                if ($critical.Count)    { $parts += "$($critical.Count) critical" }
                if ($recommended.Count) { $parts += "$($recommended.Count) recommended" }
                if ($s.IncludeOptional -and $routine.Count) { $parts += "$($routine.Count) optional" }
                $plural = if ($toInstall.Count -eq 1) { '' } else { 's' }
                $status = if ($parts.Count -eq 1) { 'Scan found {0} update{1}' -f $parts[0], $plural }
                          else { 'Scan found {0} update{1} ({2})' -f $toInstall.Count, $plural, ($parts -join ', ') }
            }
        } elseif ($hpiaFailure -and $installed.Count -eq 0) {
            $status = "HPIA failed - $hpiaFailure"
        } elseif ($failed.Count -gt 0 -or $hpiaFailure) {
            $status = "{0} updates installed, {1} failed{2}" -f $installed.Count, [Math]::Max($failed.Count, 1), $rebootSuffix
        } elseif ($installed.Count -gt 0) {
            $status = "{0} update{1} installed{2}" -f $installed.Count, $(if ($installed.Count -eq 1) { '' } else { 's' }), $rebootSuffix
        } elseif ($toInstall.Count -eq 0) {
            $status = "Up to date$rebootSuffix"
        } else {
            $status = "No updates installed ({0} pending){1}" -f $toInstall.Count, $rebootSuffix
        }
        Set-NinjaStatus $status
        Write-PeakLog ("Final: Detected={0} Installed={1} Failed={2} Unverified={3} Reboot={4} Result={5} Status='{6}'" -f `
            $detected, $installed.Count, $failed.Count, $unverified.Count, $rebootRequired, $resultText, $status) -LogOnly
    }
    finally {
        # Remove downloads and scratch files; keep logs, HPIA binaries and HPIA reports.
        foreach ($d in @($script:Paths.Temp, $script:Paths.SoftPaqs)) {
            if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

#endregion

#region ---------------------------------------------------------------- Entry point

# NinjaOne can launch 32-bit PowerShell. Relaunch as 64-bit for consistent registry/WMI/file-system views.
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

$script:ExitCode = 1
try {
    if (-not (Test-Path -LiteralPath $LogDirectory)) { New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null }
    Get-ChildItem -LiteralPath $LogDirectory -Filter 'HP-Update-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetainDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Resolve settings: explicit parameters win, then NinjaOne script variables, then defaults.
    $bound = $PSBoundParameters
    $fromEnv = {
        param([string]$Name, [string]$EnvName, $Current)
        if ($bound.ContainsKey($Name)) { return $Current }
        $v = Get-EnvSetting $EnvName
        if ($null -ne $v) { return $v }
        return $Current
    }

    $settings = @{
        ScanOnly         = [bool]$ScanOnly
        IncludeOptional  = [bool]$IncludeOptional
        ExcludeBIOS      = [bool]$ExcludeBIOS
        ExcludeFirmware  = [bool]$ExcludeFirmware
        WorkingDirectory = [string](& $fromEnv 'WorkingDirectory' 'workingDirectory' $WorkingDirectory)
        HPIASource       = [string](& $fromEnv 'HPIASource' 'hpiaSource' $HPIASource)
        TimeoutMinutes   = $TimeoutMinutes
        StatusField      = [string](& $fromEnv 'StatusField' 'statusField' $StatusField)
        ExcludedIds      = @()
    }
    foreach ($sw in 'ScanOnly', 'IncludeOptional', 'ExcludeBIOS', 'ExcludeFirmware') {
        if (-not $bound.ContainsKey($sw)) {
            $v = Get-EnvSetting ($sw.Substring(0, 1).ToLowerInvariant() + $sw.Substring(1))
            if ($null -ne $v) { $settings[$sw] = ConvertTo-Bool $v }
        }
    }
    if (-not $bound.ContainsKey('TimeoutMinutes')) {
        $v = Get-EnvSetting 'timeoutMinutes'
        if ($v -match '^\d+$' -and [int]$v -ge 5 -and [int]$v -le 240) { $settings.TimeoutMinutes = [int]$v }
    }
    if ($settings.HPIASource -notin 'Auto', 'CMSL', 'Direct') { $settings.HPIASource = 'Auto' }
    if ($settings.StatusField -notmatch '^[A-Za-z0-9_]*$') { $settings.StatusField = 'hpUpdateStatus' }

    $rawExcluded = [string](& $fromEnv 'ExcludedSoftPaqIDs' 'excludedSoftPaqIDs' $ExcludedSoftPaqIDs)
    $badIds = @()
    foreach ($tok in @($rawExcluded -split '[,;\s]+' | Where-Object { $_ })) {
        $id = ConvertTo-SoftPaqId $tok
        if ($id) { $settings.ExcludedIds += $id } else { $badIds += $tok }
    }
    $settings.ExcludedIds = @($settings.ExcludedIds | Select-Object -Unique)
    $script:Settings = $settings

    if ($badIds.Count -gt 0) {
        Write-PeakLog ("Invalid ExcludedSoftPaqIDs value(s): {0}. Expected e.g. sp123456. Nothing was changed." -f ($badIds -join ', ')) -Level ERROR
        Write-Output 'Result: Failed (invalid ExcludedSoftPaqIDs)'
        $script:ExitCode = 2
    } else {
        Invoke-Main
    }
} catch {
    try { Write-PeakLog ("Unhandled error: {0} (line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) -Level ERROR } catch { Write-Output "ERROR: $($_.Exception.Message)" }
    try { Set-NinjaStatus 'HPIA failed - script error' } catch { }
    Write-Output 'Result: Failed (unhandled error)'
    $script:ExitCode = 1
}
exit $script:ExitCode

#endregion
