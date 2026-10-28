# Remove the s3 drive mount, logon task, and rclone remote.
# WinFsp and rclone themselves stay installed.
param([switch]$NoPause)

. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = "Stop"
Update-S3Path

Write-Host "Stopping the mount..." -ForegroundColor Green
Stop-S3Mount

Write-Host "Removing the logon task..." -ForegroundColor Green
Unregister-S3Tasks

if (Test-Path -LiteralPath $script:LegacyMountScript) {
    Remove-Item -LiteralPath $script:LegacyMountScript -Force
    Write-Host "Removed $($script:LegacyMountScript)"
}

if (Get-Command rclone -ErrorAction SilentlyContinue) {
    $remotes = Invoke-Rclone -RcloneArgs @("listremotes")
    if ($remotes.Text -split "`r?`n" | Where-Object { $_.Trim() -eq "$($script:RemoteName):" }) {
        $removed = Invoke-Rclone -RcloneArgs @("config", "delete", $script:RemoteName)
        if ($removed.ExitCode -ne 0) {
            Write-Host "Could not delete the rclone remote '$($script:RemoteName)'." -ForegroundColor Red
            if ($removed.Text) { Write-Host $removed.Text }
        } else {
            Write-Host "Removed rclone remote '$($script:RemoteName)'."
        }
    }
}

if (Test-Path -LiteralPath $script:LogFile) {
    Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "S3 drive has been removed for this Windows user." -ForegroundColor Cyan
Write-Host "WinFsp and rclone are still installed." -ForegroundColor Gray
if ($script:SettingsFile) {
    Write-Host "Left settings in $($script:SettingsFile)." -ForegroundColor Gray
}
if (-not $NoPause) { pause }
