# Stop the S3 drive.
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = "Stop"

$running = @(Get-S3MountProcess)
if ($running.Count -eq 0) {
    Write-Host "S3 drive is not running."
    exit 0
}

Stop-S3Mount
Write-Host "S3 drive stopped."
exit 0
