# s3

Mount a [RustFS](https://github.com/rustfs/rustfs) server as a drive. On Windows the mount is a drive letter. On Ubuntu the mount is a folder. Anyone can use these scripts with their own S3-compatible RustFS endpoint.

| | Windows | Ubuntu |
|---|---|---|
| **Settings** | `settings.ini` | `.env` |
| **Mount** | Drive letter. The built-in letter is `K:` | Absolute folder in `S3_ROOT` |
| **Scripts** | `%LocalAppData%\s3` | `~/.local/share/s3` from the one-liner, or the clone |
| **Credentials** | `%AppData%\rclone\rclone.conf` | `~/.config/rclone/rclone.conf` |
| **Repository** | https://github.com/william-bohannan/s3 | https://github.com/william-bohannan/s3 |

## Windows

The built-in values are drive `K:`, remote name `s3`, volume name `S3 drive`, region `us-east-1`, and log `C:\git\s3\full.log`. Set `Endpoint` in `settings.ini`. When that value is missing, the installer asks for it. `settings.example.ini` is a filled-in sample.

### Install

Put `settings.ini` in the current directory (or in `C:\git\s3\settings.ini`) with your endpoint and keys. Then open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/william-bohannan/s3/main/install.ps1 | iex
```

The command downloads the scripts to `%LocalAppData%\s3`, asks for Administrator approval, and installs **WinFsp** and **rclone** with winget. Run the same line again to update the scripts.

When `settings.ini` contains a valid `AccessKey` and `SecretKey`, the installer uses them. When a key is missing or not valid, the installer asks for that key.

It reads the first `settings.ini` it finds:

1. The `-SettingsPath` argument
2. Next to the scripts
3. The current directory
4. `C:\git\s3\settings.ini`

The one-liner copies that file to `%LocalAppData%\s3\settings.ini` so the logon mount uses the same values. `settings.ini` stays on the machine after uninstall.

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

### settings.ini

Copy `settings.example.ini` to `settings.ini` and set it to your server. `settings.ini` is gitignored.

```ini
AccessKey=your-access-key
SecretKey=your-secret-key
Endpoint=https://s3.example.com
DriveLetter=K:
Region=us-east-1
RemoteName=rustfs
VolumeName=RustFS
LogFile=C:\git\s3\full.log
```

| Name | Valid value |
|---|---|
| `AccessKey`, `SecretKey` | Non-empty, no spaces. Both must be valid to skip the prompts. |
| `Endpoint` | `http` or `https` URL of your RustFS S3 API |
| `DriveLetter` | A free drive letter, with or without the colon (`K` or `K:`) |
| `Region` | A region name such as `us-east-1` |
| `RemoteName` | A short rclone remote name |
| `VolumeName` | 1–32 characters, the name shown for the drive |
| `LogFile` | A full path, including the file name |

A blank optional value is reported and the built-in default stays. An unknown name is reported and ignored. Lines starting with `#` or `;` are comments.

`DriveLetter`, `VolumeName`, and `LogFile` are read every time the mount starts. `AccessKey`, `SecretKey`, `Endpoint`, `Region`, and `RemoteName` are written into the rclone remote when the installer runs. After changing those, run the installer again. `start.ps1 -Restart` reloads the key already saved in `rclone.conf`.

### Scripts

| Script | What it does |
|---|---|
| `install.ps1` | Install WinFsp and rclone, save the rclone remote, register logon, start the drive. |
| `start.ps1` | Start the hidden mount. `-Restart` stops the running mount first so a new access key is loaded. |
| `stop.ps1` | Stop the mount. |
| `status.ps1` | Show the process, logon task, drive, settings file, and the last 20 log lines. Exits `1` when the mount is stopped. |
| `uninstall.ps1` | Remove the mount, the logon task, the rclone remote, and the log. WinFsp, rclone, and `settings.ini` stay. |
| `common.ps1` | Shared paths and mount helpers. |

After the one-liner, the scripts are in `%LocalAppData%\s3`. From a clone, run them from the clone.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\status.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -Restart
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

`-NoPause` on `install.ps1` and `uninstall.ps1` skips the final key press.

### What the installer does

1. Installs `WinFsp.WinFsp` and `Rclone.Rclone` with winget.
2. Reads the endpoint and credentials from `settings.ini`, or asks for any of them that are missing.
3. Creates an rclone `s3` remote (`provider=Other`, path-style URLs, no bucket check). RustFS hosts behind nginx need `sign_accept_encoding=false`, `use_x_id=false`, and `disable_http2=true`, and the installer sets those.
4. Lists buckets with `rclone lsd` to test the key. Open and save rights come from that key's server policy.
5. Registers the per-user logon task `MountS3`.
6. Starts the mount. A live rclone process keeps the key it loaded at startup, so this step restarts it.

The mount command uses `--links`, `--vfs-cache-mode full`, `--vfs-cache-max-age 1h`, `--vfs-write-back 0s`, `--dir-cache-time 30s`, `--buffer-size 64M`, `--transfers 8`, `--checkers 8`, and `--network-mode`. The window is hidden. Output is appended to the log.

A Windows service runs in session 0 and cannot show a drive in This PC. The logon task starts `start.ps1` in the interactive user session. An Administrator window does not see the mounted letter. `status.ps1` reports that when it is run elevated. If `start.ps1` itself is elevated, it schedules the mount back into the normal session.

### Requirements

- Windows 10 or 11
- winget (App Installer from the Microsoft Store)
- An access key for your RustFS server

### Removed on uninstall

- The hidden rclone mount
- Scheduled tasks `MountS3` and `MountS3-Now`
- The rclone remote named in `settings.ini` (built-in name `s3`)
- The log file

## Ubuntu

The built-in values are remote name `s3`, volume name `S3 drive`, region `us-east-1`, and log `~/.cache/rclone/s3-mount.log`. Set the endpoint, keys, and mount folder in `.env`. When a required value is missing, the installer asks for it.

### Install

Put `.env` in the current directory and run:

```bash
curl -fsSL https://raw.githubusercontent.com/william-bohannan/s3/main/install.sh | bash
```

The command saves `install.sh` and `.env.example` to `~/.local/share/s3`, installs **fuse3** with apt, and installs **rclone 1.67 or newer** into `~/.local/bin` when the copy already on `PATH` is older. Run the same line again to update the script and reload the mount.

From a clone of this repo:

```bash
bash install.sh
```

It reads the first `.env` it finds:

1. Next to the script
2. The current directory
3. `~/.config/s3/.env` (`$XDG_CONFIG_HOME/s3/.env` when that variable is set)

A `.env` found in the current directory or the config folder is copied next to the script, and that copy is limited to the owner. `.env` is gitignored.

### .env

Copy `.env.example` to `.env` and set it to your server. Values are read literally, so a secret can contain `$`, `&`, and `#`.

```bash
ACCESS_KEY_ID=your-access-key
SECRET_ACCESS_KEY=your-secret-key
S3_ENDPOINT_URL=https://s3.example.com
S3_ROOT=/mnt/s3
```

| Name | Valid value |
|---|---|
| `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY` | Non-empty, no spaces. Both must be valid to skip the prompts. |
| `S3_ENDPOINT_URL` | `http` or `https` URL of your RustFS S3 API |
| `S3_ROOT` | Absolute folder where the server appears. `/` is refused. |
| `REGION` | Optional. A region name such as `us-east-1`. Built-in value `us-east-1`. |
| `REMOTE_NAME` | Optional. A short rclone remote name. Built-in value `s3`. |
| `VOLUME_NAME` | Optional. 1–32 characters. Built-in value `S3 drive`. |
| `LOG_FILE` | Optional. A full path, including the file name. |

A blank optional value is reported and the built-in default stays. An unknown name is reported and ignored. Lines starting with `#` are comments.

`ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `S3_ENDPOINT_URL`, `REGION`, and `REMOTE_NAME` are written into the rclone remote when the installer runs. After changing those, run the installer again. The running mount is stopped and started again so it loads the new key.

### What the installer does

1. Installs `fuse3` with apt, plus `unzip` and `curl` when they are missing. rclone 1.67 or newer is required for the nginx signature options. An older packaged rclone stays in place, and a current build is installed in `~/.local/bin`.
2. Enables `user_allow_other` in `/etc/fuse.conf`. On systems that have a `fuse` group, it adds your user to that group.
3. Creates an rclone remote (`provider=Other`, path-style URLs, no bucket check, `sign_accept_encoding=false`, `use_x_id=false`, `disable_http2=true`).
4. Lists buckets with `rclone lsd` to test the key. Open and save rights come from that key's server policy.
5. Mounts the folder with `--allow-other` and the same cache settings as the Windows mount. The rclone process stays in the background. Output goes to the log.

The mount stays up until you stop it or restart the computer. Run the installer again after a restart.

Stop the mount with:

```bash
fusermount3 -u /mnt/s3
```

Use the folder from `S3_ROOT`. rclone, fuse3, and `.env` stay on the machine. Remove the saved remote with `rclone config delete s3` when you want that gone too. The built-in remote name is `s3`.

### Requirements

- Ubuntu, or another system with apt
- sudo for package install, `/etc/fuse.conf`, and a mount folder outside your home directory
- An access key for your RustFS server
