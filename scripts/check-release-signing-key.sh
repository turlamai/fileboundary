#!/usr/bin/env bash
# Verify that the release Ed25519 private key is trusted by the updater
# client (app/update.rkt trust root, docs/update-contract.md). This check
# runs before expensive native packaging and again before publication.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_PEM="${1:-}"

fail() {
  echo "::error::FileBoundary release signing preflight: $*" >&2
  exit 1
}

[[ -n "$KEY_PEM" && -s "$KEY_PEM" ]] || fail "nonempty signing key file is required"
command -v openssl >/dev/null || fail "openssl is required"
command -v base64 >/dev/null || fail "base64 is required"

PUBLIC_DER="$(mktemp)"
trap 'rm -f "$PUBLIC_DER"' EXIT
if ! openssl pkey -in "$KEY_PEM" -pubout -outform DER > "$PUBLIC_DER" 2>/dev/null; then
  fail "signing key is invalid or unreadable"
fi
# Ed25519 SubjectPublicKeyInfo DER is 44 bytes; reject other key algorithms.
[[ "$(wc -c < "$PUBLIC_DER" | tr -d '[:space:]')" == "44" ]] || fail "signing key must be Ed25519"

DER_PUBLIC="$(base64 -w0 < "$PUBLIC_DER")"
# The updater trust root: (define update-public-key-b64 "...") in
# app/update.rkt — the base64 SPKI DER every client embeds.
EXPECTED_DER="$(sed -n '/(define update-public-key-b64/{n;s/^[[:space:]]*"\([^"]*\)".*/\1/p;}' "$ROOT/app/update.rkt")"

[[ -n "$EXPECTED_DER" && "$DER_PUBLIC" == "$EXPECTED_DER" ]] ||
  fail "signing key does not match the updater trust root in app/update.rkt"

# The key id travels inside every signed manifest wrapper and the client
# refuses a mismatching one — prove they also agree.
EXPECTED_ID="$(sed -n 's/.*(define update-key-id "\([^"]*\)".*/\1/p' "$ROOT/app/update.rkt")"
KEY_ID="${RIVET_UPDATE_KEY_ID:-}"
[[ -n "$KEY_ID" ]] || fail "RIVET_UPDATE_KEY_ID is required for the preflight"
[[ -n "$EXPECTED_ID" && "$KEY_ID" == "$EXPECTED_ID" ]] ||
  fail "RIVET_UPDATE_KEY_ID does not match the updater key id in app/update.rkt"

echo "Release signing key matches the updater trust root (key id: $KEY_ID)"
