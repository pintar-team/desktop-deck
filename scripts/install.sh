#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CLIENT="${1:-both}"
case "$CLIENT" in codex|claude|both) ;; *) echo 'Usage: install.sh [codex|claude|both]' >&2; exit 1;; esac
if [ -x 'dist/Desktop Deck.app/Contents/MacOS/DesktopDeck' ]; then
  mkdir -p "$HOME/Applications"
  ditto 'dist/Desktop Deck.app' "$HOME/Applications/Desktop Deck.app"
elif [ ! -x "$HOME/Applications/Desktop Deck.app/Contents/MacOS/DesktopDeck" ] && [ ! -x '/Applications/Desktop Deck.app/Contents/MacOS/DesktopDeck' ]; then
  echo 'Install Desktop Deck.app from GitHub Releases or build it first.' >&2
  exit 1
fi
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
