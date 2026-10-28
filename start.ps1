# Start the Knoxxa Digital K: mount in the background. No window.
# Log: C:\kd\s3\log.txt unless settings.ini sets LogFile.
# -Restart stops the running mount first. A live rclone process keeps the
# access key it loaded at startup, so a new key is ignored until restart.
param([switch]$Restart)

. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = "Stop"

if ((Test-KnoxxaBackgroundMount) -and -not $Restart) {
    Write-Host "Knoxxa Digital is already running in the background."
    Write-Host "Log: $($script:LogFile)"
    exit 0
}

if ($Restart) {
    Write-Host "Restarting the mount so it reloads the saved access key..."
    Stop-KnoxxaMount
}

if (Test-IsAdmin) {
    Write-Host "Starting the mount in the normal user session..."
    Start-KnoxxaInUserSession -ScriptPath $PSCommandPath
    Write-Host "Knoxxa Digital is running in the background."
    Write-Host "Log: $($script:LogFile)"
    exit 0
}

Stop-KnoxxaMount
Start-KnoxxaHidden
Write-Host "Knoxxa Digital is running in the background."
Write-Host "Log: $($script:LogFile)"
exit 0
