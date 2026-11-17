#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CLIENT="${1:-both}"
case "$CLIENT" in codex|claude|both) ;; *) echo 'Usage: install.sh [codex|claude|both]' >&2; exit 1;; esac
test -x 'dist/Desktop Deck.app/Contents/MacOS/DesktopDeck'
mkdir -p "$HOME/Applications"
ditto 'dist/Desktop Deck.app' "$HOME/Applications/Desktop Deck.app"
if [ "$CLIENT" = codex ] || [ "$CLIENT" = both ]; then
  codex plugin marketplace add "$PWD"
  codex plugin add desktop-deck@desktop-deck-local
fi
if [ "$CLIENT" = claude ] || [ "$CLIENT" = both ]; then
  claude plugin validate "$PWD/plugins/desktop-deck"
  claude plugin marketplace add "$PWD"
  claude plugin install desktop-deck@desktop-deck-local
fi
echo 'Installed. Open Desktop Deck, then use a new chat or the client’s supported plugin reload.'
