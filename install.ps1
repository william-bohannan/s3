# Install the S3 drive as a hidden mount.
# One-liner from PowerShell:
#   irm https://raw.githubusercontent.com/william-bohannan/s3/main/install.ps1 | iex
# A settings.ini with valid values is used. Missing or invalid keys are requested.
# Logs: C:\git\s3\full.log
# Control: start.ps1, stop.ps1, status.ps1, uninstall.ps1

& {
param(
    [switch]$SkipInstall,
    [switch]$NoAutoStart,
    [switch]$NoMount,
    [switch]$NoPause,
    [string]$AccessKey,
    [string]$SecretKey,
    [string]$SettingsPath
)

$ErrorActionPreference = "Stop"
$s3Inline = -not $PSCommandPath

function Save-S3Download {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [switch]$Required
    )

    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    } catch {
        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }
        if ($Required) { throw }
        Write-Host "Skipped optional file $([IO.Path]::GetFileName($OutFile))." -ForegroundColor Yellow
        return
    }

    if (-not $Required) { return }
    $sample = @(Get-Content -LiteralPath $OutFile -TotalCount 12 -ErrorAction SilentlyContinue)
    $text = $sample -join "`n"
    if ($text -notmatch 's3 drive') {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        throw "Download of $([IO.Path]::GetFileName($OutFile)) did not look like an s3 drive script."
    }
}

$scriptDir = $PSScriptRoot
if (-not $scriptDir -and $PSCommandPath) {
    $scriptDir = Split-Path -Parent $PSCommandPath
}
$bundled = $scriptDir -and (Test-Path -LiteralPath (Join-Path $scriptDir "common.ps1"))

if (-not $bundled) {
    $previousProgress = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $dest = Join-Path $env:LOCALAPPDATA "s3"
        $staging = Join-Path $env:TEMP ("s3-" + [guid]::NewGuid().ToString("n"))
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $base = "https://raw.githubusercontent.com/william-bohannan/s3/main"
        Write-Host "Downloading S3 drive to $dest..." -ForegroundColor Cyan

        foreach ($name in @("common.ps1", "install.ps1", "start.ps1", "stop.ps1", "status.ps1", "uninstall.ps1")) {
            Save-S3Download -Url "$base/$name" -OutFile (Join-Path $staging $name) -Required
        }
        foreach ($name in @("README.md", "settings.example.ini")) {
            Save-S3Download -Url "$base/$name" -OutFile (Join-Path $staging $name)
        }

        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        foreach ($file in @(Get-ChildItem -LiteralPath $staging -File)) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dest $file.Name) -Force
        }

        $forward = New-Object System.Collections.Generic.List[string]
        if ($SkipInstall) { $forward.Add("-SkipInstall") }
        if ($NoAutoStart) { $forward.Add("-NoAutoStart") }
        if ($NoMount) { $forward.Add("-NoMount") }
        if ($NoPause) { $forward.Add("-NoPause") }

        $settingsSource = $null
        if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) {
            $settingsSource = $SettingsPath
        } else {
            $cwdIni = Join-Path (Get-Location).Path "settings.ini"
            if (Test-Path -LiteralPath $cwdIni) {
                $settingsSource = (Resolve-Path -LiteralPath $cwdIni).Path
            } elseif (Test-Path -LiteralPath "C:\git\s3\settings.ini") {
                $settingsSource = (Resolve-Path -LiteralPath "C:\git\s3\settings.ini").Path
            }
        }

        $settingsTarget = Join-Path $dest "settings.ini"
        if ($settingsSource -and (Test-Path -LiteralPath $settingsSource)) {
            $full = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $settingsSource).Path)
            $targetFull = [System.IO.Path]::GetFullPath($settingsTarget)
            if ($full.ToLower() -ne $targetFull.ToLower()) {
                Copy-Item -LiteralPath $full -Destination $targetFull -Force
            }
            $forward.Add("-SettingsPath")
            $forward.Add($(if (Test-Path -LiteralPath $targetFull) { $targetFull } else { $full }))
        } elseif (-not [string]::IsNullOrWhiteSpace($settingsSource)) {
            $forward.Add("-SettingsPath")
            $forward.Add($settingsSource)
        }

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest "install.ps1") @forward
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE }
    } catch {
        Write-Host "Could not download the S3 drive scripts." -ForegroundColor Red
        Write-Host $_.Exception.Message
        Write-Host "Clone https://github.com/william-bohannan/s3 and run install.ps1 from that folder."
        if (-not $NoPause) { pause }
        $code = 1
    } finally {
        $ProgressPreference = $previousProgress
        if ($staging -and (Test-Path -LiteralPath $staging)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($s3Inline) { return }
    exit $code
}

$script:KeepS3Credentials = $true
. "$PSScriptRoot\common.ps1"

function Hide-Secret {
    param([string]$Text)
    if ($SecretKey -and $Text) {
        return $Text.Replace($SecretKey, "********")
    }
    return $Text
}

# Re-launch elevated for winget installs. Switches are forwarded.
# Credentials stay off the elevated command line. The new process reads settings.ini.
if (-not $SkipInstall -and -not (Test-IsAdmin)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    $argList = New-Object System.Collections.Generic.List[string]
    $argList.Add("-NoProfile")
    $argList.Add("-ExecutionPolicy")
    $argList.Add("Bypass")
    $argList.Add("-File")
    $argList.Add($PSCommandPath)
    if ($NoAutoStart) { $argList.Add("-NoAutoStart") }
    if ($NoMount) { $argList.Add("-NoMount") }
    if ($NoPause) { $argList.Add("-NoPause") }
    if ($script:SettingsFile) {
        $argList.Add("-SettingsPath")
        $argList.Add($script:SettingsFile)
    } elseif (-not [string]::IsNullOrWhiteSpace($SettingsPath)) {
        $argList.Add("-SettingsPath")
        $argList.Add($SettingsPath)
    }
    Start-Process -FilePath "powershell.exe" -ArgumentList (Format-S3ProcessArguments -Items @($argList.ToArray())) -Verb RunAs
    exit
}

if ([string]::IsNullOrWhiteSpace($script:Endpoint)) {
    $enteredEndpoint = Read-Host "RustFS endpoint (https://...)"
    $endpointError = Get-S3SettingError -Name "Endpoint" -Value $enteredEndpoint
    if ($endpointError) {
        Write-Host "Endpoint $endpointError" -ForegroundColor Red
        if (-not $NoPause) { pause }
        exit 1
    }
    $script:Endpoint = Convert-S3SettingValue -Name "Endpoint" -Value $enteredEndpoint
}

Write-Host "=== S3 drive install ($($script:DriveLetter)) ===" -ForegroundColor Cyan
Write-Host "Endpoint: $($script:Endpoint)" -ForegroundColor Gray
if ($script:SettingsFile) {
    Write-Host "Settings: $($script:SettingsFile)" -ForegroundColor Gray
}
Write-Host ""

if (-not $SkipInstall) {
    Write-Host "[1/5] Installing WinFsp and rclone (winget)..." -ForegroundColor Green

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Host "winget not found. Install App Installer from the Microsoft Store, then re-run." -ForegroundColor Red
        if (-not $NoPause) { pause }
        exit 1
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & winget install --id WinFsp.WinFsp -e --accept-package-agreements --accept-source-agreements --silent | Out-Null
        & winget install --id Rclone.Rclone -e --accept-package-agreements --accept-source-agreements --silent | Out-Null
    } finally {
        $ErrorActionPreference = $previous
    }

    Update-S3Path
    Write-Host "Install complete." -ForegroundColor Green
} else {
    Write-Host "[1/5] Skipping install (as requested)." -ForegroundColor Yellow
    Update-S3Path
}

if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    Write-Host "rclone not found in PATH. Open a new terminal or reboot, then re-run." -ForegroundColor Red
    if (-not $NoPause) { pause }
    exit 1
}

$winfsp = Get-Service -Name "WinFsp.Launcher" -ErrorAction SilentlyContinue
if (-not $winfsp) {
    Write-Host "WinFsp is not installed (service WinFsp.Launcher is missing). Re-run without -SkipInstall." -ForegroundColor Red
    if (-not $NoPause) { pause }
    exit 1
}

Write-Host ""
Write-Host "[2/5] RustFS credentials" -ForegroundColor Green

foreach ($warning in @($script:SettingsWarnings)) {
    Write-Host "settings.ini: $warning" -ForegroundColor Yellow
}
if (-not [string]::IsNullOrWhiteSpace($SettingsPath) -and -not $script:SettingsFile) {
    Write-Host "The settings file could not be used." -ForegroundColor Red
    if (-not $NoPause) { pause }
    exit 1
}

$creds = Get-S3InstallCredentials -AccessKey $AccessKey -SecretKey $SecretKey
$AccessKey = $creds.AccessKey
$SecretKey = $creds.SecretKey

if ($creds.AccessFromIni -and $creds.SecretFromIni) {
    Write-Host "Using AccessKey and SecretKey from $($creds.SettingsFile)." -ForegroundColor Green
    Write-Host "Saved for this Windows user in %AppData%\rclone\rclone.conf."
} else {
    Write-Host "Saved for this Windows user in %AppData%\rclone\rclone.conf."
    if ($creds.AccessFromIni) {
        Write-Host "Using AccessKey from $($creds.SettingsFile)." -ForegroundColor Green
    }
    if ($creds.SecretFromIni) {
        Write-Host "Using SecretKey from $($creds.SettingsFile)." -ForegroundColor Green
    }
    if ([string]::IsNullOrWhiteSpace($AccessKey)) {
        $AccessKey = Read-Host "Access Key"
    }
    if ([string]::IsNullOrWhiteSpace($SecretKey)) {
        $secureSecret = Read-Host "Secret Key" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
        try {
            $SecretKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

if ([string]::IsNullOrWhiteSpace($AccessKey) -or [string]::IsNullOrWhiteSpace($SecretKey)) {
    Write-Host "Credentials cannot be empty." -ForegroundColor Red
    if (-not $NoPause) { pause }
    exit 1
}

Write-Host ""
Write-Host "[3/5] Configuring rclone remote '$($script:RemoteName)'..." -ForegroundColor Green

$remotes = Invoke-Rclone -RcloneArgs @("listremotes")
if ($remotes.Text -split "`r?`n" | Where-Object { $_.Trim() -eq "$($script:RemoteName):" }) {
    $removed = Invoke-Rclone -RcloneArgs @("config", "delete", $script:RemoteName)
    if ($removed.ExitCode -ne 0) {
        Write-Host "Could not replace the existing '$($script:RemoteName)' remote." -ForegroundColor Red
        Write-Host (Hide-Secret $removed.Text)
        if (-not $NoPause) { pause }
        exit 1
    }
}

# nginx in front of this RustFS host rewrites headers that rclone 1.75 signs
# by default (Accept-Encoding, x-id, HTTP/2). Leaving them signed returns
# SignatureDoesNotMatch even when the access key is valid.
$created = Invoke-Rclone -RcloneArgs @(
    "config", "create", $script:RemoteName, "s3",
    "provider", "Other",
    "endpoint", $script:Endpoint,
    "access_key_id", $AccessKey,
    "secret_access_key", $SecretKey,
    "region", $script:Region,
    "force_path_style", "true",
    "no_check_bucket", "true",
    "sign_accept_encoding", "false",
    "use_x_id", "false",
    "disable_http2", "true",
    # S3 has no folders. This uploads a zero-byte object ending in /
    # when a directory is created, so other machines can see it.
    "directory_markers", "true"
)
if ($created.ExitCode -ne 0) {
    Write-Host "rclone config create failed." -ForegroundColor Red
    Write-Host (Hide-Secret $created.Text)
    if (-not $NoPause) { pause }
    exit 1
}

Write-Host "Remote configured." -ForegroundColor Green

Write-Host ""
Write-Host "[4/5] Testing connection..." -ForegroundColor Green
$test = Invoke-Rclone -RcloneArgs @("lsd", "$($script:RemoteName):", "--max-depth", "1")
if ($test.ExitCode -ne 0) {
    Write-Host "Connection test failed." -ForegroundColor Red
    if ($test.Text) { Write-Host (Hide-Secret $test.Text) }
    if (-not $NoPause) { pause }
    exit 1
}

Write-Host "Connection successful." -ForegroundColor Green
$bucketNames = @()
foreach ($line in ($test.Text -split "`r?`n")) {
    $trim = $line.Trim()
    if (-not $trim -or $trim -match '^(ERROR|NOTICE|Failed)') { continue }
    $parts = $trim -split '\s+'
    $bucketNames += $parts[-1]
}
if ($bucketNames.Count -eq 0) {
    Write-Host "This access key cannot list any buckets." -ForegroundColor Yellow
} else {
    Write-Host "This access key can list:" -ForegroundColor Green
    foreach ($name in $bucketNames) { Write-Host "  $name" }
}
Write-Host "Open and save rights come from this key's server policy." -ForegroundColor Gray

if (Test-Path -LiteralPath $script:LegacyMountScript) {
    Remove-Item -LiteralPath $script:LegacyMountScript -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($NoAutoStart) {
    Write-Host "[5/5] Skipping the logon task (as requested)." -ForegroundColor Yellow
} else {
    Write-Host "[5/5] Registering the logon task..." -ForegroundColor Green
    Register-S3LogonTask
    Write-Host "$($script:DriveLetter) will mount in the background at logon." -ForegroundColor Green
}

$SecretKey = $null
$AccessKey = $null
if ($script:S3Ini) {
    [void]$script:S3Ini.Remove("AccessKey")
    [void]$script:S3Ini.Remove("SecretKey")
}

if (-not $NoMount) {
    Write-Host "Restarting the mount so $($script:DriveLetter) uses this access key..." -ForegroundColor Green
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\start.ps1" -Restart
    if ($LASTEXITCODE -ne 0) {
        Write-Host "The mount did not start. See $($script:LogFile)" -ForegroundColor Red
        if (-not $NoPause) { pause }
        exit 1
    }
} else {
    Write-Host "Stopping the previous mount so it cannot keep the old access key." -ForegroundColor Yellow
    Stop-S3Mount
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host "Log: $($script:LogFile)" -ForegroundColor Gray
Write-Host "Status: powershell -File `"$PSScriptRoot\status.ps1`"" -ForegroundColor Gray
Write-Host "Stop:   powershell -File `"$PSScriptRoot\stop.ps1`"" -ForegroundColor Gray
if (-not $NoPause) { pause }
} @args
