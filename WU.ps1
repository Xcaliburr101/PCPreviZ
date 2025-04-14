<#
.SYNOPSIS
Checks for available Windows driver updates using the built-in COM object
and installs them. Requires PowerShell 5.0 or higher and administrator privileges.

.DESCRIPTION
This script connects to the Windows Update service using the Microsoft.Update.Session COM object.
It searches specifically for updates classified as 'Driver' that are not currently installed.
If any driver updates are found, it proceeds to download and install them.
The script provides feedback throughout the process. It does not require any external
PowerShell modules like PSWindowsUpdate.

.NOTES
Version: 1.0
Author: CookieMonster
Requires: PowerShell 5.0+, Windows Operating System, Administrator privileges.
Date: 2025-04-14

.EXAMPLE
.\Install-DriverUpdates.ps1
Runs the script to search for, download, and install pending driver updates.
You must run this script with administrator privileges.
#>

#Requires -Version 5.0
#Requires -RunAsAdministrator

Write-Host "Starting Windows Driver Update check and installation..."

# Create a Windows Update Session object
try {
    $updateSession = New-Object -ComObject "Microsoft.Update.Session"
    Write-Host "Successfully created Update Session."
}
catch {
    Write-Error "Failed to create Microsoft.Update.Session COM object. Ensure the Windows Update service is running."
    Exit 1
}

# Create an Update Searcher object from the session
try {
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    Write-Host "Successfully created Update Searcher."
}
catch {
    Write-Error "Failed to create Update Searcher object."
    Exit 1
}

# Define the search criteria: Find drivers that are not installed and not hidden
$searchCriteria = "IsInstalled=0 and Type='Driver' and IsHidden=0"
Write-Host "Searching for driver updates using criteria: '$searchCriteria'"

try {
    # Perform the search for updates
    $searchResult = $updateSearcher.Search($searchCriteria)
    Write-Host ("Search completed. Found {0} driver update(s)." -f $searchResult.Updates.Count)
}
catch {
    Write-Error "Error searching for updates: $($_.Exception.Message)"
    # Common error code: 0x80240024 - No updates were found. This might not be an error if truly none exist.
    if ($_.Exception.ErrorCode -eq 0x80240024) {
        Write-Host "No applicable driver updates were found."
    } else {
        # Output other potential error codes/messages
        Write-Warning ("Search failed with HRESULT: {0:X}" -f $_.Exception.ErrorCode)
    }
    Exit 1 # Exit if search fails for reasons other than 'not found'
}

# Check if any updates were found
if ($searchResult.Updates.Count -eq 0) {
    Write-Host "No pending driver updates found that match the criteria."
    Exit 0
}

# Display found updates
Write-Host "The following driver updates were found:"
$searchResult.Updates | ForEach-Object { Write-Host (" - {0}" -f $_.Title) }

# Create a collection for updates to download
$updatesToDownload = New-Object -ComObject "Microsoft.Update.UpdateColl"

# Add the found updates to the download collection
$searchResult.Updates | ForEach-Object {
    # You could add more checks here, e.g., check if EULA is accepted if needed
    # if ($_.EulaAccepted -eq $false) { $_.AcceptEula() } # Uncomment if EULA acceptance is needed/causes issues
    Write-Host ("Adding update '{0}' to download list." -f $_.Title)
    $updatesToDownload.Add($_) | Out-Null
}

# Check if there are updates to download (sanity check)
if ($updatesToDownload.Count -eq 0) {
    Write-Host "No updates were added to the download list. Exiting."
    Exit 0
}

# Download the updates
Write-Host "Starting download of $($updatesToDownload.Count) driver update(s)..."
try {
    $downloader = $updateSession.CreateUpdateDownloader()
    $downloader.Updates = $updatesToDownload
    $downloadResult = $downloader.Download()

    # Check download result code
    # Result codes: 0=NotStarted, 1=InProgress, 2=Succeeded, 3=SucceededWithErrors, 4=Failed, 5=Aborted
    Write-Host ("Download Result Code: {0}" -f $downloadResult.ResultCode)

    if ($downloadResult.ResultCode -ne 2) { # 2 = Succeeded
        Write-Error "Download failed or completed with errors."
        # Optional: Loop through each update to see individual status
        for ($i = 0; $i -lt $updatesToDownload.Count; $i++) {
            $updateStatus = $downloadResult.GetUpdateResult($i)
            $updateTitle = $updatesToDownload.Item($i).Title
            Write-Host ("Status for '{0}': ResultCode={1}, HResult={2:X}" -f $updateTitle, $updateStatus.ResultCode, $updateStatus.HResult)
        }
        Exit 1
    }
    Write-Host "Download completed successfully."

}
catch {
    Write-Error "An error occurred during the download process: $($_.Exception.Message)"
    Exit 1
}

# Create a collection for updates to install (only those successfully downloaded)
$updatesToInstall = New-Object -ComObject "Microsoft.Update.UpdateColl"

# Populate the installation collection with successfully downloaded updates
Write-Host "Preparing updates for installation..."
for ($i = 0; $i -lt $searchResult.Updates.Count; $i++) {
    $update = $searchResult.Updates.Item($i)
    if ($update.IsDownloaded) {
        Write-Host ("Adding downloaded update '{0}' to installation list." -f $update.Title)
        $updatesToInstall.Add($update) | Out-Null
    } else {
        Write-Warning ("Update '{0}' was not downloaded successfully and will be skipped." -f $update.Title)
    }
}

# Check if there are updates to install
if ($updatesToInstall.Count -eq 0) {
    Write-Host "No updates are ready for installation (download might have failed or been incomplete)."
    Exit 1
}

# Install the updates
Write-Host "Starting installation of $($updatesToInstall.Count) driver update(s)... This may take some time."
try {
    $installer = $updateSession.CreateUpdateInstaller()
    $installer.Updates = $updatesToInstall
    # Note: Installation might require user interaction or fail if user is logged off, depending on update type.
    # Use $installer.Install() for synchronous installation (script waits)
    $installationResult = $installer.Install()

    # Check installation result code
    # Result codes are the same as download: 0=NotStarted, 1=InProgress, 2=Succeeded, 3=SucceededWithErrors, 4=Failed, 5=Aborted
    Write-Host ("Installation Result Code: {0}" -f $installationResult.ResultCode)

    if ($installationResult.ResultCode -ne 2) { # 2 = Succeeded
        Write-Error "Installation failed or completed with errors."
         # Optional: Loop through each update to see individual status
        for ($i = 0; $i -lt $updatesToInstall.Count; $i++) {
            $updateStatus = $installationResult.GetUpdateResult($i)
            $updateTitle = $updatesToInstall.Item($i).Title
            Write-Host ("Status for '{0}': ResultCode={1}, HResult={2:X}" -f $updateTitle, $updateStatus.ResultCode, $updateStatus.HResult)
        }
        # Check if a reboot is required even if there were errors
        if ($installationResult.RebootRequired) {
             Write-Warning "A system reboot is required to complete the installation for some updates."
        }
        Exit 1
    }

    Write-Host "Installation completed successfully."

    # Check if a reboot is required
    if ($installationResult.RebootRequired) {
        Write-Warning "A system reboot is required to complete the installation."
    } else {
        Write-Host "No reboot is required at this time."
    }

}
catch {
    Write-Error "An error occurred during the installation process: $($_.Exception.Message)"
    Exit 1
}

Write-Host "Driver update script finished."
Exit 0