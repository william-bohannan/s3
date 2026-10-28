# Knoxxa Digital

Mount Knoxxa Digital (RustFS) as a drive on Windows. The mount is a hidden rclone process in the normal desktop session, and it starts again at logon.

| | |
|---|---|
| **Drive** | `K:` (volume name **Knoxxa Digital**) |
| **Endpoint** | `https://s31.knoxxa.digital` |
| **Admin console** | https://s31a.knoxxa.digital/rustfs/console/ |
| **rclone remote** | `knoxxa` |
| **Region** | `us-east-1` |
| **Log** | `C:\kd\s3\log.txt` |
| **Credentials** | `%AppData%\rclone\rclone.conf` |
| **Repository** | https://github.com/william-bohannan/s3 |

`settings.ini` can replace any of the drive, endpoint, region, remote name, volume name, and log values. See [settings.ini](#settingsini).

## Install

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/william-bohannan/s3/main/install.ps1 | iex
```

The command downloads the scripts to `%LocalAppData%\KnoxxaDigital`, asks for Administrator approval, and installs **WinFsp** and **rclone** with winget. Run the same line again to update the scripts.

When `settings.ini` contains a valid `AccessKey` and `SecretKey`, the installer uses them. When a key is missing or not valid, the installer asks for that key.

It reads the first `settings.ini` it finds:

1. The `-SettingsPath` argument
2. Next to the scripts
3. The current directory
4. `C:\kd\s3\settings.ini`

The one-liner copies that file to `%LocalAppData%\KnoxxaDigital\settings.ini` so the logon mount uses the same values. `settings.ini` stays on the machine after uninstall.

From a clone of this repo, right-click `install.ps1` and choose **Run with PowerShell**, or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

| Switch | Effect |
|---|---|
| `-SkipInstall` | Do not run winget. WinFsp and rclone must already be installed. |
| `-NoAutoStart` | Do not register the logon task. |
| `-NoMount` | Stop a running mount and do not start a new one. |
| `-NoPause` | Close without waiting for a key press. |
| `-AccessKey` / `-SecretKey` | Use these credentials for this run. They are not placed on the Administrator command line. |
| `-SettingsPath` | Read this `settings.ini` only. |

## settings.ini

Copy `settings.example.ini` to `settings.ini`. `settings.ini` is gitignored.

```ini
AccessKey=your-access-key
SecretKey=your-secret-key

# Endpoint=https://s31.knoxxa.digital
# DriveLetter=K:
# Region=us-east-1
# RemoteName=knoxxa
# VolumeName=Knoxxa Digital
# LogFile=C:\kd\s3\log.txt
```

| Name | Valid value |
|---|---|
| `AccessKey`, `SecretKey` | Non-empty, no spaces. Both must be valid to skip the prompts. |
| `Endpoint` | `http` or `https` URL |
| `DriveLetter` | A letter, with or without the colon (`K` or `K:`) |
| `Region` | A region name such as `us-east-1` |
| `RemoteName` | A short rclone remote name |
| `VolumeName` | 1–32 characters, the name shown for the drive |
| `LogFile` | A full path, including the file name |

A blank optional value is reported and the built-in default stays. An unknown name is reported and ignored. Lines starting with `#` or `;` are comments.

`DriveLetter`, `VolumeName`, and `LogFile` are read every time the mount starts. `AccessKey`, `SecretKey`, `Endpoint`, `Region`, and `RemoteName` are written into the rclone remote when the installer runs. After changing those, run the installer again. `start.ps1 -Restart` reloads the key already saved in `rclone.conf`.

## Scripts

| Script | What it does |
|---|---|
| `install.ps1` | Install WinFsp and rclone, save the rclone remote, register logon, start the drive. |
| `start.ps1` | Start the hidden mount. `-Restart` stops the running mount first so a new access key is loaded. |
| `stop.ps1` | Stop the mount. |
| `status.ps1` | Show the process, logon task, drive, settings file, and the last 20 log lines. Exits `1` when the mount is stopped. |
| `uninstall.ps1` | Remove the mount, the logon task, the rclone remote, and the log. WinFsp, rclone, and `settings.ini` stay. |
| `common.ps1` | Shared paths and mount helpers. |

After the one-liner, the scripts are in `%LocalAppData%\KnoxxaDigital`. From a clone, run them from the clone.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\status.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -Restart
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

`-NoPause` on `install.ps1` and `uninstall.ps1` skips the final key press.

## What the installer does

1. Installs `WinFsp.WinFsp` and `Rclone.Rclone` with winget.
2. Reads credentials from `settings.ini`, or asks for the access key and secret key.
3. Creates an rclone `s3` remote (`provider=Other`, path-style URLs, no bucket check). The RustFS host needs `sign_accept_encoding=false`, `use_x_id=false`, and `disable_http2=true`.
4. Lists buckets with `rclone lsd` to test the key. Open and save rights come from that key's server policy.
5. Registers the per-user logon task `MountKnoxxaRustFS`.
6. Starts the mount. A live rclone process keeps the key it loaded at startup, so this step restarts it.

The mount command uses `--links`, `--vfs-cache-mode full`, `--vfs-cache-max-age 1h`, `--vfs-write-back 0s`, `--dir-cache-time 30s`, `--buffer-size 64M`, `--transfers 8`, `--checkers 8`, and `--network-mode`. The window is hidden. Output is appended to the log.

A Windows service runs in session 0 and cannot show a drive in This PC. The logon task starts `start.ps1` in the interactive user session. An Administrator window does not see `K:`. `status.ps1` reports that when it is run elevated. If `start.ps1` itself is elevated, it schedules the mount back into the normal session.

## Requirements

- Windows 10 or 11
- winget (App Installer from the Microsoft Store)
- An access key for `https://s31.knoxxa.digital`

## Removed on uninstall

- The hidden rclone mount
- Scheduled tasks `MountKnoxxaRustFS` and `MountKnoxxaRustFS-Now`
- The rclone remote `knoxxa`
- The log file
- An older `Documents\Mount-Knoxxa.ps1`, if it is still present
