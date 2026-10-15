#!/bin/bash
# Crée le certificat local de signature « Prism Dev » dans le trousseau de session.
# Prism, signé avec lui par scripts/build.sh, garde ses autorisations (Accessibilité, Enregistrement de l'écran…)
# d'un build à l'autre, au lieu de les perdre à chaque signature ad hoc.
set -euo pipefail
if security find-certificate -c "Prism Dev" >/dev/null 2>&1; then
  echo "Le certificat « Prism Dev » existe déjà."
  exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = Prism Dev
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 -nodes -config "$WORK/cert.cnf" -extensions ext 2>/dev/null
PASS="$(openssl rand -hex 12)"
# Le trousseau de macOS ne lit que l'ancien format PKCS#12 (3DES, MAC SHA-1).
LEGACY=()
openssl version | grep -q "^OpenSSL 3" && LEGACY=(-legacy)
openssl pkcs12 -export "${LEGACY[@]}" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/prism.p12" -passout "pass:$PASS" -name "Prism Dev"
security import "$WORK/prism.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "✓ Certificat « Prism Dev » créé : relancez scripts/build.sh, puis autorisez Prism une dernière fois."
