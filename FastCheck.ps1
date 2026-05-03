<#
.SYNOPSIS
    A clean PowerShell script For laptop diagnostics.
.DESCRIPTION
   placeholder
#>

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Clear-Host

# --- Define standard colors for the report ---
$ColorHeader = "white"    # For section titles like "System & OS"
$ColorValue = "White"     # For the primary property/object value
$ColorAccent = "Gray" # For secondary information

# --- Core Display Function ---
function Show-Row ([string]$Label, $Value, [string]$PassColor = "White") {
    # If Value is null or empty string, handle it here
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $DisplayValue = "N/A"
        $DisplayColor = "Gray"
    } else {
        $DisplayValue = $Value
        $DisplayColor = $PassColor
    }

    Write-Host (" {0,-18}: " -f $Label) -ForegroundColor cyan -NoNewline
    Write-Host $DisplayValue -ForegroundColor $DisplayColor
}

function Show-Header ([string]$Title) {
    Write-Host "`n$Title" -ForegroundColor $ColorHeader
}

# --- System & OS ---
Show-Header "System & OS"
$System = Get-CimInstance Win32_ComputerSystem -Property Manufacturer, Model
$OS = Get-CimInstance Win32_OperatingSystem -Property Caption, BuildNumber
$BIOS = Get-CimInstance Win32_BIOS -Property SerialNumber, Manufacturer, Name

Show-Row "System" "$($System.Manufacturer) $($System.Model)" $ColorValue
Show-Row "OS" "$($OS.Caption) (Build $($OS.BuildNumber))" $ColorAccent
Show-Row "Serial Number" "$($BIOS.SerialNumber)" $ColorAccent

# --- Licensing ---
Show-Header "Licensing"
# Try the Firmware key first (OA3)
$licenseKey = (Get-CimInstance SoftwareLicensingService -Property OA3xOriginalProductKey).OA3xOriginalProductKey

# Fallback to Registry if WMI is empty
if ([string]::IsNullOrWhiteSpace($licenseKey)) {
    $licenseKey = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform").BackupProductKeyDefault
}

Show-Row "Windows Key" $licenseKey

# --- CPU ---
Show-Header "CPU"
$CPU = Get-CimInstance Win32_Processor -Property Name, NumberOfCores, NumberOfLogicalProcessors | Select-Object -First 1
Show-Row "Name" "$($CPU.Name.Trim())" $ColorValue
Show-Row "Cores" "$($CPU.NumberOfCores) (Logical: $($CPU.NumberOfLogicalProcessors))" $ColorAccent

# --- BIOS ---
Show-Header "BIOS"
Show-Row "Version" "$($BIOS.Manufacturer) $($BIOS.Name)" $ColorValue

# --- Secure Boot Check ---
Show-Header "Secure Boot"
if ($isAdmin) {
    if (Confirm-SecureBootUEFI) {
        Show-Row "Status" "True" "Green"
    }
    else {
        Show-Row "Status" "Not in Secure Boot" "Red"
    }
}
else {
    Show-Row "Status" "Run as admin to check secure boot" $ColorAccent
}

# --- Bitlocker Check ---
Show-Header "Bitlocker"
if ($isAdmin) {
    $bitlockerVolume = Get-BitLockerVolume -MountPoint C:

    if ($bitlockerVolume.VolumeStatus -ne 'FullyDecrypted') {
        if ($bitlockerVolume.VolumeStatus -eq 'DecryptionInProgress') {
            Show-Row "Status" "Decryption is already in progress" "Yellow"
        }
        else {
            Show-Row "Status" "Enabled" "Red"
            Show-Row "Action" "Unlocking bitlocker..." "Yellow"
            Disable-BitLocker -MountPoint "C:"
        }
    }
    else {
        Show-Row "Status" "Not in Bitlocker" "Green"
    }
}
else {
    Show-Row "Status" "Run as admin to check bitlocker" $ColorAccent
}

# --- Display Adapters ---
Show-Header "Display Adapters"
$gpus = Get-CimInstance Win32_VideoController -ErrorAction Stop |
    Where-Object {
        $name = $_.Name -replace '\s+', ' '
        $name -match '(?i)(AMD|Radeon|Mesa|Intel|GeForce|RTX|NVIDIA|Quadro|Titan|GTX|GT|MX|Arc|Iris|UHD|HD Graphics|Radeon|RX|Vega|Navi|RDNA)' -and
        $name -notmatch '(?i)(Microsoft Basic|Standard|Generic|Virtual|Remote|Software|WDDM)'
    }

foreach ($gpu in $gpus) {
    $vramGB = if ($gpu.AdapterRAM) { [math]::Round($gpu.AdapterRAM / 1GB, 2) } else { 0 }
    $resolution = ""
    if ($gpu.CurrentHorizontalResolution -gt 0 -and $gpu.CurrentVerticalResolution -gt 0) {
        $resolution = "$($gpu.CurrentHorizontalResolution) x $($gpu.CurrentVerticalResolution)"
    }
    
    Show-Row "- Name" "$($gpu.Name)" $ColorValue
    Show-Row "  DriverVersion" "$($gpu.DriverVersion)" $ColorAccent
    Show-Row "  Resolution" "$resolution" $ColorAccent
    Show-Row "  VRAM" "$vramGB GB" $ColorAccent
}

# --- Screen Size ---
Show-Header "Screen Size"
try {
    $monitorParams = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction Stop
    $found = $false
    foreach ($monitor in $monitorParams) {
        if ($monitor.MaxHorizontalImageSize -gt 0 -and $monitor.MaxVerticalImageSize -gt 0) {
            $hInches = $monitor.MaxHorizontalImageSize / 2.54
            $vInches = $monitor.MaxVerticalImageSize / 2.54
            $diagonalInches = [math]::Round([math]::Sqrt(($hInches * $hInches) + ($vInches * $vInches)), 2)
            
            Show-Row "Size" "$diagonalInches inches" $ColorValue
            $found = $true
            break
        }
    }
    if (-not $found) {
        Show-Row "Size" "Not reported" "Red"
    }
}
catch {
    Show-Row "Size" "Query failed: $($_.Exception.Message)" "Red"
}

# --- Memory ---
Show-Header "Memory"
$Memory = Get-CimInstance Win32_PhysicalMemory -Property PartNumber, Speed, DeviceLocator, Capacity |
    Select-Object PartNumber, Speed, DeviceLocator, @{N = 'CapacityGB'; E = { [Math]::Round($_.Capacity / 1GB) } }

foreach ($Stick in $Memory) {
    Show-Row "- Slot" "$($Stick.DeviceLocator.PadRight(10)) ($($Stick.CapacityGB) GB @ $($Stick.Speed)MHz)" $ColorValue
    Show-Row "  Part" "$($Stick.PartNumber)" $ColorAccent
}

# --- Webcam ---
Show-Header "Webcam"
# 1. Attempt to find devices in the 'Camera' class
$webcam = Get-PnpDevice -Class Camera -ErrorAction SilentlyContinue | Select-Object -First 1
# 2. Fallback: Check 'Image' class if 'Camera' is empty (Legacy/Older Drivers)
if (-not $webcam) {
    $webcam = Get-PnpDevice -Class Image -ErrorAction SilentlyContinue | 
              Where-Object { $_.FriendlyName -match "Webcam|Camera|Integrated" } | 
              Select-Object -First 1
}

# 3. Extract the name safely
$webcamName = if ($webcam) { $webcam.FriendlyName } else { $null }

# 4. Display using your Show-Row function (which handles the N/A automatically)
Show-Row "Device" $webcamName $ColorAccent
# --- Storage (Local Disks) ---
Show-Header "Storage (Local Disks)"
$Disks = Get-CimInstance Win32_LogicalDisk -Property DeviceID, Size, FreeSpace, DriveType | Where-Object { $_.DriveType -eq 3 }

foreach ($Disk in $Disks) {
    $SizeGB = [Math]::Round($Disk.Size / 1GB, 2)
    $FreeGB = [Math]::Round($Disk.FreeSpace / 1GB, 2)
    $FreePct = [Math]::Round(($Disk.FreeSpace / $Disk.Size) * 100, 0)
    
    Show-Row "- Drive" "$($Disk.DeviceID)" $ColorValue
    Show-Row "  Usage" ("{0} GB Free / {1} GB Total ({2}% Free)" -f $FreeGB, $SizeGB, $FreePct) $ColorAccent
}

# --- Microphone ---
Show-Header "Microphone"
try {
    $microphoneFound = $false
    $mic = Get-CimInstance -ClassName Win32_PnPEntity -Property Name, PNPClass -ErrorAction Stop |
        Where-Object { $_.Name -match "Microphone|Mic|Microfoon" -or $_.PNPClass -eq "AudioEndpoint" } |
        Select-Object -First 1
        
    if ($mic) {
        Show-Row "Device" "$($mic.Name)" $ColorValue
        $microphoneFound = $true
    }

    if (-not $microphoneFound) {
        Show-Row "Device" "Not detected" "Red"
    }
}
catch {
    Show-Row "Detection" "Failed: $($_.Exception.Message)" "Red"
}

# --- Network (Physical Adapters) ---
Show-Header "Network (Physical Adapters)"
$Adapters = Get-CimInstance Win32_NetworkAdapter -Property PhysicalAdapter, Name, Speed |
    Where-Object { $_.PhysicalAdapter -eq $true -and $_.Name -notlike "*Virtual*" -and $_.Name -notlike "*WAN*" -and $_.Name -notlike "*loopback*" -and $_.Name -notlike "*Bluetooth*" }

foreach ($Adapter in $Adapters) {
    if ($Adapter.Speed -gt 0) {
        $SpeedMbps = [Math]::Round($Adapter.Speed / 1MB, 0)
        Show-Row "- Name" "$($Adapter.Name)" $ColorValue
        Show-Row "  Speed" "$SpeedMbps Mbps" $ColorAccent
    }
}

# --- Battery (Conditional powercfg Fallback) ---
Show-Header "Battery"
$Battery = Get-CimInstance Win32_Battery -Property DesignCapacity, FullChargeCapacity, DeviceID, EstimatedChargeRemaining | Select-Object -First 1

if ($Battery) {
    $WMIHealthPct = 0
    if ($Battery.DesignCapacity -gt 0) {
        $WMIHealthPct = [Math]::Round(($Battery.FullChargeCapacity / $Battery.DesignCapacity) * 100, 0)
    }

    $Source = "WMI"

    # Fallback to powercfg if WMI failed (0%)
    if ($WMIHealthPct -eq 0) {
        $TempFile = "$env:TEMP\battery-report.xml"
        powercfg /batteryreport /XML /OUTPUT "$TempFile" | Out-Null

        try {
            [xml]$BatteryReport = Get-Content -Path $TempFile -ErrorAction SilentlyContinue
            Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue

            $XMLBattery = $BatteryReport.BatteryReport.Batteries.Battery | Select-Object -First 1

            if ($XMLBattery -and $XMLBattery.DesignCapacity -gt 0) {
                $DesignCap = $XMLBattery.DesignCapacity
                $FullChargeCap = $XMLBattery.FullChargeCapacity
                $WMIHealthPct = [Math]::Round(($FullChargeCap / $DesignCap) * 100, 0)
                $Source = "powercfg Fallback"
            }
        }
        catch {
            Write-Debug "Failed to parse battery report XML"
        }
    }

    Show-Row "- ID" "$($Battery.DeviceID)" $ColorValue
    Show-Row "  Charge" "$($Battery.EstimatedChargeRemaining)%" $ColorAccent

    if ($WMIHealthPct -gt 0) {
        Show-Row "  Health" "$WMIHealthPct% ($Source)" "Yellow"
    }
    else {
        Show-Row "  Health" "Health data unavailable" "Red"
    }
}
else {
    Show-Row "Status" "No battery detected." "Red"
}

# --- Problems Check ---
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

Show-Header "Problematic Devices"
# Note: Upgraded this WMI call to CIM and added the property filter
$devices = Get-CimInstance -ClassName Win32_PnPEntity -Property Name, ConfigManagerErrorCode
$problematicDevices = $devices | Where-Object {
    $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22
}

if ($problematicDevices) {
    $problematicDevices | ForEach-Object {
        Show-Row "Device" "$($_.Name)" "Yellow"
        Show-Row "  Error Code" "$($_.ConfigManagerErrorCode)" "Yellow"
        Show-Row "  Description" "$(Get-ErrorDescription $_.ConfigManagerErrorCode)" "Yellow"
        Write-Host " ----------------------------------------" -ForegroundColor DarkGray
    }
}
else {
    Show-Row "Status" "All devices are functioning properly" "Green"
}

# --- Final Pause ---
Write-Host ""
Read-Host "Press Enter to exit"