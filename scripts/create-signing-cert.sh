#!/usr/bin/env bash
#
# Creates a stable, self-signed code-signing certificate used to sign Chronicle
# locally, then prints its identity name on stdout.
#
# Why this exists: without an Apple Developer identity, Xcode signs the app
# ad-hoc, whose code hash (cdhash) changes on every build. macOS TCC pins the
# Calendar permission to that hash, so after each rebuild the grant no longer
# matches and the "Grant Calendar Access" flow silently fails. A self-signed
# certificate gives a *stable* Designated Requirement (pinned to the cert, not
# the cdhash), so the permission you grant survives rebuilds.
#
# Idempotent: if the identity already exists this is a no-op. Progress goes to
# stderr; only the identity name is written to stdout so callers can capture it:
#
#     SIGN_IDENTITY="$(scripts/create-signing-cert.sh)"
#
set -euo pipefail

CERT_NAME="${CHRONICLE_SIGN_IDENTITY:-Chronicle Local Signing}"
KEYCHAIN="${CHRONICLE_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

log() { printf '%s\n' "$*" >&2; }

# Self-signed certs are untrusted, so they only appear under the default
# (X.509 Basic) policy, not `-p codesigning`. Match on the identity name.
if security find-identity "$KEYCHAIN" 2>/dev/null | grep -qF "$CERT_NAME"; then
	printf '%s\n' "$CERT_NAME"
	exit 0
fi

log "==> Creating self-signed code-signing certificate \"$CERT_NAME\" (valid 10 years)…"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions     = v3
prompt              = no
[ dn ]
CN = $CERT_NAME
[ v3 ]
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
	-keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
	-days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# Import key and cert separately (more reliable than a PKCS#12 across OpenSSL
# versions). `-T /usr/bin/codesign` adds codesign to the key's access list.
security import "$TMP/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
security import "$TMP/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null

# Let codesign use the key without a GUI prompt. This needs the (login) keychain
# password. If we can't get it, codesign still works — macOS just shows a
# one-time "Always Allow" dialog the first time you build.
KCPW="${CHRONICLE_KEYCHAIN_PASSWORD:-}"
if [[ -z "$KCPW" && -r /dev/tty ]]; then
	printf 'Enter your macOS login password to authorise codesign (or press Enter to skip): ' > /dev/tty
	IFS= read -rs KCPW < /dev/tty || KCPW=""
	printf '\n' > /dev/tty
fi
if [[ -n "$KCPW" ]]; then
	if security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KEYCHAIN" >/dev/null 2>&1; then
		log "==> codesign authorised to use the signing key."
	else
		log "warning: could not authorise the key non-interactively; expect a one-time keychain prompt on first build."
	fi
else
	log "note: skipped keychain authorisation; expect a one-time \"Always Allow\" prompt on first build."
fi

log "==> Certificate ready."
printf '%s\n' "$CERT_NAME"
