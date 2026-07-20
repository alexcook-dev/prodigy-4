#!/usr/bin/env bash
# Install or update production Prodigy.app from the latest GitHub Release.
#
# Bootstraps anything needed on a clean Mac:
#   - macOS + bash
#   - Xcode Command Line Tools (if missing; may open a GUI installer)
#   - Homebrew
#   - GitHub CLI (`gh`)
#   - gh authentication (private repo) unless GH_TOKEN / GITHUB_TOKEN is set
#
# Usage:
#   # From a clone:
#   ./scripts/install.sh
#   ./scripts/install.sh --version v0.1.1
#
#   # Recommended private-repo one-liner (after first clone or with gh available):
#   bash <(gh api repos/alexcook-dev/prodigy-4/contents/scripts/install.sh --jq .content | base64 -d)
#
#   INSTALL_DIR=/Applications ./scripts/install.sh
#   NONINTERACTIVE=1 GH_TOKEN=... ./scripts/install.sh   # CI / unattended
#
set -euo pipefail

# Prefer a real bash if we were launched under a minimal sh (Homebrew install needs bash).
if [ -z "${BASH_VERSION:-}" ]; then
  if [ -x /bin/bash ]; then
    exec /bin/bash "$0" "$@"
  fi
  echo "error: bash is required. Install bash and re-run." >&2
  exit 1
fi

REPO="${PRODIGY_REPO:-alexcook-dev/prodigy-4}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_NAME="Prodigy"
ASSET_GLOB="${APP_NAME}-*.dmg"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
SKIP_DEPS="${PRODIGY_SKIP_DEPS:-0}"

REQUESTED_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      REQUESTED_VERSION="${2:-}"
      shift 2
      ;;
    --skip-deps)
      SKIP_DEPS=1
      shift
      ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
    *)
      REQUESTED_VERSION="$1"
      shift
      ;;
  esac
done

log()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Platform + core tools that ship with (or alongside) macOS
# ---------------------------------------------------------------------------

ensure_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "Prodigy install is only supported on macOS."
}

ensure_bash() {
  if ! command -v bash >/dev/null 2>&1; then
    die "bash not found. macOS always includes /bin/bash — is PATH broken?"
  fi
  # Homebrew's bash is nicer for scripts, but system bash is enough.
  note "bash: $(command -v bash) (${BASH_VERSION})"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Xcode Command Line Tools (git, clang — required by Homebrew)
# ---------------------------------------------------------------------------

ensure_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    note "Xcode CLT: $(xcode-select -p)"
    return 0
  fi

  log "Installing Xcode Command Line Tools (needed for Homebrew/git)"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    # Touch the softwareupdate flag file and try CLI install path.
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress 2>/dev/null || true
    local label
    label="$(softwareupdate -l 2>/dev/null | awk -F'*' '/Command Line Tools/{print $2}' | sed 's/^ *//' | tail -1)" || true
    if [[ -n "${label:-}" ]]; then
      softwareupdate -i "$label" --verbose || true
    fi
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress 2>/dev/null || true
    xcode-select -p >/dev/null 2>&1 || die "Xcode CLT still missing. Run: xcode-select --install  then re-run this script."
    return 0
  fi

  echo ""
  echo "A macOS dialog will open to install Command Line Tools."
  echo "Finish that installer, then press Enter here to continue."
  xcode-select --install 2>/dev/null || true
  read -r -p "Press Enter after Command Line Tools are installed… " _
  xcode-select -p >/dev/null 2>&1 || die "Xcode CLT still not found. Install them and re-run."
}

# ---------------------------------------------------------------------------
# Homebrew
# ---------------------------------------------------------------------------

brew_prefix_guess() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    echo /opt/homebrew
  elif [[ -x /usr/local/bin/brew ]]; then
    echo /usr/local
  else
    echo ""
  fi
}

load_brew_env() {
  local prefix
  prefix="$(brew_prefix_guess)"
  if [[ -n "$prefix" && -x "${prefix}/bin/brew" ]]; then
    # shellcheck disable=SC1091
    eval "$("${prefix}/bin/brew" shellenv)"
  fi
  if have_cmd brew; then
    return 0
  fi
  return 1
}

ensure_homebrew() {
  if load_brew_env; then
    note "Homebrew: $(command -v brew) ($(brew --version 2>/dev/null | head -1))"
    return 0
  fi

  log "Installing Homebrew"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  load_brew_env || die "Homebrew installed but not on PATH. Open a new terminal or add brew to PATH, then re-run."
  note "Homebrew: $(command -v brew)"

  # Persist shellenv hint for the user (do not silently rewrite their rc without asking).
  local prefix
  prefix="$(brew_prefix_guess)"
  if [[ -n "$prefix" ]]; then
    note "Add to your shell profile if brew is missing later:"
    note "  eval \"\$(${prefix}/bin/brew shellenv)\""
  fi
}

# ---------------------------------------------------------------------------
# Formulae: gh (required for private releases), curl is system
# ---------------------------------------------------------------------------

brew_install_if_missing() {
  local formula="$1"
  if have_cmd "$formula"; then
    note "$formula: $(command -v "$formula")"
    return 0
  fi
  # Some tools use different binary names than formulae.
  case "$formula" in
    gh)
      if have_cmd gh; then note "gh: $(command -v gh)"; return 0; fi
      ;;
  esac
  log "Installing $formula via Homebrew"
  brew install "$formula"
}

ensure_gh() {
  brew_install_if_missing gh
  have_cmd gh || die "gh CLI not available after brew install"
  note "gh: $(gh --version 2>/dev/null | head -1)"
}

ensure_python3() {
  if have_cmd python3; then
    note "python3: $(command -v python3)"
    return 0
  fi
  log "Installing python3 via Homebrew (JSON parsing fallback)"
  brew install python
  have_cmd python3 || die "python3 still missing"
}

ensure_macos_utils() {
  # These are built into macOS; fail clearly if something is very wrong.
  for c in curl hdiutil ditto plutil xattr codesign osascript pgrep open mktemp; do
    have_cmd "$c" || die "missing required macOS tool: $c"
  done
  note "macOS tools: curl, hdiutil, ditto, plutil OK"
}

# ---------------------------------------------------------------------------
# GitHub auth (private repo)
# ---------------------------------------------------------------------------

ensure_github_auth() {
  if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
    export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
    note "Using GH_TOKEN / GITHUB_TOKEN for GitHub API"
    return 0
  fi

  if gh auth status >/dev/null 2>&1; then
    note "gh auth: already logged in"
    return 0
  fi

  log "GitHub login required (private repo: ${REPO})"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    die "Not authenticated. Set GH_TOKEN or run interactively: gh auth login"
  fi

  echo ""
  echo "Opening GitHub CLI login. Choose HTTPS and authenticate in the browser."
  echo ""
  gh auth login -h github.com -p https -w || die "gh auth login failed"
  gh auth status >/dev/null 2>&1 || die "Still not authenticated after gh auth login"
  note "gh auth: OK"
}

# ---------------------------------------------------------------------------
# Bootstrap all deps
# ---------------------------------------------------------------------------

bootstrap_deps() {
  if [[ "$SKIP_DEPS" == "1" ]]; then
    log "Skipping dependency bootstrap (PRODIGY_SKIP_DEPS / --skip-deps)"
    load_brew_env || true
    return 0
  fi

  log "Checking / installing dependencies"
  ensure_macos
  ensure_bash
  ensure_macos_utils
  ensure_xcode_clt
  ensure_homebrew
  ensure_gh
  ensure_python3
  ensure_github_auth
  log "Dependencies ready"
}

# ---------------------------------------------------------------------------
# Download + install app
# ---------------------------------------------------------------------------

TMPDIR_ROOT="$(mktemp -d -t prodigy-install)"
MOUNT_POINT=""
cleanup() {
  if [[ -n "${MOUNT_POINT:-}" && -d "${MOUNT_POINT}" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

auth_header=()
refresh_auth_header() {
  auth_header=()
  if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
    auth_header=(-H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}")
  elif have_cmd gh && gh auth status >/dev/null 2>&1; then
    local tok
    tok="$(gh auth token 2>/dev/null || true)"
    if [[ -n "$tok" ]]; then
      auth_header=(-H "Authorization: Bearer ${tok}")
    fi
  fi
}

api() {
  local path="$1"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${auth_header[@]}" \
    "https://api.github.com/repos/${REPO}${path}"
}

download_with_gh() {
  local tag="$1"
  local out="$2"
  if [[ -n "$tag" ]]; then
    # Accept tag with or without leading v
    if [[ "$tag" != v* ]]; then
      tag="v${tag}"
    fi
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
    if [[ "$tag" != v* ]]; then
      tag="v${tag}"
    fi
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
        print(a["url"] + "\t" + name)
        raise SystemExit(0)
raise SystemExit(1)
PY
)" || die "no Prodigy-*.dmg asset on release ${tag:-latest}"

  local asset_api_url asset_name
  asset_api_url="${parsed%%$'\t'*}"
  asset_name="${parsed#*$'\t'}"
  [[ -n "$asset_api_url" && -n "$asset_name" ]] || die "could not resolve DMG asset URL"

  local dest="${out_dir}/${asset_name}"
  curl -fsSL \
    -H "Accept: application/octet-stream" \
    "${auth_header[@]}" \
    -o "$dest" \
    "$asset_api_url"
  echo "$dest"
}

install_app() {
  log "Installing production ${APP_NAME} from GitHub (${REPO})"
  note "destination: ${INSTALL_DIR}/${APP_NAME}.app"
  note "Xcode Debug builds use Prodigy Dev — they will not overwrite this."

  mkdir -p "$INSTALL_DIR"
  mkdir -p "$TMPDIR_ROOT/dl"
  refresh_auth_header

  local dmg=""
  if have_cmd gh && gh auth status >/dev/null 2>&1; then
    log "Downloading with gh"
    download_with_gh "${REQUESTED_VERSION}" "$TMPDIR_ROOT/dl"
    dmg="$(find "$TMPDIR_ROOT/dl" -maxdepth 1 -name 'Prodigy-*.dmg' | head -1)"
  else
    log "Downloading with GitHub API"
    dmg="$(download_with_api "${REQUESTED_VERSION}" "$TMPDIR_ROOT/dl")"
  fi

  [[ -n "$dmg" && -f "$dmg" ]] || die "DMG not downloaded"

  log "Mounting $(basename "$dmg")"
  local attach_out
  attach_out="$(hdiutil attach "$dmg" -nobrowse -readonly)"
  MOUNT_POINT="$(echo "$attach_out" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
  [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || die "failed to mount DMG"

  local src_app="${MOUNT_POINT}/${APP_NAME}.app"
  [[ -d "$src_app" ]] || die "${APP_NAME}.app not found inside DMG"

  local dest="${INSTALL_DIR}/${APP_NAME}.app"
  if pgrep -x "Prodigy" >/dev/null 2>&1; then
    log "Quitting running Prodigy…"
    osascript -e 'tell application "Prodigy" to quit' 2>/dev/null || true
    sleep 1
  fi

  if [[ -d "$dest" ]]; then
    log "Replacing existing ${dest}"
    rm -rf "$dest"
  fi

  log "Copying app"
  ditto "$src_app" "$dest"
  xattr -cr "$dest" 2>/dev/null || true
  codesign --force --deep --sign - "$dest" 2>/dev/null || true

  echo ""
  log "Installed ${dest}"
  plutil -p "${dest}/Contents/Info.plist" | grep -E 'CFBundle(Identifier|Name|ShortVersionString|DisplayName)' || true
  echo ""
  note "Open with:  open \"${dest}\""
  note "Dev tip:    Xcode Run builds 'Prodigy Dev' — separate from this install."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

bootstrap_deps
install_app
