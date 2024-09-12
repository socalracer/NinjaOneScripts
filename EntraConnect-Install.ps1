# Script to download and install Microsoft Entra Connect

# Import required modules
Import-Module BitsTransfer

# URL for Microsoft Entra Connect download
$url = "https://download.microsoft.com/download/B/0/0/B00291D0-5A83-4DE7-86F5-980BC00DE05A/AzureADConnect.msi"

# Destination path for the downloaded file
$destination = "$env:TEMP\AzureADConnect.msi"

# Download the Microsoft Entra Connect installer
Write-Host "Downloading Microsoft Entra Connect..."
Start-BitsTransfer -Source $url -Destination $destination

# Check if the download was successful
if (Test-Path $destination) {
    Write-Host "Download completed successfully."
    
    # Install Microsoft Entra Connect
    Write-Host "Installing Microsoft Entra Connect..."
    Start-Process msiexec.exe -Wait -ArgumentList "/i $destination /qn"
    
    # Check installation status
    if ($?) {
        Write-Host "Microsoft Entra Connect installed successfully."
    } else {
        Write-Host "Failed to install Microsoft Entra Connect. Please check the logs for more information."
    }
    
    # Clean up the downloaded file
    Remove-Item $destination -Force
} else {
    Write-Host "Failed to download Microsoft Entra Connect. Please check your internet connection and try again."
}
