#!/bin/zsh
# Create a self-signed "Kolom Local Signing" code-signing identity in the login
# keychain. build-app.sh signs with it when present, which gives every build the
# same designated requirement (bundle identifier + certificate), so macOS keeps
# Kolom's window-control permission across rebuilds. Ad-hoc builds are
# identified by cdhash and lose the permission on every rebuild.
#
# After the first build signed this way, grant Kolom window-control access
# once more; later rebuilds keep it. This is for local development only. It is
# not Developer ID signing or notarization.
#
# Remove later with: security delete-identity -c "Kolom Local Signing"
set -euo pipefail
NAME="Kolom Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  print "$NAME already exists."
  exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# LibreSSL in /usr/bin writes PKCS#12 algorithms that security(1) can import.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" \
  -passout "pass:$PASSWORD" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
print "Created $NAME. Rebuild with scripts/build-app.sh, then grant access once."
