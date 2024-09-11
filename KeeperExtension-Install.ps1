function Check-BrowserInstalled($browserName) {
    $registryPath = switch ($browserName) {
        "Chrome" { "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" }
        "Edge" { "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe" }
        default { $null }
    }
    
    if ($null -eq $registryPath) {
        Write-Host "Unknown browser: $browserName"
        return $false
    }
    
    return Test-Path $registryPath
}

function Install-BrowserExtension($browserName, $registryPath, $valueName, $extensionValue) {
    if (!(Check-BrowserInstalled $browserName)) {
        Write-Host "$browserName is not installed on this machine."
        return $false
    }

    try {
        if (!(Test-Path $registryPath)) {
            New-Item -Path $registryPath -Force | Out-Null
        }
        New-ItemProperty -Path $registryPath -Name $valueName -Value $extensionValue -PropertyType String -Force | Out-Null
        Write-Host "$browserName Extension registry entry created successfully."
        return $true
    } catch {
        Write-Host "$browserName Extension installation failed. Error: $_"
        return $false
    }
}

function Check-RegistryInstall($browserName, $registryPath, $valueName, $extensionValue) {
    if (Test-Path $registryPath) {
        $value = Get-ItemProperty -Path $registryPath -Name $valueName -ErrorAction SilentlyContinue
        if ($value -ne $null -and $value.$valueName -eq $extensionValue) {
            Write-Host "$browserName Extension is present in registry."
            return $true
        }
    }
    Write-Host "$browserName Extension is not present in registry."
    return $false
}

function Check-ExtensionFolder($browserName, $extensionId) {
    $userProfile = $env:USERPROFILE
    $extensionPath = switch ($browserName) {
        "Chrome" { "$userProfile\AppData\Local\Google\Chrome\User Data\Default\Extensions\$extensionId" }
        "Edge" { "$userProfile\AppData\Local\Microsoft\Edge\User Data\Default\Extensions\$extensionId" }
    }

    if (Test-Path $extensionPath) {
        Write-Host "$browserName extension folder exists."
        return $true
    } else {
        Write-Host "$browserName extension folder does not exist."
        return $false
    }
}

# Chrome Extension Installation and Check
$chromeRegistryPath = "HKLM:\Software\Policies\Google\Chrome\ExtensionInstallForcelist"
$chromeValueName = "1"
$chromeExtensionValue = "bfogiafebfohielmmehodmfbbebbbpei;https://clients2.google.com/service/update2/crx"
$chromeExtensionId = "bfogiafebfohielmmehodmfbbebbbpei"

$chromeInstalled = Check-BrowserInstalled "Chrome"
$chromeSuccess = $false
$chromeVerified = $false

if ($chromeInstalled) {
    $chromeSuccess = Install-BrowserExtension "Chrome" $chromeRegistryPath $chromeValueName $chromeExtensionValue
    $chromeVerified = Check-RegistryInstall "Chrome" $chromeRegistryPath $chromeValueName $chromeExtensionValue
} else {
    Write-Host "Chrome is not installed. Skipping Chrome extension installation."
}

# Edge Extension Installation and Check
$edgeRegistryPath = "HKLM:\Software\Policies\Microsoft\Edge\ExtensionInstallForcelist"
$edgeValueName = "1"
$edgeExtensionValue = "lfochlioelphaglamdcakfjemolpichk;https://edge.microsoft.com/extensionwebstorebase/v1/crx"
$edgeExtensionId = "lfochlioelphaglamdcakfjemolpichk"

$edgeInstalled = Check-BrowserInstalled "Edge"
$edgeSuccess = $false
$edgeVerified = $false

if ($edgeInstalled) {
    $edgeSuccess = Install-BrowserExtension "Edge" $edgeRegistryPath $edgeValueName $edgeExtensionValue
    $edgeVerified = Check-RegistryInstall "Edge" $edgeRegistryPath $edgeValueName $edgeExtensionValue
} else {
    Write-Host "Edge is not installed. This is unexpected as Edge should be present on all modern Windows systems."
}

# Wait and check for extension installation
$maxAttempts = 5
$attemptDelay = 60  # seconds

for ($i = 1; $i -le $maxAttempts; $i++) {
    Write-Host "Attempt $i of $maxAttempts to verify extension installation..."
    
    if ($chromeInstalled) {
        $chromeExtensionInstalled = Check-ExtensionFolder "Chrome" $chromeExtensionId
    }
    
    $edgeExtensionInstalled = Check-ExtensionFolder "Edge" $edgeExtensionId
    
    if ((!$chromeInstalled -or $chromeExtensionInstalled) -and $edgeExtensionInstalled) {
        Write-Host "All extensions are installed successfully." -ForegroundColor Green
        exit 0
    }
    
    if ($i -lt $maxAttempts) {
        Write-Host "Waiting for $attemptDelay seconds before next check..."
        Start-Sleep -Seconds $attemptDelay
    }
}

# Final check and exit
if ((!$chromeInstalled -or ($chromeSuccess -and $chromeVerified)) -and ($edgeSuccess -and $edgeVerified)) {
    Write-Host "All available browser extensions are successfully installed and verified in registry." -ForegroundColor Yellow
    Write-Host "However, the extension folders were not found after multiple checks." -ForegroundColor Yellow
    Write-Host "IMPORTANT: The browsers may need to be restarted for the extensions to be fully installed and activated." -ForegroundColor Yellow
    Write-Host "Please follow these steps:" -ForegroundColor Yellow
    Write-Host "1. Close all instances of the browser(s)" -ForegroundColor Yellow
    Write-Host "2. Reopen the browser(s)" -ForegroundColor Yellow
    Write-Host "3. Check if the extension appears in the browser UI" -ForegroundColor Yellow
    Write-Host "4. If the extension doesn't appear, please wait for a few minutes and check again" -ForegroundColor Yellow
    Write-Host "5. If the extension still doesn't appear, try signing out and signing back into the browser" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "Extension installation or verification failed for one or both browsers." -ForegroundColor Red
    if ($chromeInstalled -and (!$chromeSuccess -or !$chromeVerified)) {
        Write-Host "Chrome extension installation or verification failed." -ForegroundColor Red
    }
    if (!$edgeSuccess -or !$edgeVerified) {
        Write-Host "Edge extension installation or verification failed." -ForegroundColor Red
    }
    exit 1
}