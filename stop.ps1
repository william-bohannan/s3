# Stop the Knoxxa Digital K: mount.
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = "Stop"

$running = @(Get-KnoxxaMountProcess)
if ($running.Count -eq 0) {
    Write-Host "Knoxxa Digital is not running."
    exit 0
}

Stop-KnoxxaMount
Write-Host "Knoxxa Digital stopped."
exit 0
