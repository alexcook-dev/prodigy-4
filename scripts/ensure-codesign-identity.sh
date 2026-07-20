#!/usr/bin/env bash
# Ensure a stable codesigning identity for Prodigy release builds.
#
# Ad-hoc signatures (`codesign -s -`) set designated requirement to pure CDHash.
# Every rebuild changes the CDHash, so macOS TCC re-prompts for Folders, Photos,
# Calendar, Reminders, Automation, etc. after every update.
#
# A self-signed identity keeps the designated requirement certificate-based so
# permissions stick across version upgrades on the same machine.
#
# Usage:
#   source ./scripts/ensure-codesign-identity.sh   # sets CODESIGN_IDENTITY
#   ./scripts/ensure-codesign-identity.sh          # prints identity and exits 0
#
# Override:
#   CODESIGN_IDENTITY="Developer ID Application: …" ./scripts/package-dmg.sh
set -euo pipefail

PRODIGY_CERT_CN="${PRODIGY_CERT_CN:-Prodigy Signing}"
PRODIGY_CERT_ORG="${PRODIGY_CERT_ORG:-Prodigy Local}"

# Prefer an explicit override (Developer ID, team cert, etc.).
if [[ -n "${CODESIGN_IDENTITY:-}" && "${CODESIGN_IDENTITY}" != "-" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"${CODESIGN_IDENTITY}\"" >/dev/null; then
    echo "${CODESIGN_IDENTITY}"
    return 0 2>/dev/null || exit 0
  fi
  # Identity string may still work for codesign even if grep fails (hash form).
  echo "${CODESIGN_IDENTITY}"
  return 0 2>/dev/null || exit 0
fi

# Prefer any existing "Prodigy Signing" identity in the keychain.
if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"${PRODIGY_CERT_CN}\"" >/dev/null; then
  echo "${PRODIGY_CERT_CN}"
  return 0 2>/dev/null || exit 0
fi

# Prefer a real Apple Developer ID if the machine has one.
_DEV_ID="$(
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
    | head -1
)"
if [[ -n "${_DEV_ID}" ]]; then
  echo "${_DEV_ID}"
  return 0 2>/dev/null || exit 0
fi

# Create a long-lived self-signed code-signing certificate once.
echo "==> Creating stable codesign identity \"${PRODIGY_CERT_CN}\"" >&2
echo "    (one-time; keeps TCC folder/calendar/mail prompts from repeating on update)" >&2

_TMP="$(mktemp -d -t prodigy-codesign)"
cleanup() { rm -rf "$_TMP"; }
trap cleanup EXIT

# OpenSSL config for a codesigning leaf cert.
cat >"${_TMP}/openssl.cnf" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
x509_extensions    = codesign_ext
prompt             = no

[ req_dn ]
CN = ${PRODIGY_CERT_CN}
O  = ${PRODIGY_CERT_ORG}

[ codesign_ext ]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF

openssl req -new -newkey rsa:2048 -nodes \
  -keyout "${_TMP}/key.pem" \
  -out "${_TMP}/csr.pem" \
  -config "${_TMP}/openssl.cnf" >/dev/null 2>&1

openssl x509 -req -days 3650 \
  -in "${_TMP}/csr.pem" \
  -signkey "${_TMP}/key.pem" \
  -out "${_TMP}/cert.pem" \
  -extfile "${_TMP}/openssl.cnf" \
  -extensions codesign_ext >/dev/null 2>&1

# PKCS#12 import into login keychain; empty export password for local use only.
openssl pkcs12 -export \
  -inkey "${_TMP}/key.pem" \
  -in "${_TMP}/cert.pem" \
  -out "${_TMP}/identity.p12" \
  -passout pass: \
  -name "${PRODIGY_CERT_CN}" >/dev/null 2>&1

_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
if [[ ! -f "$_KEYCHAIN" ]]; then
  _KEYCHAIN="${HOME}/Library/Keychains/login.keychain"
fi

# Import cert+key; allow codesign to use the key without UI prompts when possible.
security import "${_TMP}/identity.p12" \
  -k "$_KEYCHAIN" \
  -P "" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -T /usr/bin/productsign \
  >/dev/null 2>&1 || {
    # Retry with a non-empty password if empty export fails on this OpenSSL.
    openssl pkcs12 -export \
      -inkey "${_TMP}/key.pem" \
      -in "${_TMP}/cert.pem" \
      -out "${_TMP}/identity.p12" \
      -passout pass:prodigy-local \
      -name "${PRODIGY_CERT_CN}" >/dev/null 2>&1
    security import "${_TMP}/identity.p12" \
      -k "$_KEYCHAIN" \
      -P "prodigy-local" \
      -T /usr/bin/codesign \
      -T /usr/bin/security \
      -T /usr/bin/productsign \
      >/dev/null
  }

# Trust for code signing (non-interactive best-effort).
security add-trusted-cert -d -r trustRoot -p codeSign \
  -k "$_KEYCHAIN" "${_TMP}/cert.pem" >/dev/null 2>&1 || true

# Allow codesign to use the private key without keychain UI (best-effort).
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "" \
  "$_KEYCHAIN" >/dev/null 2>&1 || true

if ! security find-identity -v -p codesigning 2>/dev/null | grep -F "\"${PRODIGY_CERT_CN}\"" >/dev/null; then
  echo "error: failed to install codesign identity \"${PRODIGY_CERT_CN}\"" >&2
  echo "       Create a certificate named \"${PRODIGY_CERT_CN}\" in Keychain Access" >&2
  echo "       (Certificate Assistant → Create a Certificate → Code Signing)" >&2
  echo "       or set CODESIGN_IDENTITY to an existing identity." >&2
  exit 1
fi

echo "${PRODIGY_CERT_CN}"
