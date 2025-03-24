<#
.SYNOPSIS
    Performs a pre-visualization check on a PC, gathering system information and performing various checks.
.DESCRIPTION
    This script gathers hardware and software information from the local computer.
    It displays system specs, audio and webcam status, storage details, and checks for device problems.
    Optionally, it can generate a battery report and discover installed printers.
.PARAMETER Printer
    Switch parameter to include printer discovery in the script execution.
#>
param (
    [switch]$Printer
)

Clear-Host
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)


write-host "/==============================================\"
write-host "|| _____   _____ _____                _ ______||"
write-host "|||  __ \ / ____|  __ \              (_)___  /||"
write-host "||| |__) | |    | |__) | __ _____   ___   / / ||"
write-host "|||  ___/| |    |  ___/ '__/ _ \ \ / / | / /  ||"
write-host "||| |    | |____| |   | | |  __/\ V /| |/ /__ ||"
write-host "|||_|     \_____|_|   |_|  \___| \_/ |_/_____|||"
write-host "\==============================================/"

if (-not $isAdmin) {
    Write-Host "Script is not running as administrator. Some features may be limited." -ForegroundColor Yellow
    Write-Host "Press enter for fast mode or Y for full mode" -ForegroundColor White
    $adminResponse = Read-Host
    #the script will still proceed after user input or Enter.
    if ($adminResponse -match "^[Yy]$") {
        Write-Host "Requesting elevation..." -ForegroundColor Yellow
        Start-Process -FilePath PowerShell -Verb RunAs -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSCommandPath"
        exit
    } else {
        Write-Host "Continuing in non-administrator mode." -ForegroundColor Yellow
    }
}

# Start the timer
$stopWatch = [System.Diagnostics.Stopwatch]::StartNew()

# Display System Information first (since this is important basic info)
Write-Host "`n================== System Information ===================" -ForegroundColor Cyan
Write-Host "System Model: " -NoNewline -ForegroundColor White
Write-Host (Get-CimInstance -ClassName Win32_ComputerSystem).Model -ForegroundColor Yellow
Write-Host "Serial Number: " -NoNewline -ForegroundColor White
Write-Host (Get-CimInstance -ClassName Win32_BIOS).SerialNumber -ForegroundColor Yellow
try {
    if (Confirm-SecureBootUEFI) {
        Write-Host "Secure Boot: " -NoNewline -ForegroundColor White
        Write-Host "True" -ForegroundColor Green
    } else {
        Write-Host "Secure Boot: " -NoNewline -ForegroundColor White
        Write-Host "Not in Secure Boot" -ForegroundColor Red
    }
} catch {
    Write-Host "Secure Boot: needs admin rights" -ForegroundColor Red
}
Start-Process explorer.exe "ms-settings:windowsupdate"
# Hardware Info
function Get-SystemHardwareInfo {
    # Create a hashtable to store our results.
    $systemInfo = @{
        Processor            = "Unknown"
        ProcessorSpeedMHz    = "Unknown"
        TotalRAMGB           = "Unknown"
        MicrophoneDetection  = "Unknown"
        ScreenSizeInches     = "Unknown"
        NetworkLinkSpeed     = "Unknown"
    }

    # --- Retrieve Processor Information ---
    try {
        $processor = Get-WmiObject -Class Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($processor) {
            $systemInfo.Processor         = $processor.Name
            $systemInfo.ProcessorSpeedMHz = $processor.MaxClockSpeed
        }
    }
    catch {
        Write-Verbose "WMI query for processor info failed: $_"
        try {
            $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
            if ($processor) {
                $systemInfo.Processor         = $processor.Name
                $systemInfo.ProcessorSpeedMHz = $processor.MaxClockSpeed
            }
        }
        catch {
            Write-Verbose "CIM query for processor info also failed: $_"
        }
    }

    # --- Retrieve RAM Information ---
    try {
        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
        if ($cs) {
            $systemInfo.TotalRAMGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        }
    }
    catch {
        Write-Verbose "WMI query for computer system info failed: $_"
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            if ($cs) {
                $systemInfo.TotalRAMGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
            }
        }
        catch {
            Write-Verbose "CIM query for computer system info also failed: $_"
        }
    }

    # --- Retrieve Microphone Information ---
    try {
        $microphoneFound = $false

        # Method 1: Check using Win32_PnPEntity
        if (-not $microphoneFound) {
            $mic = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                   Where-Object { $_.Name -match "Microphone|mic" -or $_.PNPClass -eq "AudioEndpoint" } |
                   Select-Object -First 1
            if ($mic) {
                $systemInfo.MicrophoneDetection = $mic.Name
                $microphoneFound = $true
            }
        }

        if (-not $microphoneFound) {
            $systemInfo.MicrophoneDetection = "Not Detected"
        }
    }
    catch {
        Write-Verbose "Microphone detection failed: $_"
        $systemInfo.MicrophoneDetection = "Detection Failed"
    }

    # --- Retrieve Screen Size ---
    try {
        $monitorParams = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction Stop
        $found = $false
        foreach ($monitor in $monitorParams) {
            if ($monitor.MaxHorizontalImageSize -gt 0 -and $monitor.MaxVerticalImageSize -gt 0) {
                $hInches = $monitor.MaxHorizontalImageSize / 2.54
                $vInches = $monitor.MaxVerticalImageSize / 2.54
                $diagonalInches = [math]::Round([math]::Sqrt(($hInches * $hInches) + ($vInches * $vInches)), 2)
                $systemInfo.ScreenSizeInches = "$diagonalInches inches"
                $found = $true
                break
            }
        }
        if (-not $found) {
            $systemInfo.ScreenSizeInches = "Unknown"
        }
    }
    catch {
        $systemInfo.ScreenSizeInches = "Unknown"
    }

    # --- Retrieve Network Link Speed ---
    try {
        $networkAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        $networkInfo = @()

        foreach ($adapter in $networkAdapters) {
            if ($adapter.InterfaceDescription -match 'Tailscale|VPN|Virtual') { continue }

            $speed = if ($adapter.LinkSpeed -match 'Gbps') {
                [double]($adapter.LinkSpeed -replace '[^0-9.]',[string]::Empty) * 1000
            } else {
                [double]($adapter.LinkSpeed -replace '[^0-9.]',[string]::Empty)
            }

            $networkInfo += "$($adapter.Name): $speed Mbps"
        }

        if ($networkInfo.Count -gt 0) {
            $systemInfo.NetworkLinkSpeed = $networkInfo -join ' | '
        } else {
            $systemInfo.NetworkLinkSpeed = "No active network connections"
        }
    }
    catch {
        $systemInfo.NetworkLinkSpeed = "Unknown"
    }

    return $systemInfo
}

# Now use the function and display hardware info
$info = Get-SystemHardwareInfo
Write-Host ""
Write-Host "Screen Size: " -NoNewline -ForegroundColor White
Write-Host $($info.ScreenSizeInches) -ForegroundColor Yellow
Write-Host "Processor: " -NoNewline -ForegroundColor White
Write-Host $($info.Processor) -ForegroundColor Yellow
Write-Host "Total RAM (GB): " -NoNewline -ForegroundColor White
Write-Host $($info.TotalRAMGB) -ForegroundColor Yellow
Write-Host "Network Link Speed: " -NoNewline -ForegroundColor White
Write-Host $($info.NetworkLinkSpeed) -ForegroundColor Yellow
Write-Host "Microphone: " -NoNewline -ForegroundColor White
Write-Host $($info.MicrophoneDetection) -ForegroundColor Yellow




# Audio Devices
Write-Host "`n===================== Audio Devices ======================" -ForegroundColor Cyan
Write-Host "Audio Devices:" -ForegroundColor White
$audioDevices = Get-CimInstance Win32_SoundDevice | Where-Object { $_.Status -eq "OK" }
foreach ($device in $audioDevices) {
    Write-Host "  $($device.Name)" -ForegroundColor Yellow
}

# Webcam Check
Write-Host "`n====================== Webcam Check =======================" -ForegroundColor Cyan
Write-Host "Webcam Device: " -NoNewline -ForegroundColor White
Write-Host (Get-PnpDevice -Class Camera | Select-Object -ExpandProperty Name) -ForegroundColor Yellow

# Storage Info

Write-Host "`n============== Storage Device Information ===============" -ForegroundColor Cyan
$DiskDrives = Get-WmiObject -Class Win32_DiskDrive | Where-Object {$_.MediaType -ne "Removable Media"}
$PhysicalDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue

if ($DiskDrives -isnot [array]) { $DiskDrives = @($DiskDrives) }  # Ensure it's always an array

$StorageInfo = foreach ($Disk in $DiskDrives) {
    # Find matching physical disk using device ID
    $PhysicalDisk = $PhysicalDisks | Where-Object { $_.DeviceId -eq $Disk.Index }

    # Determine drive type using PhysicalDisk if available
    if ($PhysicalDisk) {
        $DriveType = switch ($PhysicalDisk.MediaType) {
            "HDD" { "HDD" }
            "SSD" { if ($PhysicalDisk.BusType -eq "NVMe") { "NVMe" } else { "SSD" } }
            default { "Unknown" }
        }
        $InterfaceType = $PhysicalDisk.BusType
    }
    else {
        # Fallback to Win32_DiskDrive method if Get-PhysicalDisk is unavailable
        $DriveType = switch ($Disk.BusType) {
            17 { "NVMe" }  # BusType 17 = NVMe
            7  { "SSD" }   # BusType 7  = SATA (SSD or HDD)
            default {
                if ($Disk.MediaType -match "Solid state drive") { "SSD" }
                elseif ($Disk.MediaType -match "Fixed hard disk") { "HDD" }
                else { "Unknown" }
            }
        }
        $InterfaceType = $Disk.InterfaceType
    }

    [PSCustomObject]@{
        "Device" = $Disk.Caption
        "Model" = $Disk.Model
        "Type" = $DriveType
        "Size (GB)" = [Math]::Round($Disk.Size / 1GB)
        "Interface Type" = $InterfaceType
    }
}

foreach ($Disk in $StorageInfo) {
    Write-Host "Device: " -NoNewline -ForegroundColor White; Write-Host $Disk.Device -ForegroundColor Yellow
    Write-Host "  Model: " -NoNewline -ForegroundColor White; Write-Host $Disk.Model -ForegroundColor Yellow
    Write-Host "  Type: " -NoNewline -ForegroundColor White; Write-Host $Disk.Type -ForegroundColor Yellow
    Write-Host "  Size: " -NoNewline -ForegroundColor White; Write-Host "$($Disk.'Size (GB)') GB" -ForegroundColor Yellow
    Write-Host "  Interface: " -NoNewline -ForegroundColor White; Write-Host $Disk.'Interface Type' -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
}

foreach ($Disk in $StorageInfo) {
    if ($Disk.Model -and $Disk.Model -ne "") {
        Write-Host "`n" -NoNewline
        Write-Host "Would you like to Google the model $($Disk.Model) on SmartHDD.com? (Y/N): " -NoNewline -ForegroundColor White
        $stopWatch.Stop()
        $response = Read-Host
        $stopWatch.Start()
        if ($response -match "^[Yy]$") {
            Add-Type -AssemblyName System.Net
            $searchQuery = [System.Net.WebUtility]::UrlEncode("site:smarthdd.com $($Disk.Model)")
            Start-Process -FilePath "https://www.google.com/search?q=$searchQuery"
            Write-Host "Searching Google for: site:smarthdd.com $($Disk.Model)" -ForegroundColor Green
        } else {
            Write-Host "Skipping Google search for: $($Disk.Model)" -ForegroundColor Yellow
        }
    }
}
# Problems Check
# Function to translate ConfigManagerErrorCode to a readable description
function Get-ErrorDescription {
    param ($errorCode)
    switch ($errorCode) {
        1 { "This device is not configured correctly." }
        2 { "Windows cannot load the driver for this device." }
        3 { "The driver for this device might be corrupted, or your system may be running low on memory or other resources." }
        10 { "This device cannot start." }
        18 { "Reinstall the drivers for this device." }
        22 { "This device is disabled." }
        28 { "The drivers for this device are not installed." }
        31 { "This device is not working properly because Windows cannot load the drivers required for this device." }
        default { "Unknown error." }
    }
}

# Retrieve all Plug and Play devices
$devices = Get-WmiObject -Class Win32_PnPEntity

# Filter devices with a non-zero ConfigManagerErrorCode, excluding code 22 (disabled devices)
$problematicDevices = $devices | Where-Object {
    $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22
}
write-host "==================Problems==============================" -ForegroundColor Cyan
# Display the problematic devices
if ($problematicDevices) {
    $problematicDevices | ForEach-Object {
        Write-Host "Device: " -NoNewline -ForegroundColor White; Write-Host $($_.Name) -ForegroundColor Yellow
        Write-Host "Error Code: " -NoNewline -ForegroundColor White; Write-Host $($_.ConfigManagerErrorCode) -ForegroundColor Yellow
        Write-Host "Error Description: " -NoNewline -ForegroundColor White; Write-Host (Get-ErrorDescription $_.ConfigManagerErrorCode) -ForegroundColor Yellow
        Write-Host "----------------------------------------" -ForegroundColor DarkGray
    }
} else {
    Write-Host "All devices are functioning properly" -ForegroundColor Green
}

#time check
write-host ""
write-host ""
#automatic add printers
if ($Printer) {
    Write-Host "`n==================== Printer Discovery =====================" -ForegroundColor Cyan
    Write-Host "Searching for available printers..." -ForegroundColor Yellow

    try {
        Add-Type -AssemblyName System.Printing
        $printServer = New-Object System.Printing.PrintServer
        $printers = $printServer.GetPrintQueues()
        if ($printers) {
            Write-Host "`nInstalled printers found:" -ForegroundColor Green
            foreach ($printer in $printers) {
                Write-Host "  - $($printer.Name) (Network: $($printer.IsNetworkPrinter), Shared: $($printer.IsShared))" -ForegroundColor White
            }
        } else {
            Write-Host "`nNo printers found." -ForegroundColor Green
        }
    } catch {
        Write-Host "Error discovering printers: $_" -ForegroundColor Red
    }
    # Ask about opening settings
    Write-Host "`nWould you like to open Printers? (Y/N): " -NoNewline -ForegroundColor White
    $settingsResponse = Read-Host

    if (-not $settingsResponse) {
        $settingsResponse = "Y"
    }

    if ($settingsResponse -match "^[Yy]$") {
        Write-Host "Opening settings..." -ForegroundColor Yellow
        # Open printer settings
        Start-Process "cmd" -ArgumentList "/c start /min explorer.exe ms-settings:printers"
    }
}

Write-Host "`n====================== Battery Report =======================" -ForegroundColor Cyan
$InfoAlertPercent = "100"
$WarnAlertPercent = "70"
$CritAlertPercent = "40"
$BatteryHealth=""
& powercfg /batteryreport /XML /OUTPUT "batteryreport.xml"
Start-Sleep 1
[xml]$b = Get-Content batteryreport.xml

$b.BatteryReport.Batteries |
    ForEach-Object{
        [PSCustomObject]@{
            DesignCapacity = $_.Battery.DesignCapacity
            FullChargeCapacity = $_.Battery.FullChargeCapacity
            BatteryHealth = [math]::floor([int64]$_.Battery.FullChargeCapacity/[int64]$_.Battery.DesignCapacity*100)
            CycleCount = $_.Battery.CycleCount
            Id = $_.Battery.id
        }
if (([int64]$_.Battery.FullChargeCapacity/[int64]$_.Battery.DesignCapacity)*100 -gt $InfoAlertPercent){
            $BatteryHealth="Great"
            write-host "Battery Health is $BatteryHealth. No further action needed." -ForegroundColor Green
        }elseif (([int64]$_.Battery.FullChargeCapacity/[int64]$_.Battery.DesignCapacity)*100 -and ([int64]$_.Battery.FullChargeCapacity/[int64]$_.Battery.DesignCapacity)*100 -gt $WarnAlertPercent){
            $BatteryHealth="OK"
            write-host "Battery Health is $BatteryHealth. Needs 3 Hour test." -ForegroundColor Yellow
        }elseif (([int64]$_.Battery.FullChargeCapacity/[int64]$_.Battery.DesignCapacity)*100 -and ([int64]$_.Battery.FullChargeCapacity/[int64]$_.Battery.DesignCapacity)*100 -gt $CritAlertPercent){
            $BatteryHealth="Low"
            write-host "Battery Health is $BatteryHealth. Needs 3 hour test, watch it closely!" -ForegroundColor Red
        }elseif (([int64]$_.Battery.FullChargeCapacity/[int64]$_.Battery.DesignCapacity)*100 -le $CritAlertPercent){
            $BatteryHealth="Critical"
            write-host "Battery Health is $BatteryHealth. Needs replacement!" -ForegroundColor DarkRed
        }
    }
Remove-Item "batteryreport.xml"

$stopWatch.Stop()
$elapsedTime = [math]::Round($stopWatch.Elapsed.TotalSeconds)

Write-Host "Script took $elapsedTime seconds"


if (!(Confirm-SecureBootUEFI)) {
        Write-Host "`nWould you like to reboot into BIOS now? [default: Y]" -ForegroundColor Cyan
        $rebootResponse = Read-Host
        if ($rebootResponse -match "^[Yy]|^$") {
            try {
                Write-Host "`n==================== CMD Method =====================" -ForegroundColor Cyan
                # Simplified shutdown command to avoid potential path issues
                shutdown.exe /r /fw /t 0 /c "Firmware Reboot initiated by $env:USERNAME"
            } catch {
                Write-Warning "Failed with shutdown.exe method: $_"
            } # Check if the Restart-Computer cmdlet supports the -Firmware parameter (PowerShell v5.1+)
            if ($PSVersionTable.PSVersion.Major -ge 5 -and $PSVersionTable.PSVersion.Minor -ge 1) {
                Write-Host "`n==================== POWERSHELL Method =====================" -ForegroundColor Cyan
                Write-Host "reboot into firmware mode using Restart-Computer -Firmware..." -ForegroundColor DarkYellow
                try {
                    Restart-Computer -Firmware -Force
                    Write-Host "Successfully initiated firmware reboot using Restart-Computer -Firmware." -ForegroundColor Green
                }
                catch {
                    Write-Warning "Failed to initiate firmware reboot using Restart-Computer -Firmware: $($_.Exception.Message)"
                    Write-Host "Falling back to the registry method..." -ForegroundColor Red
                    
                    try {
                        # Set the registry key to trigger firmware boot on the next restart
                        Write-Host "`n==================== Registry Method =====================" -ForegroundColor Cyan
                        $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\FirmwareEnvironment"
                        $registryKeyName = "BootToFirmware"
            
                        if (-not (Test-Path $registryPath)) {
                            Write-Verbose "Creating registry path: '$registryPath'"
                            New-Item -Path $registryPath -Force | Out-Null
                        }
            
                        Write-Verbose "Setting registry value '$registryPath\$registryKeyName' to 1"
                        Set-ItemProperty -Path $registryPath -Name $registryKeyName -Value 1 -Force
            
                        Write-Host "Successfully set the registry key for firmware reboot." -ForegroundColor Green
                        Write-Host "Initiating system reboot..." -ForegroundColor Green
                        Restart-Computer -Force
                    }
                    catch {
                        Write-Error "Failed to set the registry key for firmware reboot: $($_.Exception.Message)"
                        Write-Error "Could not initiate a reboot into firmware mode. im an dumbdumb"
            
                    }
        }
    }
                    Pause
        
        }
    }


# Reset Execution Policy
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Default -Force
Start-Sleep -Seconds 2
pause
exit
