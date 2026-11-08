#!/usr/bin/env bash
# Generate the Ed25519 keypair used to sign update manifests
# (docs/update-contract.md).
#
#   scripts/update-keys.sh [private-key-path]
#
# Default private key location: D:/Codes/fileboundary-keys/update-signing-key.pem
# (via %USERPROFILE%) — OUTSIDE the repository. The public key is printed
# as base64 SPKI DER for embedding in app/update.rkt (the updater trust
# root scripts/check-release-signing-key.sh compares against).
#
# One-time: also put the PEM into the GitHub secret
# RIVET_UPDATE_PRIVATE_KEY so release.yml can sign manifests.
set -euo pipefail

KEY_PATH="${1:-${FILEBOUNDARY_KEYS_DIR:-$HOME/Codes/fileboundary-keys}/update-signing-key.pem}"

# Ed25519 needs OpenSSL 3+ (older LibreSSL/OpenSSL 1.x cannot do it).
OPENSSL_BIN="${OPENSSL_BIN:-}"
if [[ -z "$OPENSSL_BIN" ]]; then
  for candidate in openssl; do
    if command -v "$candidate" >/dev/null 2>&1 \
       && "$candidate" version 2>/dev/null | grep -q "OpenSSL 3"; then
      OPENSSL_BIN="$candidate"
      break
    fi
  done
fi
[[ -n "$OPENSSL_BIN" ]] || {
  echo "error: OpenSSL 3.x required for Ed25519 (or set OPENSSL_BIN=/path/to/openssl)" >&2
  exit 1
}

if [[ -f "$KEY_PATH" ]]; then
  echo "Private key already exists: $KEY_PATH" >&2
  echo "Delete it first if you really want to rotate (rotating requires a" >&2
  echo "public-key rollout release — see docs/update-contract.md)." >&2
  exit 1
fi

mkdir -p "$(dirname "$KEY_PATH")"
umask 077
"$OPENSSL_BIN" genpkey -algorithm ed25519 -out "$KEY_PATH"

PUB_DER_B64="$("$OPENSSL_BIN" pkey -in "$KEY_PATH" -pubout -outform DER 2>/dev/null | base64 -w0)"

echo "Private key: $KEY_PATH  (back this up; put the PEM in GitHub secret"
echo "             RIVET_UPDATE_PRIVATE_KEY)"
echo "Public key (SPKI DER, base64 — embed in app/update.rkt):"
echo "$PUB_DER_B64"
