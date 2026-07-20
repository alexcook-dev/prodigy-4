#!/usr/bin/env bash
# Package a DMG and publish a GitHub Release (public assets — no end-user auth).
#
# Usage:
#   ./scripts/release.sh              # VERSION file
#   ./scripts/release.sh 0.2.0        # bump + release
#   ./scripts/release.sh --draft 0.2.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRAFT=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --draft) DRAFT=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) VERSION="$arg" ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION="$(tr -d '[:space:]' < VERSION)"
fi
VERSION="${VERSION#v}"
TAG="v${VERSION}"

command -v gh >/dev/null || { echo "error: gh CLI required" >&2; exit 1; }
gh auth status >/dev/null || { echo "error: run gh auth login first" >&2; exit 1; }

# Keep VERSION file in sync when releasing a new number
echo "$VERSION" > VERSION

echo "==> Building DMG for ${TAG}"
./scripts/package-dmg.sh "$VERSION"

DMG="dist/Prodigy-${VERSION}.dmg"
[[ -f "$DMG" ]] || { echo "error: missing $DMG" >&2; exit 1; }

NOTES="$(cat <<EOF
## Prodigy ${TAG}

Production macOS app (separate from Xcode **Prodigy Dev** builds).

### Install (terminal)

No GitHub login required for end users:

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/alexcook-dev/prodigy-4/main/scripts/install.sh | bash
\`\`\`

Installs the DMG + app into \`/Applications\` (\`dev.alexcook.Prodigy\`).

### Manual

1. Download \`Prodigy-${VERSION}.dmg\` below
2. Open the DMG → drag **Prodigy** to Applications
3. Right-click → Open the first time if Gatekeeper warns (ad-hoc signed)

### Dev vs production

| | App name | Bundle ID | How you get it |
|---|---|---|---|
| Production | Prodigy | \`dev.alexcook.Prodigy\` | this release / install.sh |
| Development | Prodigy Dev | \`dev.alexcook.Prodigy.dev\` | Xcode Run (Debug) |

Xcode updates never overwrite your production install.
EOF
)"

ARGS=(release create "$TAG" "$DMG" "${DMG}.sha256" --title "Prodigy ${TAG}" --notes "$NOTES")
if [[ "$DRAFT" -eq 1 ]]; then
  ARGS+=(--draft)
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> Release ${TAG} exists — uploading assets"
  gh release upload "$TAG" "$DMG" "${DMG}.sha256" --clobber
  gh release edit "$TAG" --notes "$NOTES" --title "Prodigy ${TAG}"
else
  echo "==> Creating release ${TAG}"
  gh "${ARGS[@]}"
fi

echo ""
echo "==> Published ${TAG}"
gh release view "$TAG" --web 2>/dev/null || gh release view "$TAG"
