#!/usr/bin/env bash
# Install or update the production Prodigy.app from the latest GitHub Release.
#
# Private repo: requires GitHub auth (`gh auth login` or GH_TOKEN).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/alexcook-dev/prodigy-4/main/scripts/install.sh | bash
#   # or, from a clone:
#   ./scripts/install.sh
#   ./scripts/install.sh --version v0.1.0
#   INSTALL_DIR=/Applications ./scripts/install.sh
set -euo pipefail

REPO="${PRODIGY_REPO:-alexcook-dev/prodigy-4}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_NAME="Prodigy"
ASSET_GLOB="${APP_NAME}-*.dmg"
REQUESTED_VERSION="${1:-}"
if [[ "${REQUESTED_VERSION}" == "--version" ]]; then
  REQUESTED_VERSION="${2:-}"
fi
# Allow: install.sh v0.1.0
if [[ "${REQUESTED_VERSION}" == -* ]]; then
  echo "Unknown flag: $REQUESTED_VERSION" >&2
  exit 2
fi

TMPDIR_ROOT="$(mktemp -d -t prodigy-install)"
cleanup() {
  if [[ -n "${MOUNT_POINT:-}" && -d "${MOUNT_POINT}" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

need_cmd curl
need_cmd hdiutil
need_cmd ditto

auth_header=()
if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  auth_header=(-H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}")
fi

api() {
  local path="$1"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${auth_header[@]}" \
    "https://api.github.com/repos/${REPO}${path}"
}

download_with_gh() {
  need_cmd gh
  local tag="$1"
  local out="$2"
  if [[ -n "$tag" ]]; then
    gh release download "$tag" -R "$REPO" -p "$ASSET_GLOB" -D "$out"
  else
    gh release download -R "$REPO" -p "$ASSET_GLOB" -D "$out"
  fi
}

download_with_api() {
  local tag="$1"
  local out_dir="$2"
  local json_file="${out_dir}/release.json"
  if [[ -n "$tag" ]]; then
    api "/releases/tags/${tag}" > "$json_file"
  else
    api "/releases/latest" > "$json_file"
  fi

  # python3 is always on macOS; parse asset API URL (needs Accept: octet-stream + auth)
  local parsed
  parsed="$(python3 - "$json_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for a in data.get("assets") or []:
    name = a.get("name") or ""
    if name.startswith("Prodigy-") and name.endswith(".dmg"):
        print(a["url"] + "\t" + name)
        raise SystemExit(0)
raise SystemExit(1)
PY
)" || {
    echo "error: no Prodigy-*.dmg asset on release ${tag:-latest}" >&2
    echo "Create one with: ./scripts/package-dmg.sh && gh release create ..." >&2
    exit 1
  }

  local asset_api_url asset_name
  asset_api_url="${parsed%%$'\t'*}"
  asset_name="${parsed#*$'\t'}"

  if [[ -z "$asset_api_url" || -z "$asset_name" ]]; then
    echo "error: could not resolve DMG asset URL" >&2
    exit 1
  fi

  local dest="${out_dir}/${asset_name}"
  curl -fsSL \
    -H "Accept: application/octet-stream" \
    "${auth_header[@]}" \
    -o "$dest" \
    "$asset_api_url"
  echo "$dest"
}

echo "==> Installing production ${APP_NAME} from GitHub (${REPO})"
echo "    destination: ${INSTALL_DIR}/${APP_NAME}.app"
echo "    (Xcode Debug builds use a different app: Prodigy Dev — they will not overwrite this.)"

mkdir -p "$INSTALL_DIR"
mkdir -p "$TMPDIR_ROOT/dl"

DMG=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "==> Downloading with gh"
  download_with_gh "${REQUESTED_VERSION}" "$TMPDIR_ROOT/dl"
  DMG="$(find "$TMPDIR_ROOT/dl" -maxdepth 1 -name 'Prodigy-*.dmg' | head -1)"
else
  if [[ ${#auth_header[@]} -eq 0 ]]; then
    echo "note: private repos need auth. Run: gh auth login"
    echo "      or:  GH_TOKEN=... $0"
  fi
  echo "==> Downloading with GitHub API"
  DMG="$(download_with_api "${REQUESTED_VERSION}" "$TMPDIR_ROOT/dl")"
fi

if [[ -z "$DMG" || ! -f "$DMG" ]]; then
  echo "error: DMG not downloaded" >&2
  exit 1
fi

echo "==> Mounting $(basename "$DMG")"
# Attach without browsing; capture mount point
ATTACH_OUT="$(hdiutil attach "$DMG" -nobrowse -readonly)"
MOUNT_POINT="$(echo "$ATTACH_OUT" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
  echo "error: failed to mount DMG" >&2
  echo "$ATTACH_OUT" >&2
  exit 1
fi

SRC_APP="${MOUNT_POINT}/${APP_NAME}.app"
if [[ ! -d "$SRC_APP" ]]; then
  echo "error: ${APP_NAME}.app not found inside DMG" >&2
  ls -la "$MOUNT_POINT" >&2 || true
  exit 1
fi

DEST="${INSTALL_DIR}/${APP_NAME}.app"
# Quit production app if running (not Prodigy Dev)
if pgrep -x "Prodigy" >/dev/null 2>&1; then
  echo "==> Quitting running Prodigy..."
  osascript -e 'tell application "Prodigy" to quit' 2>/dev/null || true
  sleep 1
fi

if [[ -d "$DEST" ]]; then
  echo "==> Replacing existing ${DEST}"
  rm -rf "$DEST"
fi

echo "==> Copying app"
ditto "$SRC_APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
codesign --force --deep --sign - "$DEST" 2>/dev/null || true

echo ""
echo "==> Installed ${DEST}"
plutil -p "${DEST}/Contents/Info.plist" | grep -E 'CFBundle(Identifier|Name|ShortVersionString|DisplayName)' || true
echo ""
echo "Open with:  open \"${DEST}\""
echo "Dev tip:    Xcode Run builds 'Prodigy Dev' (dev.alexcook.Prodigy.dev) — separate from this install."
