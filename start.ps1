# Start the S3 drive in the background. No window.
# Log: C:\git\s3\full.log unless settings.ini sets LogFile.
# -Restart stops the running mount first. A live rclone process keeps the
# access key it loaded at startup, so a new key is ignored until restart.
param([switch]$Restart)

. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = "Stop"

if ((Test-S3BackgroundMount) -and -not $Restart) {
    Write-Host "S3 drive is already running in the background."
    Write-Host "Log: $($script:LogFile)"
    exit 0
}

if ($Restart) {
    Write-Host "Restarting the mount so it reloads the saved access key..."
    Stop-S3Mount
}

if (Test-IsAdmin) {
    Write-Host "Starting the mount in the normal user session..."
    Start-S3InUserSession -ScriptPath $PSCommandPath
    Write-Host "S3 drive is running in the background."
    Write-Host "Log: $($script:LogFile)"
    exit 0
}

Stop-S3Mount
Start-S3Hidden
Write-Host "S3 drive is running in the background."
Write-Host "Log: $($script:LogFile)"
exit 0
