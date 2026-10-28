#!/usr/bin/env bash
# Install the S3 drive on Ubuntu and mount a RustFS server as a folder.
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/william-bohannan/s3/main/install.sh | bash
# Run it again after changing .env so the mount picks up the new access key.
# After the mount is up, it asks whether to install and start s3-ensure-dirs.

set -euo pipefail

S3_RAW_BASE="https://raw.githubusercontent.com/william-bohannan/s3/main"
SOURCE_PATH="${BASH_SOURCE[0]:-}"
TMP_FILES=()
TMP_DIRS=()

ACCESS_KEY_ID=""
SECRET_ACCESS_KEY=""
S3_ENDPOINT_URL=""
S3_ROOT=""
REMOTE_NAME="s3"
REGION="us-east-1"
VOLUME_NAME="S3 drive"
LOG_FILE=""
ENV_FILE=""
RCLONE=""
SCRIPT_DIR=""
MISSING_REQUIRED=()
SETTINGS_WARNINGS=()
PROMPTED=()

cleanup() {
  local f d
  if ((${#TMP_FILES[@]})); then
    for f in "${TMP_FILES[@]}"; do
      rm -f "$f"
    done
  fi
  if ((${#TMP_DIRS[@]})); then
    for d in "${TMP_DIRS[@]}"; do
      rm -rf "$d"
    done
  fi
}
trap cleanup EXIT

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

warn() {
  printf '%s\n' "$*" >&2
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

trim_slashes() {
  local s="$1"
  while [[ "$s" == */ && "$s" != "/" ]]; do
    s="${s%/}"
  done
  printf '%s' "$s"
}

is_saved_script() {
  local src="$SOURCE_PATH"
  [[ -n "$src" ]] || return 1
  case "$src" in
    bash|*/bash|/dev/fd/*|/proc/self/fd/*|/proc/[0-9]*/fd/*) return 1 ;;
  esac
  [[ -f "$src" ]]
}

reset_settings() {
  ACCESS_KEY_ID=""
  SECRET_ACCESS_KEY=""
  S3_ENDPOINT_URL=""
  S3_ROOT=""
  REMOTE_NAME="s3"
  REGION="us-east-1"
  VOLUME_NAME="S3 drive"
  LOG_FILE=""
  MISSING_REQUIRED=()
  SETTINGS_WARNINGS=()
  PROMPTED=()
}

endpoint_error() {
  local value="$1" lower
  if [[ -z "$value" ]]; then
    printf '%s' "is empty."
    return
  fi
  if [[ "$value" == *[[:space:]]* || ${#value} -gt 1024 ]]; then
    printf '%s' "must be an http or https URL."
    return
  fi
  lower="${value,,}"
  if [[ ! "$lower" =~ ^https?://[^[:space:]/?#]+ ]]; then
    printf '%s' "must be an http or https URL."
  fi
}

credential_error() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s' "is empty."
    return
  fi
  if [[ "$value" == *[[:space:]]* ]]; then
    printf '%s' "cannot contain spaces."
    return
  fi
  if ((${#value} > 1024)); then
    printf '%s' "is too long."
  fi
}

region_error() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s' "is empty."
    return
  fi
  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,31}$ ]]; then
    printf '%s' "must be a region name such as us-east-1."
  fi
}

remote_error() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s' "is empty."
    return
  fi
  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]; then
    printf '%s' "must be a short rclone remote name."
  fi
}

volume_error() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s' "is empty."
    return
  fi
  if ((${#value} > 32)); then
    printf '%s' "must be 32 characters or fewer."
    return
  fi
  if [[ "$value" =~ [\<\>\"/\\|?*] || "$value" == *:* ]]; then
    printf '%s' "cannot contain file-name symbols."
  fi
}

log_error() {
  local value="$1" leaf
  if [[ -z "$value" ]]; then
    printf '%s' "is empty."
    return
  fi
  if [[ "$value" != /* || "$value" == */ ]]; then
    printf '%s' "must be a full path, including the file name."
    return
  fi
  leaf="${value##*/}"
  if [[ -z "$leaf" || "$leaf" =~ [\<\>\"/\\|?*] || "$leaf" == *:* ]]; then
    printf '%s' "cannot contain file-name symbols."
  fi
}

root_error() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s' "is empty."
    return
  fi
  if [[ "$value" != /* ]]; then
    printf '%s' "must be an absolute path."
    return
  fi
  if [[ "$value" == "/" ]]; then
    printf '%s' "cannot be the filesystem root."
  fi
}

mark_missing() {
  local name="$1"
  local item
  for item in "${MISSING_REQUIRED[@]+"${MISSING_REQUIRED[@]}"}"; do
    [[ "$item" == "$name" ]] && return 0
  done
  MISSING_REQUIRED+=("$name")
}

parse_env_file() {
  local file="$1" line key value err
  reset_settings
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      SETTINGS_WARNINGS+=("Skipping a malformed line.")
      continue
    fi
    key="${line%%=*}"
    key="$(trim "$key")"
    value="${line#*=}"
    value="$(trim "$value")"
    if [[ ${#value} -ge 2 ]]; then
      if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi
    case "$key" in
      ACCESS_KEY_ID|SECRET_ACCESS_KEY)
        err="$(credential_error "$value")"
        if [[ -n "$err" ]]; then
          # A blank key means "ask". Any other problem is reported.
          # The last line for a key wins, so a bad line clears an earlier value.
          if [[ "$err" != "is empty." ]]; then
            SETTINGS_WARNINGS+=("${key} ${err}")
          fi
          if [[ "$key" == ACCESS_KEY_ID ]]; then
            ACCESS_KEY_ID=""
          else
            SECRET_ACCESS_KEY=""
          fi
        elif [[ "$key" == ACCESS_KEY_ID ]]; then
          ACCESS_KEY_ID="$value"
        else
          SECRET_ACCESS_KEY="$value"
        fi
        ;;
      S3_ENDPOINT_URL)
        err="$(endpoint_error "$value")"
        if [[ -n "$err" ]]; then
          SETTINGS_WARNINGS+=("S3_ENDPOINT_URL ${err}")
          S3_ENDPOINT_URL=""
        else
          S3_ENDPOINT_URL="$(trim_slashes "$value")"
        fi
        ;;
      S3_ROOT)
        value="$(trim_slashes "$value")"
        err="$(root_error "$value")"
        if [[ -n "$err" ]]; then
          SETTINGS_WARNINGS+=("S3_ROOT ${err}")
          S3_ROOT=""
        else
          S3_ROOT="$value"
        fi
        ;;
      REGION)
        err="$(region_error "$value")"
        if [[ -n "$err" ]]; then
          SETTINGS_WARNINGS+=("REGION ${err} Using us-east-1.")
          REGION="us-east-1"
        else
          REGION="$value"
        fi
        ;;
      REMOTE_NAME)
        err="$(remote_error "$value")"
        if [[ -n "$err" ]]; then
          SETTINGS_WARNINGS+=("REMOTE_NAME ${err} Using s3.")
          REMOTE_NAME="s3"
        else
          REMOTE_NAME="$value"
        fi
        ;;
      VOLUME_NAME)
        err="$(volume_error "$value")"
        if [[ -n "$err" ]]; then
          SETTINGS_WARNINGS+=("VOLUME_NAME ${err} Using S3 drive.")
          VOLUME_NAME="S3 drive"
        else
          VOLUME_NAME="$value"
        fi
        ;;
      LOG_FILE)
        err="$(log_error "$value")"
        if [[ -n "$err" ]]; then
          SETTINGS_WARNINGS+=("LOG_FILE ${err}")
          LOG_FILE=""
        else
          LOG_FILE="$value"
        fi
        ;;
      *)
        SETTINGS_WARNINGS+=("Unknown name ${key}.")
        ;;
    esac
  done < "$file"

  [[ -n "$ACCESS_KEY_ID" ]] || mark_missing ACCESS_KEY_ID
  [[ -n "$SECRET_ACCESS_KEY" ]] || mark_missing SECRET_ACCESS_KEY
  [[ -n "$S3_ENDPOINT_URL" ]] || mark_missing S3_ENDPOINT_URL
  [[ -n "$S3_ROOT" ]] || mark_missing S3_ROOT
  if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/rclone/${REMOTE_NAME}-mount.log"
  fi
}

same_file() {
  local a b
  a="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  b="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
  [[ "$a" == "$b" ]]
}

find_env_file() {
  local config_env="$1" candidate
  candidate="${SCRIPT_DIR}/.env"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [[ -f "${PWD}/.env" ]]; then
    if [[ ! -f "$candidate" ]] || ! same_file "${PWD}/.env" "$candidate"; then
      printf '%s\n' "${PWD}/.env"
      return 0
    fi
  fi
  if [[ -f "$config_env" ]]; then
    printf '%s\n' "$config_env"
    return 0
  fi
  return 1
}

place_env_beside_script() {
  local src="$1" dest="${SCRIPT_DIR}/.env"
  if same_file "$src" "$dest"; then
    chmod 600 "$dest" 2>/dev/null || true
    ENV_FILE="$dest"
    return 0
  fi
  cp "$src" "$dest"
  chmod 600 "$dest"
  ENV_FILE="$dest"
  printf 'Copied %s to %s.\n' "$src" "$dest"
}

prompt_one() {
  local name="$1" prompt="$2" secret="$3" attempt value err
  for attempt in 1 2 3; do
    printf '%s' "${prompt}: " >/dev/tty
    if [[ "$secret" == 1 ]]; then
      read -r -s value </dev/tty || die "Could not read ${name}."
      printf '\n' >/dev/tty
    else
      read -r value </dev/tty || die "Could not read ${name}."
    fi
    value="$(trim "$value")"
    case "$name" in
      ACCESS_KEY_ID|SECRET_ACCESS_KEY) err="$(credential_error "$value")" ;;
      S3_ENDPOINT_URL) err="$(endpoint_error "$value")" ;;
      S3_ROOT)
        value="$(trim_slashes "$value")"
        err="$(root_error "$value")"
        ;;
      *) err="is not a known setting." ;;
    esac
    if [[ -z "$err" ]]; then
      case "$name" in
        S3_ENDPOINT_URL) value="$(trim_slashes "$value")" ;;
      esac
      printf -v "$name" '%s' "$value"
      PROMPTED+=("$name")
      return 0
    fi
    warn "${name} ${err}"
  done
  die "Could not read a valid ${name}."
}

fill_missing() {
  local name config_env
  if ((${#MISSING_REQUIRED[@]} == 0)); then
    return 0
  fi
  if [[ ! -r /dev/tty ]]; then
    config_env="${XDG_CONFIG_HOME:-$HOME/.config}/s3/.env"
    warn "Set these in ${ENV_FILE}: ${MISSING_REQUIRED[*]}"
    warn "Looked for .env next to the script, in the current directory, and in ${config_env}."
    die "Copy .env.example to .env and fill it in."
  fi
  for name in "${MISSING_REQUIRED[@]}"; do
    case "$name" in
      ACCESS_KEY_ID) prompt_one ACCESS_KEY_ID "Access Key" 0 ;;
      SECRET_ACCESS_KEY) prompt_one SECRET_ACCESS_KEY "Secret Key" 1 ;;
      S3_ENDPOINT_URL) prompt_one S3_ENDPOINT_URL "RustFS endpoint (https://...)" 0 ;;
      S3_ROOT) prompt_one S3_ROOT "Mount folder (absolute path)" 0 ;;
    esac
  done
}

write_prompted_env() {
  local name dest="$ENV_FILE"
  if ((${#PROMPTED[@]} == 0)); then
    return 0
  fi
  (
    umask 077
    if [[ ! -f "$dest" ]]; then
      printf '%s\n' "# Local credentials for the S3 drive." >"$dest"
    fi
    for name in "${PROMPTED[@]}"; do
      printf '%s=' "$name" >>"$dest"
      case "$name" in
        ACCESS_KEY_ID) printf '%s\n' "$ACCESS_KEY_ID" >>"$dest" ;;
        SECRET_ACCESS_KEY) printf '%s\n' "$SECRET_ACCESS_KEY" >>"$dest" ;;
        S3_ENDPOINT_URL) printf '%s\n' "$S3_ENDPOINT_URL" >>"$dest" ;;
        S3_ROOT) printf '%s\n' "$S3_ROOT" >>"$dest" ;;
      esac
    done
  )
  chmod 600 "$dest"
}

require_sudo() {
  command -v sudo >/dev/null 2>&1 || die "sudo is required to ${1}."
}

install_packages() {
  local -a missing=()
  command -v fusermount3 >/dev/null 2>&1 || missing+=(fuse3)
  command -v unzip >/dev/null 2>&1 || missing+=(unzip)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v mountpoint >/dev/null 2>&1 || missing+=(util-linux)
  command -v timeout >/dev/null 2>&1 || missing+=(coreutils)
  if ((${#missing[@]} == 0)); then
    echo "Required packages are already installed."
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 || die "Install these packages, then re-run: ${missing[*]}"
  require_sudo "install packages (${missing[*]})"
  echo "Installing: ${missing[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

rclone_is_current() {
  local bin="$1" line major minor
  [[ -x "$bin" ]] || return 1
  line="$("$bin" version 2>/dev/null | head -n 1 || true)"
  [[ "$line" =~ v([0-9]+)\.([0-9]+) ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  (( major > 1 || (major == 1 && minor >= 67) ))
}

install_rclone() {
  local existing local_bin arch zip_arch url tmp unpacked
  local_bin="${HOME}/.local/bin/rclone"
  if command -v rclone >/dev/null 2>&1; then
    existing="$(command -v rclone)"
    if rclone_is_current "$existing"; then
      RCLONE="$existing"
      echo "rclone is already current (${RCLONE})."
      return 0
    fi
  fi
  if rclone_is_current "$local_bin"; then
    RCLONE="$local_bin"
    echo "Using ${RCLONE}."
    return 0
  fi

  case "$(uname -m)" in
    x86_64) zip_arch="amd64" ;;
    aarch64|arm64) zip_arch="arm64" ;;
    armv7l) zip_arch="arm-v7" ;;
    *) die "Install rclone 1.67 or newer. This architecture is unsupported: $(uname -m)" ;;
  esac

  echo "Installing rclone into ${HOME}/.local/bin."
  tmp="$(mktemp -d)"
  TMP_DIRS+=("$tmp")
  url="https://downloads.rclone.org/rclone-current-linux-${zip_arch}.zip"
  curl -fsSL "$url" -o "${tmp}/rclone.zip" || die "Could not download rclone."
  unzip -q "${tmp}/rclone.zip" -d "$tmp" || die "The rclone download could not be unpacked."
  unpacked="$(find "$tmp" -type f -name rclone -print -quit)"
  [[ -n "$unpacked" ]] || die "The rclone download did not contain the rclone program."
  mkdir -p "${HOME}/.local/bin"
  install -m 755 "$unpacked" "$local_bin"
  rclone_is_current "$local_bin" || die "The installed rclone is older than 1.67."
  RCLONE="$local_bin"
  echo "Installed ${RCLONE}."
}

enable_user_allow_other() {
  if [[ -f /etc/fuse.conf ]] && grep -qE '^[[:space:]]*user_allow_other[[:space:]]*$' /etc/fuse.conf; then
    echo "user_allow_other is already enabled."
    return 0
  fi
  require_sudo "enable user_allow_other in /etc/fuse.conf"
  if [[ -f /etc/fuse.conf ]] && grep -qE '^[[:space:]]*#[[:space:]]*user_allow_other[[:space:]]*$' /etc/fuse.conf; then
    sudo sed -i -E 's/^[[:space:]]*#[[:space:]]*user_allow_other[[:space:]]*$/user_allow_other/' /etc/fuse.conf
  else
    echo "user_allow_other" | sudo tee -a /etc/fuse.conf >/dev/null
  fi
  echo "Enabled user_allow_other in /etc/fuse.conf."
}

ensure_fuse_group() {
  local members
  if ! getent group fuse >/dev/null; then
    echo "No fuse group on this system. User mounts use /dev/fuse directly."
    return 0
  fi
  members=",$(getent group fuse | awk -F: '{print $4}'),"
  if [[ "$members" == *",${USER},"* ]]; then
    echo "${USER} is already in the fuse group."
    return 0
  fi
  require_sudo "add ${USER} to the fuse group"
  sudo usermod -aG fuse "$USER"
  echo "Added ${USER} to the fuse group."
  if ! id -nG | tr ' ' '\n' | grep -qx fuse; then
    echo "This session does not have the fuse group yet. Log out and back in if the mount is denied."
  fi
}

redact_file() {
  local file="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "${SECRET_ACCESS_KEY:-}" && "$line" == *"$SECRET_ACCESS_KEY"* ]]; then
      echo "[redacted]"
      continue
    fi
    if [[ -n "${ACCESS_KEY_ID:-}" && "$line" == *"$ACCESS_KEY_ID"* ]]; then
      echo "[redacted]"
      continue
    fi
    if [[ "$line" == *secret_access_key* || "$line" == *access_key_id* ]]; then
      echo "[redacted]"
      continue
    fi
    printf '%s\n' "$line"
  done < "$file"
}

configure_remote() {
  # nginx in front of RustFS rewrites headers that rclone signs by default.
  # Accept-Encoding, x-id, and HTTP/2 then come back as SignatureDoesNotMatch.
  # Pass the secret as plain text. Pre-obscuring it makes ListBuckets fail.
  local -a args=(
    provider Other
    endpoint "$S3_ENDPOINT_URL"
    access_key_id "$ACCESS_KEY_ID"
    secret_access_key "$SECRET_ACCESS_KEY"
    region "$REGION"
    force_path_style true
    no_check_bucket true
    sign_accept_encoding false
    use_x_id false
    disable_http2 true
    # S3 has no folders. This uploads a zero-byte object ending in /
    # when a directory is created, so other machines can see it.
    directory_markers true
  )
  local remotes output
  remotes="$("$RCLONE" listremotes 2>/dev/null || true)"
  output="$(mktemp)"
  TMP_FILES+=("$output")
  if printf '%s\n' "$remotes" | grep -Fxq "${REMOTE_NAME}:"; then
    echo "Replacing rclone remote ${REMOTE_NAME}."
    if ! "$RCLONE" --auto-confirm config delete "$REMOTE_NAME" >"$output" 2>&1; then
      warn "Could not replace the existing ${REMOTE_NAME} remote."
      redact_file "$output" >&2 || true
      exit 1
    fi
  else
    echo "Creating rclone remote ${REMOTE_NAME}."
  fi
  if ! "$RCLONE" config create "$REMOTE_NAME" s3 "${args[@]}" >"$output" 2>&1; then
    warn "Failed to create rclone remote ${REMOTE_NAME}."
    redact_file "$output" >&2 || true
    exit 1
  fi
  : >"$output"
  local config_file="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"
  if [[ -f "$config_file" ]]; then
    chmod 600 "$config_file"
  fi
}

test_connection() {
  local output rc=0
  output="$(mktemp)"
  TMP_FILES+=("$output")
  echo "Checking ${REMOTE_NAME}: at ${S3_ENDPOINT_URL}."
  timeout 30 "$RCLONE" lsd "${REMOTE_NAME}:" --max-depth 1 >"$output" 2>&1 || rc=$?
  if ((rc != 0)); then
    warn "Could not list the S3 remote."
    redact_file "$output" >&2 || true
    die "Check ${ENV_FILE}."
  fi
  if [[ ! -s "$output" ]]; then
    echo "This access key cannot list any buckets."
  else
    echo "This access key can list:"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="$(trim "$line")"
      [[ -z "$line" ]] && continue
      printf '  %s\n' "$line"
    done < "$output"
  fi
  echo "Open and save rights come from this key's server policy."
}

ensure_mount_point() {
  if mountpoint -q "$S3_ROOT" 2>/dev/null; then
    return 0
  fi
  if [[ -d "$S3_ROOT" && -w "$S3_ROOT" ]]; then
    return 0
  fi
  if [[ ! -e "$S3_ROOT" ]] && mkdir -p "$S3_ROOT" 2>/dev/null; then
    return 0
  fi
  require_sudo "create ${S3_ROOT}"
  sudo mkdir -p "$S3_ROOT"
  sudo chown "$USER:$(id -gn)" "$S3_ROOT"
}

stop_existing_mount() {
  local i
  mountpoint -q "$S3_ROOT" 2>/dev/null || return 0
  echo "Stopping the mount at ${S3_ROOT} so the new access key is loaded."
  fusermount3 -u "$S3_ROOT" 2>/dev/null || true
  mountpoint -q "$S3_ROOT" 2>/dev/null || return 0
  fusermount3 -uz "$S3_ROOT" 2>/dev/null || true
  for i in 1 2 3 4 5; do
    mountpoint -q "$S3_ROOT" 2>/dev/null || return 0
    sleep 0.2
  done
  require_sudo "unmount ${S3_ROOT}"
  sudo umount -l "$S3_ROOT" || die "Could not unmount ${S3_ROOT}."
  for i in 1 2 3 4 5; do
    mountpoint -q "$S3_ROOT" 2>/dev/null || return 0
    sleep 0.2
  done
  die "Could not unmount ${S3_ROOT}."
}

refuse_nonempty_mount_point() {
  mountpoint -q "$S3_ROOT" 2>/dev/null && die "${S3_ROOT} is still mounted."
  if [[ -n "$(find "$S3_ROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]]; then
    die "${S3_ROOT} is not empty. Move those files aside, then re-run."
  fi
}

mount_remote() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "Mounting ${REMOTE_NAME}: at ${S3_ROOT}."
  if ! "$RCLONE" mount "${REMOTE_NAME}:" "$S3_ROOT" \
    --links \
    --s3-directory-markers \
    --vfs-cache-mode full \
    --vfs-cache-max-age 1h \
    --vfs-write-back 0s \
    --dir-cache-time 30s \
    --buffer-size 64M \
    --transfers 8 \
    --checkers 8 \
    --volname "$VOLUME_NAME" \
    --allow-other \
    --log-file "$LOG_FILE" \
    --log-level INFO \
    --daemon-wait 30s \
    --daemon; then
    warn "Mount failed. Recent log (${LOG_FILE}):"
    tail -n 40 "$LOG_FILE" >&2 || true
    exit 1
  fi
  if ! mountpoint -q "$S3_ROOT"; then
    warn "rclone exited cleanly, but ${S3_ROOT} is not a mount. Recent log:"
    tail -n 40 "$LOG_FILE" >&2 || true
    exit 1
  fi
  echo "Mounted ${REMOTE_NAME}: at ${S3_ROOT}."
  echo "Log: ${LOG_FILE}"
  echo "After a restart, run this installer again to mount the folder."
  printf 'Stop the mount with: fusermount3 -u %q\n' "$S3_ROOT"
}

# Ask only after the mount is up. Enter skips. y installs the hourly job and runs it once.
offer_ensure_dirs() {
  local answer dest tmp prompt
  echo
  if [[ -x /etc/cron.hourly/s3-ensure-dirs ]]; then
    echo "s3-ensure-dirs is already installed. It creates the standard site folders and runs every hour."
    prompt="Would you like to update and start s3-ensure-dirs? [y/N] "
  else
    echo "s3-ensure-dirs creates the standard folders inside each existing customer site and runs every hour."
    prompt="Would you like to install and start s3-ensure-dirs? [y/N] "
  fi
  if [[ ! -r /dev/tty ]]; then
    echo "To install it later, run:"
    printf '  curl -fsSL %s/s3-ensure-dirs | bash\n' "$S3_RAW_BASE"
    return 0
  fi
  printf '%s' "$prompt" >/dev/tty
  if ! read -r answer </dev/tty; then
    echo "Skipped s3-ensure-dirs."
    return 0
  fi
  answer="$(trim "$answer")"
  case "${answer,,}" in
    y|yes) ;;
    *)
      echo "Skipped s3-ensure-dirs."
      return 0
      ;;
  esac

  dest="${SCRIPT_DIR}/s3-ensure-dirs"
  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  echo "Downloading s3-ensure-dirs..."
  if ! curl -fsSL "${S3_RAW_BASE}/s3-ensure-dirs" -o "$tmp"; then
    warn "Could not download s3-ensure-dirs. The drive is mounted."
    printf 'Run it later with: curl -fsSL %s/s3-ensure-dirs | bash\n' "$S3_RAW_BASE" >&2
    return 0
  fi
  if ! grep -q 's3-ensure-dirs' "$tmp"; then
    warn "The download was not s3-ensure-dirs. The drive is mounted."
    return 0
  fi
  mv "$tmp" "$dest"
  chmod 755 "$dest"
  # The child reads this value before it looks in .env.
  export S3_ROOT
  if ! bash "$dest"; then
    warn "s3-ensure-dirs did not finish. The drive is mounted."
    printf 'Run it later with: curl -fsSL %s/s3-ensure-dirs | bash\n' "$S3_RAW_BASE" >&2
  fi
}

bootstrap_and_exec() {
  local dest tmp example
  [[ "$(id -u)" -eq 0 ]] && die "Run this as your regular user. It uses sudo only for system changes."
  dest="${XDG_DATA_HOME:-$HOME/.local/share}/s3"
  mkdir -p "$dest"
  tmp="$(mktemp)"
  TMP_FILES+=("$tmp" "${tmp}.err")
  if ! curl -fsSL "${S3_RAW_BASE}/install.sh" -o "$tmp" 2>"${tmp}.err"; then
    if [[ -s "${tmp}.err" ]]; then
      warn "$(head -n 1 "${tmp}.err")"
    fi
    die "Could not download the S3 drive installer from ${S3_RAW_BASE}/install.sh."
  fi
  if ! head -n 12 "$tmp" | grep -qi 's3 drive'; then
    die "The download was not the S3 drive installer."
  fi
  mv "$tmp" "${dest}/install.sh"
  chmod 755 "${dest}/install.sh"
  example="$(mktemp)"
  TMP_FILES+=("$example")
  if curl -fsSL "${S3_RAW_BASE}/.env.example" -o "$example" 2>/dev/null; then
    if head -n 20 "$example" | grep -q 'ACCESS_KEY_ID'; then
      mv "$example" "${dest}/.env.example"
      chmod 644 "${dest}/.env.example"
    fi
  fi
  rm -f "$example" "${tmp}.err"
  exec bash "${dest}/install.sh" "$@"
  die "Could not start the saved installer."
}

load_settings() {
  local found config_env warning
  config_env="${XDG_CONFIG_HOME:-$HOME/.config}/s3/.env"
  if found="$(find_env_file "$config_env")"; then
    place_env_beside_script "$found"
    parse_env_file "$ENV_FILE"
  else
    reset_settings
    ENV_FILE="${SCRIPT_DIR}/.env"
    LOG_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/rclone/${REMOTE_NAME}-mount.log"
    MISSING_REQUIRED=(ACCESS_KEY_ID SECRET_ACCESS_KEY S3_ENDPOINT_URL S3_ROOT)
  fi
  for warning in "${SETTINGS_WARNINGS[@]+"${SETTINGS_WARNINGS[@]}"}"; do
    warn ".env: ${warning}"
  done
  fill_missing
  write_prompted_env
}

main() {
  [[ "$(id -u)" -eq 0 ]] && die "Run this as your regular user. It uses sudo only for system changes."
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  load_settings
  echo "=== S3 drive install (${S3_ROOT}) ==="
  echo "Endpoint: ${S3_ENDPOINT_URL}"
  echo "Settings: ${ENV_FILE}"
  echo
  echo "[1/5] Installing packages..."
  install_packages
  install_rclone
  echo
  echo "[2/5] Enabling FUSE user mounts..."
  enable_user_allow_other
  ensure_fuse_group
  echo
  echo "[3/5] Configuring rclone remote ${REMOTE_NAME}..."
  configure_remote
  echo
  echo "[4/5] Testing connection..."
  test_connection
  unset ACCESS_KEY_ID SECRET_ACCESS_KEY
  echo
  echo "[5/5] Mounting..."
  ensure_mount_point
  stop_existing_mount
  refuse_nonempty_mount_point
  mount_remote
  offer_ensure_dirs
}

if ! is_saved_script; then
  bootstrap_and_exec "$@"
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
