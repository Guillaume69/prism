#!/bin/bash
# Prépare une release : Prism.app universel (Apple silicon et Intel), hôte des extensions compris, compressé avec ditto,
# et son empreinte SHA-256. Les deux fichiers sont dans dist/, prêts pour « gh release create ».
set -euo pipefail
cd "$(dirname "$0")/.."

(cd RaycastHost && npm ci --silent)
./scripts/build.sh --universal
[ -f dist/Prism.app/Contents/Resources/RaycastHost/host.js ] || { echo "✗ hôte des extensions absent du paquet" >&2; exit 1; }
lipo dist/Prism.app/Contents/MacOS/Prism -verify_arch arm64 x86_64

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ZIP="Prism-$VERSION.zip"
rm -f "dist/$ZIP" "dist/$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent dist/Prism.app "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")
echo "✓ dist/$ZIP"
cat "dist/$ZIP.sha256"
