<#
.SYNOPSIS
Checks for available Windows driver updates using the built-in COM object,
downloads them, and optionally installs them. Requires PowerShell 5.1+ and
administrator privileges.

.DESCRIPTION
This script connects to the Windows Update service using the Microsoft.Update.Session
COM object. It searches specifically for updates classified as 'Driver' that are
not currently installed or hidden. If driver updates are found, it proceeds to
download them. It then prompts for confirmation before installing the downloaded
updates.

The script provides detailed feedback using Write-Verbose and essential progress
updates using Write-Host. It includes enhanced error handling for various stages
of the update process and handles EULA acceptance automatically.

.PARAMETER ForceInstall
Skips the confirmation prompt before installing downloaded updates. Use with caution.

.NOTES
Version: 1.2
Author: Gemini (based on original by CookieMonster)
Requires: PowerShell 5.1+, Windows Operating System, Administrator privileges.
Date: 2025-04-14
Changes:
 - Fixed syntax errors by removing -ErrorAction from COM method calls within try/catch.
 - Addressed PSScriptAnalyzer warnings by placing $null on the left in comparisons.

.EXAMPLE
.\Install-DriverUpdates_v2.ps1 -Verbose
Runs the script with detailed output. It will search for, download, and then
prompt before installing pending driver updates. Requires administrator privileges.

.EXAMPLE
.\Install-DriverUpdates_v2.ps1 -ForceInstall -Verbose
Runs the script, automatically downloading and installing driver updates without
confirmation. Requires administrator privileges. Use the -Verbose switch for detailed logs.
#>

[CmdletBinding(SupportsShouldProcess = $true)] # Enables -WhatIf, -Confirm, -Verbose
param(
    [Switch]$ForceInstall # Parameter to skip install confirmation
)

#Requires -Version 5.1
#Requires -RunAsAdministrator

# --- Script Configuration ---
$ScriptStartTime = Get-Date
$LogFile = Join-Path -Path $env:TEMP -ChildPath "DriverUpdateLog-$($ScriptStartTime.ToString('yyyyMMdd-HHmmss')).log"

# --- Helper Function for Logging ---
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $LogEntry = "[$Timestamp][$Level] $Message"
    # Output to console based on level
    switch ($Level) {
        'INFO' { Write-Host $LogEntry -ForegroundColor Green }
        'WARN' { Write-Warning $LogEntry }
        'ERROR' { Write-Error $LogEntry }
    }
    # Append to log file
    try {
        Add-Content -Path $LogFile -Value $LogEntry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file '$LogFile'. Error: $($_.Exception.Message)"
    }
}

# --- Main Script Logic ---
Write-Log -Message "Starting Windows Driver Update script execution."
$exitCode = 1 # Default exit code to error unless explicitly set to 0

# Create a Windows Update Session object
$updateSession = $null
try {
    Write-Verbose "Creating Microsoft.Update.Session COM object..."
    # Use -ErrorAction Stop here as New-Object is a cmdlet
    $updateSession = New-Object -ComObject "Microsoft.Update.Session" -ErrorAction Stop
    Write-Log -Message "Successfully created Update Session."
    Write-Verbose "Update Session created successfully."
}
catch {
    Write-Log -Message "FATAL: Failed to create Microsoft.Update.Session COM object. Ensure the Windows Update service is running and COM permissions are correct. Error: $($_.Exception.Message)" -Level ERROR
    Exit $exitCode # Exit with error code 1
}

# Create an Update Searcher object from the session
$updateSearcher = $null
try {
    Write-Verbose "Creating Update Searcher object..."
    # COM method call - rely on try/catch for errors
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    # Check if the object was created successfully
    if ($null -eq $updateSearcher) {
        throw "Update Searcher COM object creation returned null."
    }
    Write-Log -Message "Successfully created Update Searcher."
    Write-Verbose "Update Searcher created successfully."
}
catch {
    Write-Log -Message "FATAL: Failed to create Update Searcher object. Error: $($_.Exception.Message)" -Level ERROR
    # Clean up COM object if session was created
    if ($null -ne $updateSession) {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null
    }
    Exit $exitCode # Exit with error code 1
}

# Define the search criteria: Find drivers that are not installed and not hidden
$searchCriteria = "IsInstalled=0 and Type='Driver' and IsHidden=0"
Write-Log -Message "Searching for driver updates using criteria: '$searchCriteria'"
Write-Verbose "Search criteria: $searchCriteria"

$searchResult = $null
try {
    Write-Verbose "Performing update search..."
    # COM method call - rely on try/catch for errors
    $searchResult = $updateSearcher.Search($searchCriteria)
    # Check if search result object is valid
    if ($null -eq $searchResult) {
         throw "Update search operation returned null."
    }
    Write-Log -Message ("Search completed. Found {0} driver update(s)." -f $searchResult.Updates.Count)
    Write-Verbose ("Search found {0} updates matching criteria." -f $searchResult.Updates.Count)
}
catch {
    $hResult = $_.Exception.HResult
    $hResultHex = "0x{0:X}" -f $hResult
    Write-Log -Message "Error occurred during update search. HRESULT: $hResultHex. Error: $($_.Exception.Message)" -Level ERROR
    # Specific HRESULT check for WU_E_NO_UPDATE (0x80240024)
    if ($hResult -eq 0x80240024) {
        Write-Log -Message "No applicable driver updates were found matching the criteria."
        $exitCode = 0 # No updates found is not an error condition
    } else {
        Write-Warning "Search failed. Review the error message and HRESULT ($hResultHex)."
        $exitCode = 1 # Other search errors are errors
    }
    # Clean up COM objects
    if ($null -ne $updateSearcher) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null }
    if ($null -ne $updateSession) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null }
    Exit $exitCode
}

# Check if any updates were found
if ($searchResult.Updates.Count -eq 0) {
    Write-Log -Message "No pending driver updates found that match the criteria. Exiting."
    # Clean up COM objects
    if ($null -ne $updateSearcher) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null }
    if ($null -ne $updateSession) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null }
    Exit 0 # Successful exit, no action needed
}

# Display found updates
Write-Log -Message "The following driver updates were found:"
$searchResult.Updates | ForEach-Object { Write-Host ("  - $($_.Title)") }

# Create a collection for updates to download and accept EULAs
$updatesToDownload = $null
try {
    # Use -ErrorAction Stop here as New-Object is a cmdlet
    $updatesToDownload = New-Object -ComObject "Microsoft.Update.UpdateColl" -ErrorAction Stop
    Write-Verbose "Creating collection for updates to download."
} catch {
     Write-Log -Message "FATAL: Failed to create Microsoft.Update.UpdateColl COM object. Error: $($_.Exception.Message)" -Level ERROR
     if ($null -ne $updateSearcher) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null }
     if ($null -ne $updateSession) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null }
     Exit $exitCode # Exit with error code 1
}


try {
    Write-Verbose "Adding updates to the download collection and accepting EULAs..."
    $searchResult.Updates | ForEach-Object {
        $update = $_
        Write-Verbose "Processing update: $($update.Title)"
        # Accept EULA if necessary
        if (-not $update.EulaAccepted) {
            Write-Log -Message "Accepting EULA for: $($update.Title)"
            Write-Verbose "EULA not accepted for '$($update.Title)'. Attempting to accept..."
            try {
                # COM method call - rely on try/catch for errors
                $update.AcceptEula()
                Write-Verbose "EULA accepted for '$($update.Title)'."
            }
            catch {
                Write-Log -Message "Failed to accept EULA for '$($update.Title)'. Skipping this update. Error: $($_.Exception.Message)" -Level WARN
                # Continue to the next update in the loop
                return # Skips adding this update
            }
        }
        # Add the update to the collection
        Write-Verbose "Adding '$($update.Title)' to download list."
        $null = $updatesToDownload.Add($update) # Suppress output, rely on try/catch for Add errors
    }
}
catch {
    # Catch errors from the ForEach-Object block or Add method itself
    Write-Log -Message "Error occurred while preparing updates for download: $($_.Exception.Message)" -Level ERROR
    # Clean up COM objects
    if ($null -ne $updatesToDownload) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updatesToDownload) | Out-Null }
    if ($null -ne $updateSearcher) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null }
    if ($null -ne $updateSession) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null }
    Exit $exitCode # Exit with error code 1
}


# Check if there are updates actually added to the download list (e.g., if EULA failed for all)
if ($updatesToDownload.Count -eq 0) {
    Write-Log -Message "No updates were successfully added to the download list (possibly due to EULA acceptance issues). Exiting." -Level WARN
    # Clean up COM objects
    if ($null -ne $updatesToDownload) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updatesToDownload) | Out-Null }
    if ($null -ne $updateSearcher) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null }
    if ($null -ne $updateSession) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null }
    Exit 0 # Exit gracefully as no action is pending
}

# Download the updates
Write-Log -Message "Starting download of $($updatesToDownload.Count) driver update(s)..."
$downloader = $null
$downloadResult = $null
try {
    Write-Verbose "Creating Update Downloader object..."
    # COM method call - rely on try/catch for errors
    $downloader = $updateSession.CreateUpdateDownloader()
    if ($null -eq $downloader) { throw "Update Downloader COM object creation returned null." }

    $downloader.Updates = $updatesToDownload
    Write-Verbose "Initiating download..."
    # COM method call - rely on try/catch for errors
    $downloadResult = $downloader.Download()
    if ($null -eq $downloadResult) { throw "Download operation returned null." }


    # Check download result code
    # Result codes: 0=NotStarted, 1=InProgress, 2=Succeeded, 3=SucceededWithErrors, 4=Failed, 5=Aborted
    Write-Log -Message ("Overall Download Result Code: {0} ({1})" -f $downloadResult.ResultCode, $([Microsoft.Update.OperationResultCode]$downloadResult.ResultCode))
    Write-Verbose "Download operation completed with ResultCode: $($downloadResult.ResultCode)"

    if ($downloadResult.ResultCode -ne [Microsoft.Update.OperationResultCode]::orcSucceeded) {
        Write-Log -Message "Download did not complete successfully (ResultCode = $($downloadResult.ResultCode))." -Level WARN
        # Log detailed status for each update
        Write-Log -Message "Individual update download statuses:" -Level WARN
        for ($i = 0; $i -lt $updatesToDownload.Count; $i++) {
            $updateTitle = $updatesToDownload.Item($i).Title
            try {
                 # Use try-catch for safety when accessing individual results
                 $updateStatus = $downloadResult.GetUpdateResult($i)
                 $hResultHex = "0x{0:X}" -f $updateStatus.HResult
                 Write-Log -Message ("  - '{0}': ResultCode={1} ({2}), HResult={3}" -f $updateTitle, $updateStatus.ResultCode, $([Microsoft.Update.OperationResultCode]$updateStatus.ResultCode), $hResultHex) -Level WARN
            } catch {
                 Write-Log -Message ("  - Error getting download status for '{0}': {1}" -f $updateTitle, $_.Exception.Message) -Level ERROR
            }
        }
        # Decide whether to proceed: Only proceed if *some* updates succeeded (ResultCode 3)
        if ($downloadResult.ResultCode -ne [Microsoft.Update.OperationResultCode]::orcSucceededWithErrors) {
             Write-Log -Message "Download failed completely. No updates will be installed." -Level ERROR
             $exitCode = 1 # Set error exit code
             # Clean up COM objects before exiting - Handled in finally block
             throw "Download failed completely." # Throw to exit try block and trigger finally
        } else {
             Write-Log -Message "Download completed with errors, but some updates might be ready. Proceeding to installation phase for downloaded updates." -Level WARN
             # Allow script to continue, exitCode remains 1 due to errors
             $exitCode = 1
        }
    } else {
        Write-Log -Message "Download completed successfully for all specified updates."
        # Success so far, but installation might still fail
        $exitCode = 0
    }
}
catch {
    # Catch errors from COM calls or the explicit throw above
    Write-Log -Message "A critical error occurred during the download process: $($_.Exception.Message)" -Level ERROR
    $exitCode = 1 # Ensure exit code is error
    # Clean up COM objects - Handled in finally block
}
finally {
     # Ensure downloader COM object is released if it was created
     if ($null -ne $downloader) {
         Write-Verbose "Releasing Update Downloader COM object."
         [System.Runtime.InteropServices.Marshal]::ReleaseComObject($downloader) | Out-Null
     }
     # If a critical download error occurred, clean up other objects and exit
     if ($exitCode -eq 1 -and $PSCmdlet.MyInvocation.ScriptName -ne '') { # Check if we are in the main script flow
         if ($null -ne $updatesToDownload) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updatesToDownload) | Out-Null }
         if ($null -ne $updateSearcher) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null }
         if ($null -ne $updateSession) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null }
         Exit $exitCode
     }
}


# Create a collection for updates to install (only those successfully downloaded)
$updatesToInstall = $null
try {
    $updatesToInstall = New-Object -ComObject "Microsoft.Update.UpdateColl" -ErrorAction Stop
    Write-Verbose "Creating collection for updates to install."
} catch {
     Write-Log -Message "FATAL: Failed to create Microsoft.Update.UpdateColl COM object for installation. Error: $($_.Exception.Message)" -Level ERROR
     if ($null -ne $updatesToDownload) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updatesToDownload) | Out-Null }
     if ($null -ne $updateSearcher) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null }
     if ($null -ne $updateSession) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null }
     Exit 1 # Exit with error code 1
}


Write-Log -Message "Filtering for successfully downloaded updates..."
try {
    # Iterate through the original list that was *attempted* to download
    for ($i = 0; $i -lt $updatesToDownload.Count; $i++) {
        $update = $updatesToDownload.Item($i) # Get update from the download collection
        Write-Verbose "Checking download status for: $($update.Title)"
        # Check the IsDownloaded property *after* the download operation
        if ($update.IsDownloaded) {
            Write-Log -Message "Adding successfully downloaded update '$($update.Title)' to installation list."
            Write-Verbose "'$($update.Title)' is marked as downloaded. Adding to install list."
            $null = $updatesToInstall.Add($update) # Suppress output
        } else {
            # This might happen if downloadResult was SucceededWithErrors
             Write-Log -Message "Update '$($update.Title)' was not successfully downloaded (IsDownloaded=false). Skipping installation." -Level WARN
             Write-Verbose "'$($update.Title)' IsDownloaded property is false."
        }
    }
}
catch {
    Write-Log -Message "Error occurred while preparing updates for installation: $($_.Exception.Message)" -Level ERROR
    # Clean up COM objects
    if ($null -ne $updatesToInstall) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updatesToInstall) | Out-Null }
    if ($null -ne $updatesToDownload) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updatesToDownload) | Out-Null }
    if ($null -ne $updateSearcher) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null }
    if ($null -ne $updateSession) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null }
    Exit 1 # Exit with error code 1
}


# Check if there are updates ready to install
if ($updatesToInstall.Count -eq 0) {
    Write-Log -Message "No updates are ready for installation (download may have failed or completed with errors for all items)." -Level WARN
    # Clean up COM objects
    if ($null -ne $updatesToInstall) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updatesToInstall) | Out-Null }
    if ($null -ne $updatesToDownload) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updatesToDownload) | Out-Null }
    if ($null -ne $updateSearcher) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null }
    if ($null -ne $updateSession) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null }
    # If download had errors ($exitCode=1), keep it as 1. Otherwise, it's a clean exit (0).
    Exit $exitCode
}

# Install the updates - Use ShouldProcess for -Confirm / -WhatIf
Write-Log -Message "Preparing to install $($updatesToInstall.Count) downloaded driver update(s)."

if ($PSCmdlet.ShouldProcess("the system", "Install $($updatesToInstall.Count) driver updates")) {
    # Proceed only if -Confirm is specified or -ForceInstall switch is used
    if ($ForceInstall -or $PSCmdlet.ShouldContinue("Are you sure you want to install these $($updatesToInstall.Count) driver updates?", "Confirm Installation")) {

        Write-Log -Message "Starting installation of $($updatesToInstall.Count) driver update(s)... This may take some time."
        $installer = $null
        $installationResult = $null
        try {
            Write-Verbose "Creating Update Installer object..."
            # COM method call - rely on try/catch for errors
            $installer = $updateSession.CreateUpdateInstaller()
            if ($null -eq $installer) { throw "Update Installer COM object creation returned null." }

            $installer.Updates = $updatesToInstall

            Write-Verbose "Initiating synchronous installation..."
            # Note: Installation might require user interaction or fail if user is logged off, depending on update type.
            # COM method call - rely on try/catch for errors
            $installationResult = $installer.Install()
            if ($null -eq $installationResult) { throw "Install operation returned null." }


            # Check installation result code
            Write-Log -Message ("Overall Installation Result Code: {0} ({1})" -f $installationResult.ResultCode, $([Microsoft.Update.OperationResultCode]$installationResult.ResultCode))
            Write-Verbose "Installation operation completed with ResultCode: $($installationResult.ResultCode)"

            if ($installationResult.ResultCode -ne [Microsoft.Update.OperationResultCode]::orcSucceeded) {
                 Write-Log -Message "Installation did not complete successfully for all updates (ResultCode = $($installationResult.ResultCode))." -Level WARN
                 # Log detailed status for each update
                 Write-Log -Message "Individual update installation statuses:" -Level WARN
                 for ($i = 0; $i -lt $updatesToInstall.Count; $i++) {
                     $updateTitle = $updatesToInstall.Item($i).Title
                     try {
                         $updateStatus = $installationResult.GetUpdateResult($i)
                         $hResultHex = "0x{0:X}" -f $updateStatus.HResult
                         Write-Log -Message ("  - '{0}': ResultCode={1} ({2}), HResult={3}" -f $updateTitle, $updateStatus.ResultCode, $([Microsoft.Update.OperationResultCode]$updateStatus.ResultCode), $hResultHex) -Level WARN
                     } catch {
                          Write-Log -Message ("  - Error getting installation status for '{0}': {1}" -f $updateTitle, $_.Exception.Message) -Level ERROR
                     }
                 }
                 # Check for reboot requirement even if there were errors
                 if ($installationResult.RebootRequired) {
                    Write-Log -Message "A system reboot is required to complete the installation process for some updates." -Level WARN
                 }
                 # Exit with an error code if installation wasn't fully successful or had errors
                 $exitCode = 1
            } else {
                Write-Log -Message "Installation completed successfully for all specified updates."
                # Check for reboot requirement on full success
                if ($installationResult.RebootRequired) {
                    Write-Log -Message "A system reboot is required to complete the installation." -Level WARN
                } else {
                    Write-Log -Message "No system reboot is required at this time."
                }
                $exitCode = 0 # Success
            }
        }
        catch {
            Write-Log -Message "A critical error occurred during the installation process: $($_.Exception.Message)" -Level ERROR
            $exitCode = 1
        }
        finally {
             # Ensure installer COM object is released if it was created
             if ($null -ne $installer) {
                 Write-Verbose "Releasing Update Installer COM object."
                 [System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) | Out-Null
             }
        }
    } else {
        Write-Log -Message "Installation cancelled by user confirmation."
        $exitCode = 0 # User cancelled, not an error
    }
} else {
    Write-Log -Message "Installation skipped due to -WhatIf parameter."
    $updatesToInstall | ForEach-Object { Write-Host ("-Would install driver: $($_.Title)") }
    $exitCode = 0 # WhatIf is not an error
}


# --- Final Cleanup ---
Write-Verbose "Releasing remaining COM objects..."
# Release collections first
if ($null -ne $updatesToInstall) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updatesToInstall) | Out-Null }
if ($null -ne $updatesToDownload) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updatesToDownload) | Out-Null }
# Then Searcher and Session
if ($null -ne $updateSearcher) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null }
if ($null -ne $updateSession) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null }
Write-Verbose "COM objects released."

Write-Log -Message "Driver update script finished. Log file located at: $LogFile"
Exit $exitCode # Exit with 0 for success/no action needed, 1 for errors
