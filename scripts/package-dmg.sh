#!/usr/bin/env bash
# Build Release Prodigy.app and wrap it in a DMG for GitHub Releases.
#
# Usage:
#   ./scripts/package-dmg.sh              # uses VERSION file
#   ./scripts/package-dmg.sh 0.2.0        # override version
#
# Output:
#   dist/Prodigy-<version>.dmg
#   dist/Prodigy.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-${VERSION:-}}"
if [[ -z "$VERSION" ]]; then
  if [[ -f VERSION ]]; then
    VERSION="$(tr -d '[:space:]' < VERSION)"
  else
    VERSION="0.1.0"
  fi
fi
VERSION="${VERSION#v}"

PROJECT="CommandCenter/CommandCenter.xcodeproj"
SCHEME="CommandCenter"
CONFIG="Release"
APP_NAME="Prodigy"
BUNDLE_ID="dev.alexcook.Prodigy"
DERIVED="${ROOT}/dist/DerivedData"
STAGE="${ROOT}/dist/dmg-stage"
OUT_DIR="${ROOT}/dist"
DMG_PATH="${OUT_DIR}/${APP_NAME}-${VERSION}.dmg"
APP_PATH="${OUT_DIR}/${APP_NAME}.app"

echo "==> Packaging ${APP_NAME} v${VERSION}"
echo "    bundle id: ${BUNDLE_ID}"
echo "    output:    ${DMG_PATH}"

rm -rf "$DERIVED" "$STAGE" "$APP_PATH" "$DMG_PATH" "${DMG_PATH}.sha256"
mkdir -p "$OUT_DIR" "$STAGE"

echo "==> Building Release (xcodebuild)"
# Do NOT pass PRODUCT_NAME / PRODUCT_BUNDLE_IDENTIFIER on the command line —
# xcodebuild applies those to SPM package targets too and renames resource
# bundles (SwiftTerm_SwiftTerm.bundle → Prodigy.bundle), breaking the copy.
# Release config in the Xcode project already sets Prodigy / dev.alexcook.Prodigy.
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=YES \
  build

BUILT_APP="${DERIVED}/Build/Products/${CONFIG}/${APP_NAME}.app"
if [[ ! -d "$BUILT_APP" ]]; then
  # Fallback: older PRODUCT_NAME if project settings drifted
  if [[ -d "${DERIVED}/Build/Products/${CONFIG}/CommandCenter.app" ]]; then
    BUILT_APP="${DERIVED}/Build/Products/${CONFIG}/CommandCenter.app"
    echo "warning: found CommandCenter.app — rename to Prodigy.app for packaging" >&2
  else
    echo "error: expected app not found at $BUILT_APP" >&2
    ls -la "${DERIVED}/Build/Products/${CONFIG}/" 2>/dev/null || true
    exit 1
  fi
fi

echo "==> Staging app + Applications symlink"
ditto "$BUILT_APP" "$APP_PATH"

# Stable codesign identity (NOT ad-hoc). Ad-hoc DR is pure CDHash → every
# release looks like a new app to TCC and re-prompts Folders/Calendar/Mail.
# Installers must NOT re-sign; they only strip quarantine.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  IDENTITY="$("$ROOT/scripts/ensure-codesign-identity.sh")"
fi
echo "==> Codesigning with identity: ${IDENTITY}"
codesign \
  --force \
  --deep \
  --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --timestamp=none \
  "$APP_PATH"
# Verify the designated requirement is certificate-based (not pure cdhash).
# codesign -d writes requirement lines to stderr.
DR="$(codesign -d -r- "$APP_PATH" 2>&1 | sed -n 's/.*designated => //p' | head -1 || true)"
echo "    designated => ${DR:-unknown}"
if [[ "$DR" == cdhash* ]] || [[ -z "$DR" ]]; then
  echo "warning: designated requirement looks CDHash-only or empty; TCC may re-prompt on update" >&2
  echo "         ensure CODESIGN_IDENTITY is a real certificate, not ad-hoc (-)" >&2
fi
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

ditto "$APP_PATH" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/Applications"

echo "==> Creating DMG"
TMP_DMG="${OUT_DIR}/.tmp-${APP_NAME}.dmg"
rm -f "$TMP_DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDRW \
  "$TMP_DMG" >/dev/null

hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$TMP_DMG"
rm -rf "$STAGE"

(
  cd "$OUT_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256"
)

echo ""
echo "==> Done"
echo "    App:  $APP_PATH"
echo "    DMG:  $DMG_PATH"
echo "    SHA:  ${DMG_PATH}.sha256"
plutil -p "${APP_PATH}/Contents/Info.plist" | grep -E 'CFBundle(Identifier|Name|ShortVersionString|Version|DisplayName)' || true
echo ""
echo "Install locally:  ditto \"$APP_PATH\" /Applications/Prodigy.app && xattr -dr com.apple.quarantine /Applications/Prodigy.app"
echo "  (in-place ditto — do not rm -rf first; preserves TCC grants)"
echo "Release upload:   gh release create \"v${VERSION}\" \"$DMG_PATH\" --title \"Prodigy v${VERSION}\" --generate-notes"
