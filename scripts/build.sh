#!/bin/bash
# Construit dist/Prism.app : binaire optimisé pour l'architecture du Mac (ou universel avec --universal), icône, signature.
set -euo pipefail
cd "$(dirname "$0")/.."

# Sans licence Xcode acceptée, les Command Line Tools suffisent.
if [ -z "${DEVELOPER_DIR:-}" ] && ! swift --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

# --universal : un binaire pour Apple silicon et Intel, celui des releases.
if [ "${1:-}" = "--universal" ]; then
  for ARCH in arm64 x86_64; do swift build -c release --triple "$ARCH-apple-macosx14.0"; done
  BIN=".build/Prism-universal"
  lipo -create -output "$BIN" \
    "$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)/Prism" \
    "$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/Prism"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/Prism"
fi

APP="dist/Prism.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Prism"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# L'hôte des extensions Raycast : un seul fichier JavaScript (React et l'API compris), construit par esbuild.
if [ -d RaycastHost/node_modules ] && command -v node >/dev/null 2>&1; then
  (cd RaycastHost && npm run build --silent)
fi
if [ -f RaycastHost/dist/host.js ]; then
  mkdir -p "$APP/Contents/Resources/RaycastHost"
  cp RaycastHost/dist/host.js "$APP/Contents/Resources/RaycastHost/host.js"
else
  echo "⚠︎ RaycastHost/dist/host.js absent : lancez « cd RaycastHost && npm install && npm run build »" >&2
fi

ICONSET=".build/Prism.iconset"
rm -rf "$ICONSET"
"$BIN" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Signature stable avec le certificat local « Prism Dev » (scripts/create-signing-certificate.sh) : macOS garde
# alors les autorisations (Accessibilité…) d'un build à l'autre. Sans lui, signature ad hoc.
if security find-certificate -c "Prism Dev" >/dev/null 2>&1; then
  codesign --force --sign "Prism Dev" --identifier app.prism.launcher "$APP"
else
  codesign --force --sign - --identifier app.prism.launcher "$APP"
fi
echo "✓ $APP"
