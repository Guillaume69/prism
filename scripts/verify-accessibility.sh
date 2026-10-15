#!/bin/bash
# Vérifie de bout en bout ce qui demande l'autorisation d'accessibilité :
# coller dans l'app active et ranger sa fenêtre, sur un document TextEdit d'essai.
# Prérequis : Prism autorisé dans Réglages Système › Confidentialité et sécurité › Accessibilité.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${PRISM_APP:-/Applications/Prism.app}"
BIN="$APP/Contents/MacOS/Prism"
TMP="$(mktemp -d)"
pbpaste > "$TMP/clipboard.txt" 2>/dev/null || true

# Quoi qu'il arrive : presse-papiers rendu, Prism relancé normalement, sans le pont d'essai.
restore() {
  pbcopy < "$TMP/clipboard.txt" 2>/dev/null || true
  rm -rf "$TMP"
  pkill -x Prism 2>/dev/null || true
  sleep 0.8
  open "$APP"
}
trap restore EXIT

state() { "$BIN" --debug dump "$TMP/state.json"; sleep 0.4; python3 -c "import json;print(json.load(open('$TMP/state.json'))['$1'])"; }

echo "→ Relance de Prism avec le pont d'essai"
pkill -x Prism 2>/dev/null || true
sleep 0.8
open --env PRISM_DEBUG=1 "$APP"
# Attendre que Prism réponde au pont d'essai (une app signée met un peu plus de temps à démarrer).
for _ in $(seq 1 20); do
  sleep 0.5
  rm -f "$TMP/state.json"
  "$BIN" --debug dump "$TMP/state.json"; sleep 0.3
  [ -s "$TMP/state.json" ] && break
done
sleep 1

if [ "$(state accessibilityTrusted)" != "True" ]; then
  echo "✗ Prism n'a pas l'autorisation d'accessibilité."
  echo "  Réglages Système › Confidentialité et sécurité › Accessibilité : activez Prism, puis relancez ce script."
  exit 1
fi
echo "✓ Accessibilité accordée"

echo "→ Document TextEdit d'essai"
osascript -e 'tell application "TextEdit" to activate' -e 'tell application "TextEdit" to make new document' >/dev/null
sleep 1

echo "→ ⌥Espace, « 7*6 », ⌘↵ (coller le résultat)"
"$BIN" --debug hotkey; sleep 0.5
"$BIN" --debug type "7*6"; sleep 0.4
"$BIN" --debug key 36 cmd; sleep 1.2
TEXT="$(osascript -e 'tell application "TextEdit" to get text of document 1')"
if [ "$TEXT" = "42" ]; then echo "✓ Collé dans TextEdit : $TEXT"; else echo "✗ Texte du document : « $TEXT » (attendu : 42)"; FAIL=1; fi

echo "→ ⌥Espace, « moitie gauche », ↵"
"$BIN" --debug hotkey; sleep 0.5
"$BIN" --debug key 0 cmd; "$BIN" --debug type "moitie gauche"; sleep 0.4
"$BIN" --debug key 36; sleep 1
BOUNDS="$(osascript -e 'tell application "TextEdit" to get bounds of window 1')"
# Moitié gauche attendue de l'écran qui contient la fenêtre, dans le repère d'AppleScript
# (origine en haut à gauche de l'écran principal).
EXPECTED="$(osascript -l JavaScript - "$BOUNDS" <<'JS'
ObjC.import("AppKit")
function run(argv) {
  const [l, t, r, b] = argv[0].split(",").map(Number)
  const screens = $.NSScreen.screens.js
  const primaryHeight = screens[0].frame.size.height
  const cx = (l + r) / 2, cy = primaryHeight - (t + b) / 2
  const screen = screens.find(s => {
    const f = s.frame
    return cx >= f.origin.x && cx <= f.origin.x + f.size.width && cy >= f.origin.y && cy <= f.origin.y + f.size.height
  }) || screens[0]
  const v = screen.visibleFrame
  const top = primaryHeight - (v.origin.y + v.size.height)
  return [v.origin.x, top, v.origin.x + Math.floor(v.size.width / 2), top + v.size.height].join(",")
}
JS
)"
# Le haut peut descendre sous la barre des menus d'un écran secondaire, que macOS ne déclare pas toujours.
if python3 -c "
import sys
got = [int(x) for x in '$BOUNDS'.replace(' ', '').split(',')]
want = [float(x) for x in '$EXPECTED'.split(',')]
sides = all(abs(got[i] - want[i]) <= 2 for i in (0, 2, 3))
top = abs(got[1] - want[1]) <= 2 or 0 < got[1] - want[1] <= 60
sys.exit(0 if sides and top else 1)
"; then
  echo "✓ Fenêtre rangée à gauche : $BOUNDS (attendu $EXPECTED, à 2 pt près)"
else
  echo "✗ Fenêtre : $BOUNDS, attendu $EXPECTED"; FAIL=1
fi

echo "→ Moitié haute puis moitié basse : elles se touchent sans se chevaucher"
place() { "$BIN" --debug hotkey; sleep 0.5; "$BIN" --debug key 0 cmd; "$BIN" --debug type "$1"; sleep 0.4; "$BIN" --debug key 36; sleep 1; osascript -e 'tell application "TextEdit" to get bounds of window 1'; }
TOP="$(place "moitie haute")"
BOTTOM="$(place "moitie basse")"
if python3 -c "
import sys
t = [int(x) for x in '$TOP'.replace(' ', '').split(',')]
b = [int(x) for x in '$BOTTOM'.replace(' ', '').split(',')]
sys.exit(0 if abs(t[3] - b[1]) <= 2 and t[0] == b[0] and t[2] == b[2] else 1)
"; then
  echo "✓ Moitiés jointives : haute $TOP, basse $BOTTOM"
else
  echo "✗ Moitiés : haute $TOP, basse $BOTTOM"; FAIL=1
fi

echo "→ Nettoyage"
osascript -e 'tell application "TextEdit" to close document 1 saving no' >/dev/null
[ -z "${FAIL:-}" ] && echo "Tout fonctionne." || { echo "Échec."; exit 1; }
