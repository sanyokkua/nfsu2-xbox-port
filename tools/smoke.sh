#!/bin/bash
# Boot gate: runs the build for N seconds in a throwaway HOME on an APFS clone of the disc, START pressed
# every 2.5 s, the settings menu opened and closed at 20 s, Metal frame dumps every 600 frames. Passes when the game exits by the smoke timer (no crash)
# and the last dump is not black.   tools/smoke.sh [seconds=75] [binary]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS="${1:-75}"; BIN="${2:-$ROOT/build/release/nfsu2_recomp}"
T="$(mktemp -d "${TMPDIR:-/tmp}/nfsu2-smoke.XXXXXX")"
mkdir -p "$T/home" "$T/dump"; cp -c -R "$ROOT/game/extracted" "$T/game"
( cd "$T/home" && HOME="$T/home" NFSU2_GAME_DIR="$T/game" NFSU2_SMOKE_SECONDS="$SECS" \
  RECOMP_PAD_PRESS=0x10,2500,200 RECOMP_GL_DUMP="$T/dump/m,600" NFSU2_OVERLAY_SCRIPT="20:open,20.5:next,21:down,21.5:close" "$BIN" > "$T/run.log" 2>&1 ) || true
grep -q "smoke time limit reached" "$T/run.log" || { echo "smoke: FAIL (no clean exit) — $T/run.log"; tail -20 "$T/run.log"; exit 1; }
LAST="$(find "$T/dump" -name 'm?????.bmp' | sort | tail -1)"
[[ -n "$LAST" ]] || { echo "smoke: FAIL (no frame dumps)"; exit 1; }
MEAN="$(python3 -I -c 'import sys;d=open(sys.argv[1],"rb").read()[54:];print(sum(d[::97])//max(1,len(d[::97])))' "$LAST")"
[[ "$MEAN" -gt 8 ]] || { echo "smoke: FAIL (last frame black, mean $MEAN) — $LAST"; exit 1; }
echo "smoke: OK ${SECS}s, $(find "$T/dump" -name 'm?????.bmp' | wc -l | tr -d ' ') frames, last mean $MEAN ($T)"
