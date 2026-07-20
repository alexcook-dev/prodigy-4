#!/usr/bin/env bash
# Install or update production Prodigy.app from the latest public GitHub Release.
# No GitHub login required — the repo and releases are public.
#
# Bootstraps only what macOS may lack for a clean machine:
#   - bash, curl, hdiutil, ditto (system)
#   - Xcode CLT if missing (needed only if Homebrew is installed later)
#   - python3 if missing (JSON parse; usually preinstalled on macOS)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/alexcook-dev/prodigy-4/main/scripts/install.sh | bash
#   ./scripts/install.sh
#   ./scripts/install.sh --version v0.1.1
#   INSTALL_DIR=$HOME/Applications ./scripts/install.sh
#   NONINTERACTIVE=1 ./scripts/install.sh
#
set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  if [ -x /bin/bash ]; then
    exec /bin/bash "$0" "$@"
  fi
  echo "error: bash is required." >&2
  exit 1
fi

REPO="${PRODIGY_REPO:-alexcook-dev/prodigy-4}"
INSTALL_DIR="${INSTALL_DIR:-}"
APP_NAME="Prodigy"
DMG_INSTALL_NAME="${APP_NAME}.dmg"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
SKIP_DEPS="${PRODIGY_SKIP_DEPS:-0}"

REQUESTED_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) REQUESTED_VERSION="${2:-}"; shift 2 ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
    *) REQUESTED_VERSION="$1"; shift ;;
  esac
done

log()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "Prodigy install is only supported on macOS."
}

ensure_bash() {
  have_cmd bash || die "bash not found"
  note "bash: $(command -v bash)"
}

ensure_macos_utils() {
  for c in curl hdiutil ditto plutil xattr codesign osascript pgrep open mktemp; do
    have_cmd "$c" || die "missing required macOS tool: $c"
  done
  note "macOS tools OK (curl, hdiutil, ditto, …)"
}

ensure_python3() {
  if have_cmd python3; then
    note "python3: $(command -v python3)"
    return 0
  fi
  # Rare on modern macOS — try CLT / leave a clear message (no brew/gh required).
  die "python3 not found. Install Xcode Command Line Tools (xcode-select --install) and re-run."
}

bootstrap_deps() {
  if [[ "$SKIP_DEPS" == "1" ]]; then
    log "Skipping dependency checks (--skip-deps)"
    return 0
  fi
  log "Checking dependencies (no GitHub login required)"
  ensure_macos
  ensure_bash
  ensure_macos_utils
  ensure_python3
  log "Dependencies ready"
}

TMPDIR_ROOT="$(mktemp -d -t prodigy-install)"
MOUNT_POINT=""
cleanup() {
  if [[ -n "${MOUNT_POINT:-}" && -d "${MOUNT_POINT}" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

# Public GitHub API — no Authorization header.
api() {
  local path="$1"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${REPO}${path}"
}

# Download Prodigy-*.dmg via public browser_download_url (no auth).
download_dmg() {
  local tag="$1"
  local out_dir="$2"
  local json_file="${out_dir}/release.json"

  if [[ -n "$tag" ]]; then
    [[ "$tag" == v* ]] || tag="v${tag}"
    api "/releases/tags/${tag}" > "$json_file"
  else
    api "/releases/latest" > "$json_file"
  fi

  local parsed
  parsed="$(python3 - "$json_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for a in data.get("assets") or []:
    name = a.get("name") or ""
    if name.startswith("Prodigy-") and name.endswith(".dmg"):
        url = a.get("browser_download_url") or ""
        if url:
            print(url + "\t" + name)
            raise SystemExit(0)
raise SystemExit(1)
PY
)" || die "no public Prodigy-*.dmg on release ${tag:-latest}"

  local download_url asset_name
  download_url="${parsed%%$'\t'*}"
  asset_name="${parsed#*$'\t'}"
  [[ -n "$download_url" && -n "$asset_name" ]] || die "could not resolve DMG download URL"

  local dest="${out_dir}/${asset_name}"
  log "Downloading ${asset_name} (public release, no login)"
  note "$download_url"
  curl -fL --progress-bar -o "$dest" "$download_url"
  echo "$dest"
}

resolve_install_dir() {
  if [[ -n "${INSTALL_DIR}" ]]; then
    echo "${INSTALL_DIR}"
    return 0
  fi
  if [[ -d /Applications ]] && touch /Applications/.prodigy-write-test 2>/dev/null; then
    rm -f /Applications/.prodigy-write-test
    echo /Applications
    return 0
  fi
  if [[ -d /Applications ]]; then
    echo /Applications
    return 0
  fi
  echo "${HOME}/Applications"
}

install_file_to_dir() {
  local src="$1" dest="$2" dest_dir
  dest_dir="$(dirname "$dest")"
  mkdir -p "$dest_dir" 2>/dev/null || true
  if cp -f "$src" "$dest" 2>/dev/null || ditto "$src" "$dest" 2>/dev/null; then
    return 0
  fi
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    die "cannot write ${dest}. Try INSTALL_DIR=\$HOME/Applications"
  fi
  log "Need administrator permission to write ${dest}"
  sudo mkdir -p "$dest_dir"
  sudo cp -f "$src" "$dest"
}

install_dir_to_dir() {
  local src="$1" dest="$2" dest_dir
  dest_dir="$(dirname "$dest")"
  mkdir -p "$dest_dir" 2>/dev/null || true
  # Prefer in-place ditto over rm -rf + copy. Replacing the bundle path
  # outright can drop path-based TCC grants even with a stable signature.
  if ditto "$src" "$dest" 2>/dev/null; then
    return 0
  fi
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    die "cannot write ${dest}. Try INSTALL_DIR=\$HOME/Applications"
  fi
  log "Need administrator permission to install ${dest}"
  sudo mkdir -p "$dest_dir"
  # Fallback: only remove if in-place sudo ditto fails.
  if ! sudo ditto "$src" "$dest" 2>/dev/null; then
    sudo rm -rf "$dest"
    sudo ditto "$src" "$dest"
  fi
}

install_app() {
  local apps_dir
  apps_dir="$(resolve_install_dir)"
  INSTALL_DIR="$apps_dir"

  log "Installing production ${APP_NAME} from public GitHub releases (${REPO})"
  note "Applications folder: ${apps_dir}"
  note "Will place: ${apps_dir}/${DMG_INSTALL_NAME}  (DMG package)"
  note "       and: ${apps_dir}/${APP_NAME}.app      (app from that DMG)"

  mkdir -p "$TMPDIR_ROOT/dl"
  local dmg
  dmg="$(download_dmg "${REQUESTED_VERSION}" "$TMPDIR_ROOT/dl")"
  [[ -n "$dmg" && -f "$dmg" ]] || die "DMG not downloaded"

  local dmg_basename dmg_in_apps dmg_stable
  dmg_basename="$(basename "$dmg")"
  dmg_in_apps="${apps_dir}/${dmg_basename}"
  dmg_stable="${apps_dir}/${DMG_INSTALL_NAME}"

  log "Installing DMG into Applications → ${dmg_in_apps}"
  install_file_to_dir "$dmg" "$dmg_in_apps"
  xattr -dr com.apple.quarantine "$dmg_in_apps" 2>/dev/null || true
  if [[ "$dmg_in_apps" != "$dmg_stable" ]]; then
    install_file_to_dir "$dmg" "$dmg_stable"
    xattr -dr com.apple.quarantine "$dmg_stable" 2>/dev/null || true
  fi

  log "Mounting ${dmg_in_apps}"
  local attach_out
  attach_out="$(hdiutil attach "$dmg_in_apps" -nobrowse -readonly)"
  MOUNT_POINT="$(echo "$attach_out" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
  [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || die "failed to mount DMG"

  local src_app="${MOUNT_POINT}/${APP_NAME}.app"
  [[ -d "$src_app" ]] || die "${APP_NAME}.app not found inside DMG"

  local dest_app="${apps_dir}/${APP_NAME}.app"
  if pgrep -x "Prodigy" >/dev/null 2>&1; then
    log "Quitting running Prodigy…"
    osascript -e 'tell application "Prodigy" to quit' 2>/dev/null || true
    sleep 1
  fi

  log "Installing app from DMG → ${dest_app}"
  install_dir_to_dir "$src_app" "$dest_app"
  # Preserve the app's code signature from the DMG. Ad-hoc re-signing on every
  # install forces macOS to re-prompt for Folders / Photos / Automation (TCC).
  xattr -dr com.apple.quarantine "$dest_app" 2>/dev/null || true

  if [[ -n "${MOUNT_POINT:-}" && -d "${MOUNT_POINT}" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    MOUNT_POINT=""
  fi

  echo ""
  log "Installed package (DMG):  ${dmg_in_apps}"
  [[ -f "$dmg_stable" && "$dmg_stable" != "$dmg_in_apps" ]] && note "Stable alias: ${dmg_stable}"
  log "Installed application:    ${dest_app}"
  plutil -p "${dest_app}/Contents/Info.plist" | grep -E 'CFBundle(Identifier|Name|ShortVersionString|DisplayName)' || true
  echo ""
  note "Open with:  open \"${dest_app}\""
  note "No GitHub account or login is required for installs or updates."
}

bootstrap_deps
install_app
