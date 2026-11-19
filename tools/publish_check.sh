#!/bin/bash
# Before a push or a release: what git would publish holds no game files, no generated code, nothing large, no secrets and no path
# of this Mac; LICENSE is there.   tools/publish_check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
bad() { echo "FAIL: $1"; fail=1; }
[ -f LICENSE ] || bad "no LICENSE"
FILES="$(git ls-files --cached --others --exclude-standard)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    engine/xboxrecomp/tools/conformance/test.xbe) ;;   # xboxrecomp's 4 KB synthetic test image (its mkxbe.py), no game code
    upstream/*|engine/gen/*|mirror/*|game/*|build/*|logs/*|.venv/*) bad "not ours to publish: $f" ;;
    *.iso|*.ISO|*.xbe|*.XBE|*.BIN|*.xmv|*.bundle|*.dmg) bad "a game or binary file: $f" ;;
    *recomp_[0-9][0-9][0-9][0-9].c|*recomp_dispatch.c|*recomp_stubs*.c) bad "generated code: $f" ;;
  esac
  [ -f "$f" ] || continue
  size=$(stat -f %z "$f")
  [ "$size" -le 2000000 ] || bad "larger than 2 MB: $f ($size bytes)"
  grep -qI "$HOME" "$f" 2>/dev/null && bad "this Mac's home path in $f"
  grep -qIE "(ghp_|github_pat_|sk-ant-|AKIA)[A-Za-z0-9_]{16,}|BEGIN (RSA|OPENSSH) PRIVATE KEY" "$f" 2>/dev/null && bad "a secret in $f"
done <<< "$FILES"
[ $fail -eq 0 ] && echo "publish_check: PASS ($(echo "$FILES" | wc -l | tr -d ' ') files)" || { echo "publish_check: FAILED"; exit 1; }
