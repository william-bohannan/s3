#!/usr/bin/env bash
# Remove the S3 drive from Ubuntu.
# Stops the mount, deletes the rclone remote, and clears the saved installer,
# credentials, file cache, log, and hourly folder job.
# fuse3, /etc/fuse.conf, the fuse group, and a packaged rclone stay.
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/william-bohannan/s3/main/uninstall.sh | bash

set -euo pipefail

SOURCE_PATH="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
DATA_DIR=""
CONFIG_DIR=""
CACHE_DIR=""
RCLONE=""
SAW=0
FAILED=0
INTEREST=0

ROOTS=()
REMOTES=()
LOGS=()
LEFT_ENV=()

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

contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

mark_seen() {
  SAW=1
}

note_install() {
  INTEREST=1
}

note_failure() {
  FAILED=1
  warn "$*"
}

remote_ok() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]
}

root_ok() {
  local value="$1"
  [[ -n "$value" && "$value" == /* && "$value" != "/" ]] || return 1
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  case "$value" in
    */.|*/..|*/./*|*/../*) return 1 ;;
    /mnt|/media|/home|/root|/usr|/bin|/sbin|/etc|/var|/opt|/tmp|/boot|/dev|/proc|/sys|/run) return 1 ;;
    "$HOME"|"${HOME}/.local"|"${HOME}/.config"|"${HOME}/.cache"|"${HOME}/.local/share"|"${HOME}/.local/bin") return 1 ;;
  esac
  return 0
}

log_ok() {
  local value="$1" leaf
  [[ -n "$value" && "$value" == /* && "$value" != */ ]] || return 1
  [[ "$value" != *$'\n'* ]] || return 1
  leaf="${value##*/}"
  [[ -n "$leaf" && ! "$leaf" =~ [\<\>\"/\\|?*] && "$leaf" != *:* ]] || return 1
  case "$value" in
    /etc/*|/usr/*|/bin/*|/sbin/*|/boot/*|/dev/*|/proc/*|/sys/*) return 1 ;;
  esac
  return 0
}

add_root() {
  local value
  value="$(trim_slashes "$(trim "$1")")"
  [[ -n "$value" ]] || return 0
  if ! root_ok "$value"; then
    warn "Skipping mount folder: ${value}"
    return 0
  fi
  if contains "$value" "${ROOTS[@]}"; then
    return 0
  fi
  ROOTS+=("$value")
}

add_remote() {
  local value
  value="$(trim "$1")"
  [[ -n "$value" ]] || return 0
  if ! remote_ok "$value"; then
    warn "Skipping rclone remote name: ${value}"
    return 0
  fi
  if contains "$value" "${REMOTES[@]}"; then
    return 0
  fi
  REMOTES+=("$value")
}

add_log() {
  local value
  value="$(trim "$1")"
  [[ -n "$value" ]] || return 0
  if ! log_ok "$value"; then
    warn "Skipping log file: ${value}"
    return 0
  fi
  if contains "$value" "${LOGS[@]}"; then
    return 0
  fi
  LOGS+=("$value")
}

strip_quotes() {
  local value="$1"
  if [[ ${#value} -ge 2 ]]; then
    if [[ ( "$value" == \"*\" && "$value" == *\" ) || ( "$value" == \'*\' && "$value" == *\' ) ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi
  printf '%s' "$value"
}

remember_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  case "$file" in
    "${DATA_DIR}/"*|"${CONFIG_DIR}/"*) return 0 ;;
  esac
  if contains "$file" "${LEFT_ENV[@]}"; then
    return 0
  fi
  LEFT_ENV+=("$file")
}

parse_env_file() {
  local file="$1" line key value
  [[ -f "$file" ]] || return 0
  remember_env_file "$file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || continue
    key="$(trim "${line%%=*}")"
    value="$(strip_quotes "$(trim "${line#*=}")")"
    case "$key" in
      S3_ROOT)
        [[ -n "$value" ]] && note_install
        add_root "$value"
        ;;
      REMOTE_NAME)
        [[ -n "$value" ]] && note_install
        add_remote "$value"
        ;;
      LOG_FILE)
        [[ -n "$value" ]] && note_install
        add_log "$value"
        ;;
    esac
  done < "$file"
}

collect_settings() {
  local config_env="${CONFIG_DIR}/.env" defaults="/etc/default/s3-ensure-dirs"
  if is_saved_script; then
    SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
    parse_env_file "${SCRIPT_DIR}/.env"
  fi
  if [[ -f "${PWD}/.env" ]]; then
    parse_env_file "${PWD}/.env"
  fi
  parse_env_file "$config_env"
  parse_env_file "${DATA_DIR}/.env"
  parse_env_file "$defaults"
}

note_known_artifacts() {
  local remote
  if [[ -e "$DATA_DIR" || -e "$CONFIG_DIR" ]]; then
    note_install
  fi
  if [[ -e /etc/cron.hourly/s3-ensure-dirs || -e /etc/default/s3-ensure-dirs ]]; then
    note_install
  fi
  if [[ -f "${CACHE_DIR}/rclone/s3-mount.log" ]]; then
    note_install
  fi
  for remote in "${REMOTES[@]}"; do
    if [[ -f "${CACHE_DIR}/rclone/${remote}-mount.log" ]]; then
      note_install
    fi
  done
}

finalize_names() {
  local remote
  # The built-in remote name is s3. Use it only when this install was found,
  # so an unrelated rclone remote of that name is left alone.
  if [[ ${#REMOTES[@]} -eq 0 && "$INTEREST" -eq 1 ]]; then
    add_remote "s3"
  fi
  for remote in "${REMOTES[@]}"; do
    add_log "${CACHE_DIR}/rclone/${remote}-mount.log"
  done
}

is_mounted() {
  local root="$1" target
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$root"
    return
  fi
  [[ -r /proc/mounts ]] || return 1
  while read -r _ target _; do
    target="${target//\\040/ }"
    [[ "$target" == "$root" ]] && return 0
  done < /proc/mounts
  return 1
}

discover_live_mounts() {
  local args_file part spec name next i arg ours
  local -a args
  [[ -d /proc ]] || return 0
  shopt -s nullglob
  for args_file in /proc/[0-9]*/cmdline; do
    [[ -r "$args_file" ]] || continue
    args=()
    while IFS= read -r -d '' part || [[ -n "${part:-}" ]]; do
      args+=("$part")
    done < "$args_file"
    [[ ${#args[@]} -ge 4 ]] || continue
    [[ "${args[0]##*/}" == "rclone" ]] || continue
    [[ "${args[1]}" == "mount" ]] || continue
    ours=0
    for arg in "${args[@]}"; do
      if [[ "$arg" == "--s3-directory-markers" || "$arg" == "--s3-directory-markers="* ]]; then
        ours=1
        break
      fi
    done
    for ((i = 2; i < ${#args[@]} - 1; i++)); do
      spec="${args[i]}"
      [[ "$spec" == *:* ]] || continue
      name="${spec%%:*}"
      remote_ok "$name" || continue
      next="${args[i + 1]}"
      [[ "$next" == /* ]] || continue
      # A running mount from this installer carries --s3-directory-markers.
      # A configured remote is stopped even when that flag is absent.
      if [[ "$ours" -eq 1 ]] || contains "$name" "${REMOTES[@]}"; then
        [[ "$ours" -eq 1 ]] && note_install
        add_remote "$name"
        add_root "$next"
      fi
      break
    done
  done
  shopt -u nullglob
}

stop_one() {
  local root="$1" i
  if ! is_mounted "$root"; then
    return 0
  fi
  echo "Stopping the mount at ${root}."
  mark_seen
  if command -v fusermount3 >/dev/null 2>&1; then
    fusermount3 -u "$root" 2>/dev/null || true
  elif command -v fusermount >/dev/null 2>&1; then
    fusermount -u "$root" 2>/dev/null || true
  fi
  if is_mounted "$root" && command -v fusermount3 >/dev/null 2>&1; then
    fusermount3 -uz "$root" 2>/dev/null || true
  fi
  for i in 1 2 3 4 5; do
    is_mounted "$root" || return 0
    sleep 0.2
  done
  if command -v sudo >/dev/null 2>&1; then
    sudo umount -l "$root" || true
  fi
  for i in 1 2 3 4 5; do
    is_mounted "$root" || return 0
    sleep 0.2
  done
  note_failure "Could not unmount ${root}."
  return 1
}

stop_mounts() {
  local root
  [[ ${#ROOTS[@]} -eq 0 ]] && return 0
  for root in "${ROOTS[@]}"; do
    stop_one "$root" || true
  done
}

find_rclone() {
  local candidate
  if command -v rclone >/dev/null 2>&1; then
    RCLONE="$(command -v rclone)"
    return 0
  fi
  candidate="${HOME}/.local/bin/rclone"
  if [[ -x "$candidate" ]]; then
    RCLONE="$candidate"
    return 0
  fi
  return 1
}

strip_config_sections() {
  local file="$1" tmp line section drop removed
  [[ -f "$file" && ! -L "$file" ]] || return 0
  [[ ${#REMOTES[@]} -gt 0 ]] || return 0
  tmp="$(mktemp)"
  drop=0
  removed=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[([A-Za-z0-9][A-Za-z0-9_-]{0,31})\][[:space:]]*$ ]]; then
      section="${BASH_REMATCH[1]}"
      if contains "$section" "${REMOTES[@]}"; then
        drop=1
        removed=1
        echo "Removing rclone remote ${section}."
      else
        drop=0
      fi
    fi
    if [[ "$drop" -eq 0 ]]; then
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  if [[ "$removed" -eq 0 ]]; then
    rm -f -- "$tmp"
    return 0
  fi
  mark_seen
  if grep -qE '^\[[^]]+\]' "$tmp"; then
    mv -- "$tmp" "$file"
    chmod 600 -- "$file" || true
  else
    rm -f -- "$tmp" "$file"
    echo "Removed ${file}."
    rmdir -- "$(dirname -- "$file")" 2>/dev/null || true
  fi
}

delete_remotes() {
  local remote listed config_file
  [[ ${#REMOTES[@]} -gt 0 ]] || return 0
  config_file="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"
  if [[ -z "$RCLONE" ]]; then
    strip_config_sections "$config_file"
    return 0
  fi
  if ! listed="$("$RCLONE" listremotes 2>/dev/null)"; then
    note_failure "Could not list rclone remotes."
    return 0
  fi
  for remote in "${REMOTES[@]}"; do
    printf '%s\n' "$listed" | grep -Fxq "${remote}:" || continue
    echo "Removing rclone remote ${remote}."
    if ! "$RCLONE" --auto-confirm config delete "$remote" >/dev/null 2>&1; then
      note_failure "Could not delete rclone remote ${remote}."
      continue
    fi
    mark_seen
  done
}

remove_cache() {
  local remote path parent base
  for remote in "${REMOTES[@]}"; do
    for path in "${CACHE_DIR}/rclone/vfs/${remote}" "${CACHE_DIR}/rclone/vfsMeta/${remote}"; do
      [[ -e "$path" || -L "$path" ]] || continue
      if [[ -L "$path" ]]; then
        rm -f -- "$path"
        echo "Removed ${path}."
        mark_seen
        continue
      fi
      base="$(basename -- "$path")"
      parent="$(basename -- "$(dirname -- "$path")")"
      [[ "$base" == "$remote" ]] || continue
      [[ "$parent" == "vfs" || "$parent" == "vfsMeta" ]] || continue
      rm -rf -- "$path"
      echo "Removed ${path}."
      mark_seen
    done
  done
  rmdir "${CACHE_DIR}/rclone/vfs" "${CACHE_DIR}/rclone/vfsMeta" "${CACHE_DIR}/rclone" 2>/dev/null || true
}

remove_logs() {
  local log
  [[ ${#LOGS[@]} -eq 0 ]] && return 0
  for log in "${LOGS[@]}"; do
    [[ -f "$log" && ! -L "$log" ]] || continue
    rm -f -- "$log"
    echo "Removed ${log}."
    mark_seen
  done
}

remove_as_root() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  if rm -f -- "$path" 2>/dev/null; then
    echo "Removed ${path}."
    mark_seen
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    note_failure "Could not remove ${path}. sudo is required."
    return 0
  fi
  if sudo rm -f -- "$path"; then
    echo "Removed ${path}."
    mark_seen
    return 0
  fi
  note_failure "Could not remove ${path}."
}

remove_cron() {
  remove_as_root /etc/cron.hourly/s3-ensure-dirs
  remove_as_root /etc/default/s3-ensure-dirs
}

remove_empty_mounts() {
  local root
  [[ ${#ROOTS[@]} -eq 0 ]] && return 0
  for root in "${ROOTS[@]}"; do
    [[ -d "$root" && ! -L "$root" ]] || continue
    is_mounted "$root" && continue
    if rmdir -- "$root" 2>/dev/null; then
      echo "Removed empty mount folder ${root}."
      mark_seen
      continue
    fi
    if [[ -n "$(find "$root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]]; then
      echo "Left ${root} because it is not empty."
      continue
    fi
    if command -v sudo >/dev/null 2>&1 && sudo rmdir -- "$root" 2>/dev/null; then
      echo "Removed empty mount folder ${root}."
      mark_seen
      continue
    fi
    echo "Left ${root}."
  done
}

remove_owned_tree() {
  local path="$1" parent
  [[ -e "$path" || -L "$path" ]] || return 0
  [[ "$(basename -- "$path")" == "s3" ]] || {
    note_failure "Refusing to remove ${path}."
    return 0
  }
  parent="$(dirname -- "$path")"
  case "$parent" in
    *.local/share|*.config) ;;
    *)
      note_failure "Refusing to remove ${path}."
      return 0
      ;;
  esac
  parent="$(cd "$parent" && pwd)" || {
    note_failure "Refusing to remove ${path}."
    return 0
  }
  case "$parent" in
    */.local/share|*/.config) ;;
    *)
      note_failure "Refusing to remove ${path}."
      return 0
      ;;
  esac
  if [[ -L "${parent}/s3" ]]; then
    rm -f -- "${parent}/s3"
  else
    rm -rf -- "${parent}/s3"
  fi
  echo "Removed ${parent}/s3."
  mark_seen
}

remove_user_files() {
  remove_owned_tree "$DATA_DIR"
  remove_owned_tree "$CONFIG_DIR"
}

remove_local_rclone() {
  local bin="${HOME}/.local/bin/rclone" config_file remotes
  # Only drop the user-installed binary after this install was found and
  # no other rclone remotes are left.
  [[ "$SAW" -eq 1 && -n "$RCLONE" ]] || return 0
  if ! remotes="$("$RCLONE" listremotes 2>/dev/null)"; then
    echo "Left rclone. Its remote list could not be read."
    return 0
  fi
  if [[ -n "$(printf '%s' "$remotes" | tr -d '[:space:]')" ]]; then
    echo "Left rclone. Other remotes are still configured."
    return 0
  fi
  config_file="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"
  if [[ -f "$config_file" && ! -L "$config_file" ]] && ! grep -qE '^\[[^]]+\]' "$config_file"; then
    rm -f -- "$config_file"
    echo "Removed ${config_file}."
    mark_seen
    rmdir -- "$(dirname -- "$config_file")" 2>/dev/null || true
  fi
  if [[ -x "$bin" && ! -L "$bin" ]]; then
    rm -f -- "$bin"
    echo "Removed ${bin}."
    mark_seen
  fi
  if [[ "$RCLONE" != "$bin" ]]; then
    echo "Left rclone at ${RCLONE}."
  fi
}

report() {
  local file
  echo
  if [[ "$FAILED" -ne 0 ]]; then
    warn "The S3 drive was not fully removed."
  elif [[ "$SAW" -eq 0 ]]; then
    echo "No S3 drive install was found for this user."
  else
    echo "S3 drive has been removed for this Ubuntu user."
  fi
  if [[ "$FAILED" -ne 0 || "$SAW" -ne 0 ]]; then
    echo "fuse3, /etc/fuse.conf, and the fuse group were left in place."
  fi
  if [[ ${#LEFT_ENV[@]} -gt 0 ]]; then
    for file in "${LEFT_ENV[@]}"; do
      echo "Left ${file}."
    done
  fi
}

main() {
  [[ "$(id -u)" -eq 0 ]] && die "Run this as your regular user. It uses sudo only for system files."
  DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/s3"
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/s3"
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
  collect_settings
  discover_live_mounts
  note_known_artifacts
  finalize_names
  find_rclone || true
  stop_mounts
  if [[ "$FAILED" -ne 0 ]]; then
    report
    exit 1
  fi
  delete_remotes
  remove_cache
  remove_logs
  remove_cron
  remove_empty_mounts
  remove_user_files
  remove_local_rclone
  report
  [[ "$FAILED" -eq 0 ]]
}

main "$@"
