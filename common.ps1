# Shared paths and mount helpers for the s3 drive scripts.
# A Windows service runs in session 0 and cannot show a drive in This PC.
# The mount is a hidden rclone process in the normal user session.

# Built-in values. settings.ini overrides a value when that value is valid.
$script:S3Defaults = @{
    RemoteName = "s3"
    Endpoint = ""
    DriveLetter = "K:"
    Region = "us-east-1"
    VolumeName = "S3 drive"
    LogFile = "C:\git\s3\full.log"
}
$script:TaskName = "MountS3"
$script:TaskNow = "MountS3-Now"
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LegacyMountScript = Join-Path $env:USERPROFILE "Documents\Mount-Knoxxa.ps1"
$script:SettingsFile = $null
$script:S3Ini = @{}
$script:SettingsWarnings = @()

$script:S3SettingNames = @{
    accesskey = "AccessKey"
    secretkey = "SecretKey"
    endpoint = "Endpoint"
    driveletter = "DriveLetter"
    region = "Region"
    remotename = "RemoteName"
    volumename = "VolumeName"
    logfile = "LogFile"
}

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-S3Path {
    $machine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Get-S3MountProcess {
    $drive = [regex]::Escape($script:DriveLetter)
    return @(Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '\bmount\b' -and $_.CommandLine -match $drive })
}

function Test-S3BackgroundMount {
    $log = [regex]::Escape($script:LogFile)
    foreach ($proc in @(Get-S3MountProcess)) {
        if ($proc.CommandLine -match $log) { return $true }
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.ParentProcessId)" -ErrorAction SilentlyContinue
        if ($parent -and $parent.CommandLine -match $log) { return $true }
    }
    return $false
}

function Stop-S3Mount {
    $log = [regex]::Escape($script:LogFile)
    Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match $log } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($proc in @(Get-S3MountProcess)) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'Mount-Knoxxa\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    if (Test-Path "$($script:DriveLetter)\") {
        & net.exe use $script:DriveLetter /delete /y | Out-Null
    }
}

function Get-S3LogTail {
    param([int]$Lines = 20)
    if (-not (Test-Path -LiteralPath $script:LogFile)) {
        return "(no log yet)"
    }
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open(
            $script:LogFile,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $reader = New-Object System.IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
    } catch {
        return "(log is in use by the mount)"
    } finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
    $all = @($text -split "`r?`n" | Where-Object { $_ -ne "" })
    if ($all.Count -eq 0) { return "(log is empty)" }
    return ($all | Select-Object -Last $Lines) -join [Environment]::NewLine
}

function Start-S3Hidden {
    Update-S3Path
    $rclone = (Get-Command rclone -ErrorAction SilentlyContinue).Source
    if (-not $rclone) { throw "rclone not found in PATH." }

    $dir = Split-Path -Parent $script:LogFile
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    "$(Get-Date -Format o) starting S3 drive on $($script:DriveLetter)" | Add-Content -LiteralPath $script:LogFile -Encoding UTF8

    # Leading and trailing quotes are required so cmd.exe /c keeps the inner quotes.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c `"`"$rclone`" mount $($script:RemoteName): $($script:DriveLetter) --links --vfs-cache-mode full --vfs-cache-max-age 1h --vfs-write-back 0s --dir-cache-time 30s --buffer-size 64M --transfers 8 --checkers 8 --network-mode --volname `"$($script:VolumeName)`" >> `"$($script:LogFile)`" 2>&1`""
    $psi.WorkingDirectory = $dir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [void][System.Diagnostics.Process]::Start($psi)

    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Seconds 1
        $up = @(Get-S3MountProcess)
    } while ($up.Count -eq 0 -and (Get-Date) -lt $deadline)

    if ($up.Count -eq 0) {
        throw "The mount process did not start. See $($script:LogFile)"
    }
}

function Start-S3InUserSession {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

    Unregister-ScheduledTask -TaskName $script:TaskNow -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $script:TaskNow -Action $action -Principal $principal -Settings $settings -Description "Start the S3 drive mount in the user session" | Out-Null
    try {
        Start-ScheduledTask -TaskName $script:TaskNow
        $deadline = (Get-Date).AddSeconds(25)
        do {
            Start-Sleep -Seconds 1
            $up = @(Get-S3MountProcess)
        } while ($up.Count -eq 0 -and (Get-Date) -lt $deadline)
    } finally {
        Unregister-ScheduledTask -TaskName $script:TaskNow -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (-not $up -or @($up).Count -eq 0) {
        throw "The mount process did not start. See $($script:LogFile)"
    }
}

function Register-S3LogonTask {
    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $startScript = Join-Path $script:Root "start.ps1"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)

    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Mount S3 drive as $($script:DriveLetter) in the background at logon" | Out-Null
}

function Unregister-S3Tasks {
    foreach ($name in @($script:TaskName, $script:TaskNow, "MountKnoxxaRustFS", "MountKnoxxaRustFS-Now")) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# PowerShell 5.1 turns native stderr into a terminating error when
# $ErrorActionPreference is Stop, even if stderr is redirected.
function Invoke-Rclone {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$RcloneArgs
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & rclone @RcloneArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }

    $text = (@($raw) | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            if ($_.Exception.Message) { $_.Exception.Message } else { $_.ToString() }
        } else {
            "$_"
        }
    }) -join "`n"

    return [pscustomobject]@{
        ExitCode = $code
        Text = $text.Trim()
    }
}

function Reset-S3Defaults {
    $script:RemoteName = $script:S3Defaults.RemoteName
    $script:Endpoint = $script:S3Defaults.Endpoint
    $script:DriveLetter = $script:S3Defaults.DriveLetter
    $script:Region = $script:S3Defaults.Region
    $script:VolumeName = $script:S3Defaults.VolumeName
    $script:LogFile = $script:S3Defaults.LogFile
}

function Find-S3SettingsFile {
    param(
        [string]$Explicit,
        [string]$ScriptDir
    )

    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        if (Test-Path -LiteralPath $Explicit) {
            return (Resolve-Path -LiteralPath $Explicit).Path
        }
        return $Explicit
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ScriptDir)) {
        $candidates.Add((Join-Path $ScriptDir "settings.ini"))
    }
    try {
        $candidates.Add((Join-Path (Get-Location).Path "settings.ini"))
    } catch {
    }
    $candidates.Add("C:\git\s3\settings.ini")

    $seen = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $full = (Resolve-Path -LiteralPath $candidate).Path
        $key = $full.ToLower()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        return $full
    }
    return $null
}

function Read-S3Ini {
    param([Parameter(Mandatory = $true)][string]$Path)

    $map = @{}
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $trim = $line.Trim()
        if ($trim.Length -eq 0) { continue }
        if ($trim.StartsWith("#") -or $trim.StartsWith(";")) { continue }
        if ($trim.StartsWith("[")) { continue }
        $eq = $trim.IndexOf("=")
        if ($eq -lt 1) { continue }
        $rawKey = $trim.Substring(0, $eq).Trim()
        $rawVal = $trim.Substring($eq + 1).Trim()
        if ($rawVal.Length -ge 2) {
            $quote = $rawVal[0]
            if (($quote -eq '"' -or $quote -eq "'") -and $rawVal[$rawVal.Length - 1] -eq $quote) {
                $rawVal = $rawVal.Substring(1, $rawVal.Length - 2)
            }
        }
        $lookup = $rawKey.ToLower()
        if ($script:S3SettingNames.ContainsKey($lookup)) {
            $map[$script:S3SettingNames[$lookup]] = $rawVal
        } else {
            $map[$rawKey] = $rawVal
        }
    }
    return $map
}

function Get-S3SettingError {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    $v = ""
    if ($null -ne $Value) { $v = $Value.Trim() }
    if ([string]::IsNullOrWhiteSpace($v)) { return "is empty." }
    if ($v.Length -gt 1024) { return "is too long." }

    switch ($Name) {
        "AccessKey" {
            if ($v -match '\s') { return "cannot contain spaces." }
            return $null
        }
        "SecretKey" {
            if ($v -match '\s') { return "cannot contain spaces." }
            return $null
        }
        "Endpoint" {
            $uri = $null
            $ok = [Uri]::TryCreate($v, [UriKind]::Absolute, [ref]$uri)
            if (-not $ok -or ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https") -or [string]::IsNullOrWhiteSpace($uri.Host)) {
                return "must be an http or https URL."
            }
            return $null
        }
        "DriveLetter" {
            if ($v -notmatch '^[A-Za-z]:?$') { return "must be a drive letter such as K:." }
            return $null
        }
        "Region" {
            if ($v -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,31}$') { return "must be a region name such as us-east-1." }
            return $null
        }
        "RemoteName" {
            if ($v -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$') { return "must be a short rclone remote name." }
            return $null
        }
        "VolumeName" {
            if ($v.Length -gt 32) { return "must be 32 characters or fewer." }
            if ($v -match '[<>:"/\\|?*]') { return "cannot contain file-name symbols." }
            return $null
        }
        "LogFile" {
            if (-not [System.IO.Path]::IsPathRooted($v)) { return "must be a full path." }
            $leaf = [System.IO.Path]::GetFileName($v)
            if ([string]::IsNullOrWhiteSpace($leaf)) { return "must include a file name." }
            if ($leaf -match '[<>:"/\\|?*]') { return "cannot contain file-name symbols." }
            return $null
        }
    }
    return "is not a known setting."
}

function Convert-S3SettingValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $v = $Value.Trim()
    switch ($Name) {
        "DriveLetter" {
            $letter = $v.TrimEnd(":")
            return ($letter.Substring(0, 1).ToUpper() + ":")
        }
        "Endpoint" {
            return $v.TrimEnd("/")
        }
        default { return $v }
    }
}

function Import-S3Settings {
    param([string]$Path)

    Reset-S3Defaults
    $script:S3Ini = @{}
    $script:SettingsWarnings = @()
    $script:SettingsFile = $null

    $explicit = $Path
    if ([string]::IsNullOrWhiteSpace($explicit) -and (Test-Path -Path "Variable:SettingsPath")) {
        $explicit = [string]$SettingsPath
    }

    $found = Find-S3SettingsFile -Explicit $explicit -ScriptDir $script:Root
    if ([string]::IsNullOrWhiteSpace($found)) { return }
    if (-not (Test-Path -LiteralPath $found)) {
        $script:SettingsWarnings += "Settings file not found: $found"
        return
    }

    $script:SettingsFile = (Resolve-Path -LiteralPath $found).Path
    try {
        $map = Read-S3Ini -Path $script:SettingsFile
    } catch {
        $script:SettingsWarnings += "Could not read $($script:SettingsFile). $($_.Exception.Message)"
        $script:SettingsFile = $null
        return
    }

    $configNames = @("Endpoint", "DriveLetter", "Region", "RemoteName", "VolumeName", "LogFile")
    foreach ($name in $configNames) {
        if (-not $map.ContainsKey($name)) { continue }
        $err = Get-S3SettingError -Name $name -Value ([string]$map[$name])
        if ($err) {
            $script:SettingsWarnings += "$name $err"
            continue
        }
        $value = Convert-S3SettingValue -Name $name -Value ([string]$map[$name])
        switch ($name) {
            "Endpoint" { $script:Endpoint = $value }
            "DriveLetter" { $script:DriveLetter = $value }
            "Region" { $script:Region = $value }
            "RemoteName" { $script:RemoteName = $value }
            "VolumeName" { $script:VolumeName = $value }
            "LogFile" { $script:LogFile = $value }
        }
    }

    foreach ($name in @("AccessKey", "SecretKey")) {
        if (-not $map.ContainsKey($name)) { continue }
        $err = Get-S3SettingError -Name $name -Value ([string]$map[$name])
        if ($err) {
            # A blank key in the example file means "ask", which is not a warning.
            if ($err -ne "is empty.") {
                $script:SettingsWarnings += "$name $err"
            }
            continue
        }
        # start/stop/status do not keep the keys in memory. install.ps1 opts in.
        if ($script:KeepS3Credentials) {
            $script:S3Ini[$name] = Convert-S3SettingValue -Name $name -Value ([string]$map[$name])
        }
    }

    foreach ($key in @($map.Keys)) {
        $known = $false
        foreach ($name in ($configNames + @("AccessKey", "SecretKey"))) {
            if ($name -eq $key) { $known = $true }
        }
        if (-not $known) {
            $script:SettingsWarnings += "Ignored unknown setting $key."
        }
    }
}

function Format-S3ProcessArguments {
    param([Parameter(Mandatory = $true)][string[]]$Items)
    return (($Items | ForEach-Object {
        $text = [string]$_
        if ($text -match '[\s"]') {
            '"' + ($text.Replace('"', '\"')) + '"'
        } else {
            $text
        }
    }) -join " ")
}

function Get-S3InstallCredentials {
    param(
        [string]$AccessKey,
        [string]$SecretKey
    )

    $access = $AccessKey
    $secret = $SecretKey
    $accessFromIni = $false
    $secretFromIni = $false
    if ([string]::IsNullOrWhiteSpace($access) -and $script:S3Ini.ContainsKey("AccessKey")) {
        $access = [string]$script:S3Ini["AccessKey"]
        $accessFromIni = $true
    }
    if ([string]::IsNullOrWhiteSpace($secret) -and $script:S3Ini.ContainsKey("SecretKey")) {
        $secret = [string]$script:S3Ini["SecretKey"]
        $secretFromIni = $true
    }

    return [pscustomobject]@{
        AccessKey = $access
        SecretKey = $secret
        AccessFromIni = $accessFromIni
        SecretFromIni = $secretFromIni
        SettingsFile = $script:SettingsFile
    }
}

Reset-S3Defaults
Import-S3Settings
