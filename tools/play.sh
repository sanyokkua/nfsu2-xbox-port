#!/bin/bash
# Dev play-test: runs the build with a persistent player folder (own HOME, an APFS clone of the disc that also
# holds the game's saves) in ~/Library/Application Support/NFS Underground 2/dev. Log: <that>/logs/last.log.
# Extra env (e.g. NFSU2_FPS_CAP=120) passes through.   tools/play.sh [binary]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/build/release/nfsu2_recomp}"
P="$HOME/Library/Application Support/NFS Underground 2/dev"
mkdir -p "$P/home" "$P/logs"
[[ -f "$P/game/default.xbe" ]] || cp -c -R "$ROOT/game/extracted" "$P/game"
cd "$P/logs"
HOME="$P/home" NFSU2_GAME_DIR="$P/game" exec "$BIN" > "$P/logs/last.log" 2>&1
