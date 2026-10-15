#!/bin/bash
# Construit Prism, le copie dans /Applications (ou ~/Applications) et le lance.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

pkill -x Prism 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/Prism.app"
cp -R dist/Prism.app "$DEST/Prism.app"
open "$DEST/Prism.app"
echo "✓ Prism installé dans $DEST et lancé"
