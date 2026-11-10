#!/usr/bin/env bash
# Load RustFS policies from policies/*.json into the local RustFS server.
# One-liner, on the machine where RustFS is running:
#   curl -fsSL https://raw.githubusercontent.com/william-bohannan/s3/main/policies.sh | bash
# From a clone:
#   bash policies.sh
# Reads RUSTFS_ADMIN_USER and RUSTFS_ADMIN_PASS from .env.
# Talks to http://127.0.0.1:9000 unless RUSTFS_ENDPOINT is set.
# Installs rc 0.1.36 or newer into ~/.local/bin when the copy on PATH is older.
# Replaces a policy that already has the same name. Does not attach policies,
# does not remove other policies, and does not change the built-in policies.

set -euo pipefail
umask 077

S3_RAW_BASE="https://raw.githubusercontent.com/william-bohannan/s3/main"
RC_RELEASE="https://github.com/rustfs/cli/releases/download/v0.1.36"
RC_VERSION="0.1.36"
ALIAS_NAME="s3-policies"
SOURCE_PATH="${BASH_SOURCE[0]:-}"
TMP_FILES=()
TMP_DIRS=()

RUSTFS_ADMIN_USER=""
RUSTFS_ADMIN_PASS=""
RUSTFS_ENDPOINT=""
ENDPOINT=""
ENV_FILE=""
SCRIPT_DIR=""
POLICY_DIR=""
RC=""
LOADED=0
FAILED=0
POLICY_FILES=()

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

endpoint_error() {
  local value="$1" lower
  if [[ -z "$value" ]]; then
    printf '%s' "is empty."
    return 0
  fi
  if [[ "$value" == *[[:space:]]* || ${#value} -gt 1024 ]]; then
    printf '%s' "must be an http or https URL."
    return 0
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
    return 0
  fi
  if [[ "$value" == *[[:space:]]* ]]; then
    printf '%s' "cannot contain spaces."
    return 0
  fi
  if ((${#value} > 1024)); then
    printf '%s' "is too long."
  fi
}

redact_file() {
  local file="$1"
  RUSTFS_ADMIN_PASS="$RUSTFS_ADMIN_PASS" awk '
    BEGIN {
      secret = ENVIRON["RUSTFS_ADMIN_PASS"]
      n = length(secret)
    }
    {
      line = $0
      if (n == 0) {
        print line
        next
      }
      out = ""
      while (1) {
        i = index(line, secret)
        if (i == 0) {
          print out line
          break
        }
        out = out substr(line, 1, i - 1) "[redacted]"
        line = substr(line, i + n)
      }
    }
  ' "$file"
}

parse_env_file() {
  local file="$1" line key value err
  RUSTFS_ADMIN_USER=""
  RUSTFS_ADMIN_PASS=""
  RUSTFS_ENDPOINT=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      warn "Skipping a malformed line in ${file}."
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
      RUSTFS_ADMIN_USER|RUSTFS_ADMIN_PASS)
        err="$(credential_error "$value")"
        if [[ -n "$err" ]]; then
          if [[ "$err" != "is empty." ]]; then
            warn "${key} ${err}"
          fi
          if [[ "$key" == RUSTFS_ADMIN_USER ]]; then
            RUSTFS_ADMIN_USER=""
          else
            RUSTFS_ADMIN_PASS=""
          fi
        elif [[ "$key" == RUSTFS_ADMIN_USER ]]; then
          RUSTFS_ADMIN_USER="$value"
        else
          RUSTFS_ADMIN_PASS="$value"
        fi
        ;;
      RUSTFS_ENDPOINT)
        if [[ -z "$value" ]]; then
          RUSTFS_ENDPOINT=""
        else
          err="$(endpoint_error "$value")"
          if [[ -n "$err" ]]; then
            die "RUSTFS_ENDPOINT ${err}"
          fi
          RUSTFS_ENDPOINT="$(trim_slashes "$value")"
        fi
        ;;
    esac
  done < "$file"
  return 0
}

find_env_file() {
  local candidate config_env data_env
  candidate="${SCRIPT_DIR}/.env"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [[ -f "${PWD}/.env" ]]; then
    printf '%s\n' "${PWD}/.env"
    return 0
  fi
  config_env="${XDG_CONFIG_HOME:-$HOME/.config}/s3/.env"
  if [[ -f "$config_env" ]]; then
    printf '%s\n' "$config_env"
    return 0
  fi
  data_env="${XDG_DATA_HOME:-$HOME/.local/share}/s3/.env"
  if [[ -f "$data_env" ]]; then
    printf '%s\n' "$data_env"
    return 0
  fi
  return 1
}

load_admin_env() {
  local -a missing=()
  if ! ENV_FILE="$(find_env_file)"; then
    die "Copy .env.example to .env and set RUSTFS_ADMIN_USER and RUSTFS_ADMIN_PASS."
  fi
  parse_env_file "$ENV_FILE"
  [[ -n "$RUSTFS_ADMIN_USER" ]] || missing+=(RUSTFS_ADMIN_USER)
  [[ -n "$RUSTFS_ADMIN_PASS" ]] || missing+=(RUSTFS_ADMIN_PASS)
  if ((${#missing[@]})); then
    die "Set ${missing[*]} in ${ENV_FILE}."
  fi
  if [[ -n "$RUSTFS_ENDPOINT" ]]; then
    ENDPOINT="$RUSTFS_ENDPOINT"
  else
    ENDPOINT="http://127.0.0.1:9000"
  fi
}

rc_version_ok() {
  local line="$1" major minor patch
  [[ "$line" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  if ((major > 0)); then
    return 0
  fi
  if ((minor > 1)); then
    return 0
  fi
  if ((minor == 1 && patch >= 36)); then
    return 0
  fi
  return 1
}

rc_is_current() {
  local bin="$1" line
  [[ -n "$bin" && -x "$bin" ]] || return 1
  line="$("$bin" --version 2>/dev/null | head -n 1 || true)"
  rc_version_ok "$line"
}

install_rc() {
  local arch url tmp archive checksum hash actual unpacked local_bin
  command -v curl >/dev/null 2>&1 || die "curl is required to install rc."
  command -v tar >/dev/null 2>&1 || die "tar is required to install rc."
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required to install rc."
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Install rc ${RC_VERSION} or newer. This architecture is unsupported: $(uname -m)." ;;
  esac
  local_bin="${HOME}/.local/bin/rc"
  url="${RC_RELEASE}/rustfs-cli-linux-${arch}-v${RC_VERSION}.tar.gz"
  echo "Installing rc ${RC_VERSION} into ${HOME}/.local/bin."
  tmp="$(mktemp -d)"
  TMP_DIRS+=("$tmp")
  archive="${tmp}/rc.tar.gz"
  checksum="${tmp}/rc.tar.gz.sha256"
  curl -fsSL "$url" -o "$archive" || die "Could not download rc."
  curl -fsSL "${url}.sha256" -o "$checksum" || die "Could not download the rc checksum."
  hash="$(awk 'NR == 1 { print $1 }' "$checksum")"
  [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]] || die "The rc checksum was not a SHA-256 hash."
  actual="$(sha256sum "$archive" | awk '{ print $1 }')"
  [[ "${actual,,}" == "${hash,,}" ]] || die "The rc download did not match its checksum."
  tar -xzf "$archive" -C "$tmp" || die "The rc download could not be unpacked."
  unpacked="$(find "$tmp" -type f -name rc -print -quit)"
  [[ -n "$unpacked" ]] || die "The rc download did not contain the rc program."
  mkdir -p "${HOME}/.local/bin"
  install -m 755 "$unpacked" "${local_bin}.new"
  mv -f "${local_bin}.new" "$local_bin"
  rc_is_current "$local_bin" || die "The installed rc is older than ${RC_VERSION}."
  RC="$local_bin"
  echo "Installed ${RC}."
}

ensure_rc() {
  local existing local_bin
  local_bin="${HOME}/.local/bin/rc"
  if command -v rc >/dev/null 2>&1; then
    existing="$(command -v rc)"
    if rc_is_current "$existing"; then
      RC="$existing"
      echo "rc is already current (${RC})."
      return 0
    fi
  fi
  if rc_is_current "$local_bin"; then
    RC="$local_bin"
    echo "Using ${RC}."
    return 0
  fi
  install_rc
}

lock_rc_config() {
  local config_dir config_file
  config_dir="${RC_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/rc}"
  config_file="${config_dir}/config.toml"
  [[ -f "$config_file" ]] || die "rc did not store the admin alias."
  chmod 700 "$config_dir" || die "Could not limit access to ${config_dir}."
  chmod 600 "$config_file" || die "Could not limit access to the rc config."
}

configure_alias() {
  local out
  out="$(mktemp)"
  TMP_FILES+=("$out")
  if ! "$RC" alias set -- "$ALIAS_NAME" "$ENDPOINT" "$RUSTFS_ADMIN_USER" "$RUSTFS_ADMIN_PASS" >"$out" 2>&1; then
    warn "Could not save the admin alias."
    redact_file "$out" >&2 || true
    exit 1
  fi
  lock_rc_config
  out="$(mktemp)"
  TMP_FILES+=("$out")
  if ! "$RC" admin policy ls -- "$ALIAS_NAME" >"$out" 2>&1; then
    warn "Could not reach RustFS at ${ENDPOINT}."
    redact_file "$out" >&2 || true
    exit 1
  fi
  echo "Alias ${ALIAS_NAME} is ready."
}

list_policy_files() {
  local f
  POLICY_FILES=()
  shopt -s nullglob
  for f in "${POLICY_DIR}"/*.json; do
    if [[ -f "$f" ]]; then
      POLICY_FILES+=("$f")
    fi
  done
  shopt -u nullglob
  if ((${#POLICY_FILES[@]} == 0)); then
    die "No policy files in ${POLICY_DIR}."
  fi
  mapfile -t POLICY_FILES < <(printf '%s\n' "${POLICY_FILES[@]}" | sort)
  return 0
}

policy_name_ok() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]
}

policy_is_builtin() {
  case "$1" in
    readonly|readwrite|writeonly|diagnostics|consoleAdmin) return 0 ;;
    *) return 1 ;;
  esac
}

policy_document_ok() {
  local file="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    doc = json.load(handle)
if not isinstance(doc, dict):
    raise SystemExit(1)
if doc.get("Version") != "2012-10-17":
    raise SystemExit(1)
statements = doc.get("Statement")
if not isinstance(statements, list) or not statements:
    raise SystemExit(1)
' "$file"
    return
  fi
  if grep -q '"Version"' "$file" && grep -q '2012-10-17' "$file" && grep -q '"Statement"' "$file"; then
    return 0
  fi
  return 1
}

import_one() {
  local file="$1" name out
  name="$(basename -- "$file" .json)"
  if ! policy_name_ok "$name"; then
    warn "Could not load ${name}. The file name is not a policy name."
    return 1
  fi
  if policy_is_builtin "$name"; then
    printf 'Skipping %s. Built-in policies stay as they are.\n' "$name"
    return 2
  fi
  if ! policy_document_ok "$file"; then
    warn "Could not load ${name}. The file is not a policy document."
    return 1
  fi
  out="$(mktemp)"
  TMP_FILES+=("$out")
  if "$RC" admin policy create -- "$ALIAS_NAME" "$name" "$file" >"$out" 2>&1; then
    printf 'Loaded %s.\n' "$name"
    return 0
  fi
  warn "Could not load ${name}."
  redact_file "$out" >&2 || true
  return 1
}

import_policies() {
  local file status
  list_policy_files
  for file in "${POLICY_FILES[@]}"; do
    status=0
    import_one "$file" || status=$?
    if [[ "$status" -eq 0 ]]; then
      LOADED=$((LOADED + 1))
    elif [[ "$status" -ne 2 ]]; then
      FAILED=$((FAILED + 1))
    fi
  done
  if [[ "$LOADED" -eq 0 ]]; then
    die "No policies were loaded."
  fi
  printf 'Loaded %s policies at %s.\n' "$LOADED" "$ENDPOINT"
  if [[ "$FAILED" -ne 0 ]]; then
    warn "${FAILED} policies were not loaded."
  fi
  [[ "$FAILED" -eq 0 ]]
}

policy_names_from_listing() {
  local body="$1" line name
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ \"name\":\ \"([A-Za-z0-9][A-Za-z0-9_-]*\.json)\" ]]; then
      name="${BASH_REMATCH[1]}"
      printf '%s\n' "$name"
    fi
  done < "$body"
  return 0
}

bootstrap_and_exec() {
  local dest tmp body stage name src old
  local -a names=()
  [[ "$(id -u)" -eq 0 ]] && die "Run this as your regular user."
  command -v curl >/dev/null 2>&1 || die "curl is required to download policies.sh."
  dest="${XDG_DATA_HOME:-$HOME/.local/share}/s3"
  mkdir -p "${dest}/policies"
  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  if ! curl -fsSL "${S3_RAW_BASE}/policies.sh" -o "$tmp"; then
    die "Could not download policies.sh."
  fi
  if ! head -n 12 "$tmp" | grep -q 'Load RustFS policies'; then
    die "The download was not policies.sh."
  fi
  body="$(mktemp)"
  TMP_FILES+=("$body")
  if ! curl -fsSL -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/william-bohannan/s3/contents/policies?ref=main" \
    -o "$body"; then
    die "Could not list the policy files. From a clone, run: bash policies.sh"
  fi
  mapfile -t names < <(policy_names_from_listing "$body" | sort -u)
  if ((${#names[@]} == 0)); then
    die "Could not list the policy files. From a clone, run: bash policies.sh"
  fi
  stage="$(mktemp -d)"
  TMP_DIRS+=("$stage")
  for name in "${names[@]}"; do
    src="${stage}/${name}"
    if ! curl -fsSL "${S3_RAW_BASE}/policies/${name}" -o "$src"; then
      die "Could not download policies/${name}."
    fi
    if ! grep -q '"Version"' "$src" || ! grep -q '"Statement"' "$src"; then
      die "The download for policies/${name} was not a policy file."
    fi
  done
  if [[ -L "${dest}/policies" ]]; then
    die "Refusing to replace a linked policies directory."
  fi
  mkdir -p "${dest}/policies.new"
  for name in "${names[@]}"; do
    mv "${stage}/${name}" "${dest}/policies.new/${name}"
    chmod 644 "${dest}/policies.new/${name}"
  done
  if [[ -d "${dest}/policies" ]]; then
    rm -rf "${dest}/policies.prev"
    mv "${dest}/policies" "${dest}/policies.prev"
  fi
  mv "${dest}/policies.new" "${dest}/policies"
  rm -rf "${dest}/policies.prev"
  mv "$tmp" "${dest}/policies.sh"
  chmod 755 "${dest}/policies.sh"
  exec bash "${dest}/policies.sh" "$@"
  die "Could not start policies.sh."
}

main() {
  [[ "$(id -u)" -eq 0 ]] && die "Run this as your regular user."
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  POLICY_DIR="${SCRIPT_DIR}/policies"
  [[ -d "$POLICY_DIR" ]] || die "No policies directory at ${POLICY_DIR}."
  load_admin_env
  printf '=== RustFS policies (%s) ===\n' "$ENDPOINT"
  printf 'Settings: %s\n' "$ENV_FILE"
  ensure_rc
  configure_alias
  import_policies
  unset RUSTFS_ADMIN_PASS
}

if ! is_saved_script; then
  bootstrap_and_exec "$@"
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
