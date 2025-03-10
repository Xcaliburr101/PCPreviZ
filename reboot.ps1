if (!$isAdmin) {
    Write-Host "`nAdmin rights required to check Secure Boot and reboot to BIOS" -ForegroundColor Red
} else {
    if (!(Confirm-SecureBootUEFI)) {
        Write-Host "`nWould you like to reboot into BIOS now? (Y/N)" -ForegroundColor Cyan
        $rebootResponse = Read-Host
        if ($rebootResponse -match "^[Yy]$") {
            Write-Host "Rebooting into BIOS..." -ForegroundColor Green
            try {
                $osVersion = [System.Version]((Get-WmiObject -Class Win32_OperatingSystem).Version)
            }
            catch {
                Write-Host "Failed to retrieve OS version: $_" -ForegroundColor Red
                exit 1
            }
            
            # Check Firmware Reboot Compatibility
            $supportsFwReboot = $osVersion.Major -gt 6 -or ($osVersion.Major -eq 6 -and $osVersion.Minor -ge 2)
            
            if ($supportsFwReboot) {
                try {
                    Write-Host "Initiating firmware reboot..." -ForegroundColor Cyan
                    Write-Warning "The system will reboot in 10 seconds. Save any open work immediately!"
                    
                    # Start shutdown process
                    $shutdownArgs = "/r /fw /t 10 /c `"PS Firmware Reboot initiated by $env:USERNAME`""
                    Start-Process "shutdown.exe" -ArgumentList $shutdownArgs -NoNewWindow -Wait
                    
                    exit 0
                }
                catch {
                    Write-Host "Failed to initiate firmware reboot: $_" -ForegroundColor Red
                    exit 2
                }
            }
            else {
                Write-Host "Automatic firmware reboot not supported on:" -ForegroundColor Yellow
                Write-Host "OS Version: $($osVersion.Major).$($osVersion.Minor) (Windows 7/Server 2008 R2 or older)" -ForegroundColor Yellow
            }
        }
    }
}
