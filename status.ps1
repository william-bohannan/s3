# Show whether Knoxxa Digital (K:) is mounted.
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = "Stop"

$procs = @(Get-KnoxxaMountProcess)
$task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue

Write-Host "Knoxxa Digital ($($script:DriveLetter))"
if ($script:SettingsFile) {
    Write-Host "Settings: $($script:SettingsFile)"
} else {
    Write-Host "Settings: defaults"
}
if ($procs.Count -gt 0) {
    Write-Host "Process: running (pid $($procs[0].ProcessId))"
} else {
    Write-Host "Process: stopped"
}

if ($task) {
    Write-Host "Logon task: registered"
} else {
    Write-Host "Logon task: not registered"
}

if (Test-IsAdmin) {
    if ($procs.Count -gt 0) {
        Write-Host "Drive: mounted for the normal desktop. This Administrator window cannot see $($script:DriveLetter)."
    } else {
        Write-Host "Drive: not mounted"
    }
} elseif (Test-Path "$($script:DriveLetter)\") {
    Write-Host "Drive: present"
} else {
    Write-Host "Drive: not present"
}

Write-Host "Log: $($script:LogFile)"
Write-Host "----"
Write-Host (Get-KnoxxaLogTail -Lines 20)

if ($procs.Count -gt 0) { exit 0 }
exit 1
