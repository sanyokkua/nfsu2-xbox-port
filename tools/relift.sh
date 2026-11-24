#!/bin/bash
# Full lift (seeds changed) + stub check + incremental release build (tools/build_release.sh configures it first).
# Logs in build/regen.log, build/stubcheck.log, build/build.log. From the hpcos-xbox-port.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
export PATH="$ROOT/.venv/bin:/opt/homebrew/bin:$PATH"
NFSU2_XBE="$ROOT/game/extracted/default.xbe" NFSU2_GEN_DIR="$ROOT/engine/gen" \
  bash engine/tools/regen.sh > build/regen.log 2>&1 || { tail -20 build/regen.log; exit 1; }
grep -E "Translating|unresolved" build/regen.log || true
python3 tools/stubcheck.py > build/stubcheck.log 2>&1 || { tail -12 build/stubcheck.log; exit 1; }   # a real-code stub is a silent bug
tail -1 build/stubcheck.log
cmake --build build/release > build/build.log 2>&1 || { grep -E "error" build/build.log | head; exit 1; }
echo "build OK"
