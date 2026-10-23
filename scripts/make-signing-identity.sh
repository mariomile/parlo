#!/bin/zsh
# Creates a self-signed "Parlo Development" code-signing identity in the login keychain.
# Ad-hoc signatures change on every build, so macOS forgets privacy permissions after each rebuild;
# a fixed certificate keeps them. Safe to rerun: does nothing if the identity exists.
set -euo pipefail
NAME="Parlo Development"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then exit 0; fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/key.pem" -out "$dir/cert.pem" -days 3650 -config "$dir/cert.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/id.p12" -passout pass:parlo 2>/dev/null
security import "$dir/id.p12" -k ~/Library/Keychains/login.keychain-db -P parlo -T /usr/bin/codesign >/dev/null
echo "Created signing identity \"$NAME\""
