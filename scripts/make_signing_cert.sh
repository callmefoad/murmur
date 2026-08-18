#!/bin/bash
# Creates a self-signed code-signing certificate "Murmur Dev" in the
# login keychain, so rebuilds keep the same signature and macOS permission
# grants (Accessibility) survive. Idempotent.
set -euo pipefail

NAME="Murmur Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Signing identity '$NAME' already exists."
    exit 0
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

cat > cert.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -config cert.cnf

P12_PASS="$(openssl rand -hex 16)"

openssl pkcs12 -export -legacy -out identity.p12 \
    -inkey key.pem -in cert.pem -passout pass:"$P12_PASS" 2>/dev/null \
 || openssl pkcs12 -export -out identity.p12 \
    -inkey key.pem -in cert.pem -passout pass:"$P12_PASS"

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import identity.p12 -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security

# Mark the certificate trusted for code signing (may show an auth prompt).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" cert.pem

echo "Created signing identity '$NAME'."
