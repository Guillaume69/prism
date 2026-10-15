#!/bin/bash
# Vérifie de bout en bout ce qui intercepte le clavier : l'expansion des snippets, la touche Hyper
# et les doubles frappes, par de vraies frappes système envoyées par le pont d'essai.
# Prérequis : Prism autorisé dans Réglages Système › Confidentialité et sécurité › Accessibilité.
# Les réglages de l'utilisateur (commandes, snippets, touche Hyper) sont sauvegardés puis rendus.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${PRISM_APP:-/Applications/Prism.app}"
BIN="$APP/Contents/MacOS/Prism"
DATA="$HOME/Library/Application Support/Prism"
TMP="$(mktemp -d)"
cp "$DATA/commands.json" "$TMP/commands.json" 2>/dev/null || true
cp "$DATA/snippets.json" "$TMP/snippets.json" 2>/dev/null || true
HYPER_KEY="$(defaults read app.prism.launcher hyper.key 2>/dev/null || echo "")"

restore() {
  pkill -x Prism 2>/dev/null || true
  sleep 0.8
  if [ -f "$TMP/commands.json" ]; then cp "$TMP/commands.json" "$DATA/commands.json"; else rm -f "${DATA:?}/commands.json"; fi
  if [ -f "$TMP/snippets.json" ]; then cp "$TMP/snippets.json" "$DATA/snippets.json"; else rm -f "${DATA:?}/snippets.json"; fi
  if [ -n "$HYPER_KEY" ]; then defaults write app.prism.launcher hyper.key "$HYPER_KEY"; else defaults delete app.prism.launcher hyper.key 2>/dev/null || true; fi
  [ -n "${OPENED:-}" ] && osascript -e 'tell application "TextEdit" to close document 1 saving no' >/dev/null 2>&1 || true
  rm -rf "$TMP"
  open "$APP"
}
trap restore EXIT

state() { "$BIN" --debug dump "$TMP/state.json"; sleep 0.4; python3 -c "import json;print(json.load(open('$TMP/state.json'))['$1'])"; }

echo "→ Réglages d'essai : snippet « ;prismtest », Hyper (F18) + E → emojis, ⌃⌃ → historique des dictées"
pkill -x Prism 2>/dev/null || true
sleep 0.8
python3 - "$DATA" <<'PY'
import json, os, sys, uuid
data = sys.argv[1]
path = os.path.join(data, "commands.json")
content = json.load(open(path)) if os.path.exists(path) else {"commands": {}, "favorites": [], "disabledFallbacks": [], "fallbackOrder": []}
commands = content.setdefault("commands", {})
# ⌃⌥⌘E (Carbon : cmdKey 256, optionKey 2048, controlKey 4096) et double ⌃ (0x10000 + 3).
commands["command:emoji"] = {**commands.get("command:emoji", {}), "hotkey": {"keyCode": 14, "modifiers": 6400}, "disabled": False}
commands["command:dictation.history"] = {**commands.get("command:dictation.history", {}), "hotkey": {"keyCode": 65539, "modifiers": 0}, "disabled": False}
json.dump(content, open(path, "w"), indent=2)
path = os.path.join(data, "snippets.json")
snippets = json.load(open(path)) if os.path.exists(path) else []
snippets.append({"id": str(uuid.uuid4()).upper(), "name": "Essai Prism", "text": "Bonjour depuis Prism", "keyword": ";prismtest",
                 "tags": [], "isPinned": False, "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z"})
json.dump(snippets, open(path, "w"), indent=2)
PY
defaults write app.prism.launcher hyper.key f18
open --env PRISM_DEBUG=1 "$APP"
sleep 3

if [ "$(state accessibilityTrusted)" != "True" ]; then
  echo "✗ Prism n'a pas l'autorisation d'accessibilité."
  exit 1
fi
echo "✓ Accessibilité accordée"

echo "→ Document TextEdit d'essai"
osascript -e 'tell application "TextEdit" to activate' -e 'tell application "TextEdit" to make new document' >/dev/null
OPENED=1
sleep 1.2

echo "→ Frappe de « ;prismtest » dans TextEdit"
"$BIN" --debug systype ";prismtest"
sleep 1.5
TEXT="$(osascript -e 'tell application "TextEdit" to get text of document 1')"
if [ "$TEXT" = "Bonjour depuis Prism" ]; then echo "✓ Snippet développé : $TEXT"; else echo "✗ Texte du document : « $TEXT » (attendu : Bonjour depuis Prism)"; FAIL=1; fi

echo "→ Hyper (F18 maintenue) + E"
"$BIN" --debug syskey 79 "" down; sleep 0.1
"$BIN" --debug syskey 14 "" press; sleep 0.1
"$BIN" --debug syskey 79 "" up; sleep 1.2
if [ "$(state visible)" = "True" ] && [ "$(state screen)" = "emoji" ]; then echo "✓ Hyper + E a ouvert les emojis"; else echo "✗ Hyper + E : lanceur $(state visible), écran $(state screen)"; FAIL=1; fi
"$BIN" --debug key 53; sleep 0.3; "$BIN" --debug key 53; sleep 0.5
osascript -e 'tell application "TextEdit" to activate' >/dev/null; sleep 0.8

echo "→ Double appui sur ⌃"
for _ in 1 2; do
  "$BIN" --debug sysflags 59 ctrl; sleep 0.06
  "$BIN" --debug sysflags 59 ""; sleep 0.12
done
sleep 1.2
if [ "$(state visible)" = "True" ] && [ "$(state screen)" = "dictation.history" ]; then echo "✓ ⌃⌃ a ouvert l'historique des dictées"; else echo "✗ ⌃⌃ : lanceur $(state visible), écran $(state screen)"; FAIL=1; fi
"$BIN" --debug key 53; sleep 0.3; "$BIN" --debug key 53

echo "→ Nettoyage"
[ -z "${FAIL:-}" ] && echo "Tout fonctionne." || { echo "Échec."; exit 1; }
