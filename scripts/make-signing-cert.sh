#!/bin/sh
# Makes the self-signed code-signing certificate that releases are signed with, keeps a copy
# outside the repo, and stores it as the GitHub Actions secrets SIGNING_P12_BASE64 and
# SIGNING_P12_PASSWORD (needs gh, logged in). Run once.
#   scripts/make-signing-cert.sh [backup dir]     default ~/jdsp4mac-signing
#
# Every release must be signed with the same certificate: it is the app's identity. A new one
# makes macOS ask for the recording permission again and makes the in-app updater refuse the
# release, so keep the backup (a password manager is a good place for the .p12 and password).
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
DIR=${1:-$HOME/jdsp4mac-signing}
OPENSSL=/usr/bin/openssl  # LibreSSL: its .p12 files import with `security`

if [ -e "$DIR/jdsp4mac.p12" ]; then
    echo "$DIR/jdsp4mac.p12 already exists. Replacing it would change the app's identity; not doing that."
    echo "To store the existing one as secrets again:"
    echo "  base64 -i \"$DIR/jdsp4mac.p12\" | gh secret set SIGNING_P12_BASE64"
    echo "  printf %s \"\$(cat '$DIR/password.txt')\" | gh secret set SIGNING_P12_PASSWORD"
    exit 1
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = jdsp4mac
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
$OPENSSL req -x509 -newkey rsa:3072 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 7300 -config "$TMP/cert.cnf" 2>/dev/null
$OPENSSL rand -hex 24 > "$DIR/password.txt"
$OPENSSL pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name jdsp4mac \
    -out "$DIR/jdsp4mac.p12" -passout file:"$DIR/password.txt"
chmod 600 "$DIR/jdsp4mac.p12" "$DIR/password.txt"

cd "$REPO"
base64 -i "$DIR/jdsp4mac.p12" | gh secret set SIGNING_P12_BASE64
printf %s "$(cat "$DIR/password.txt")" | gh secret set SIGNING_P12_PASSWORD

echo
echo "Certificate: CN=jdsp4mac, valid 20 years, SHA-1 $($OPENSSL x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)"
echo "Saved to $DIR (jdsp4mac.p12 and password.txt). Back both up; the secrets cannot be read back."
echo "GitHub secrets SIGNING_P12_BASE64 and SIGNING_P12_PASSWORD are set."
