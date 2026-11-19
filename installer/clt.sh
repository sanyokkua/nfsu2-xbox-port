#!/bin/bash
# Apple's Command Line Tools (clang, python3, make, git): present -> exit 0. Missing -> the system's install dialog, then wait until
# clang is there (NFSU2_CLT_WAIT seconds, default 3600); still missing -> exit 1. Progress lines "N text" go to $1.
# Adapted from NFSU2Deadware's tools/dmg/clt.sh (MIT).
PROG="${1:-/dev/null}"
clt_ok() { xcode-select -p >/dev/null 2>&1 && xcrun -f clang++ >/dev/null 2>&1 && [ -x /usr/bin/python3 ] && /usr/bin/python3 -c '' 2>/dev/null; }
clt_ok && exit 0
echo "1 Install Apple's Command Line Tools in the system dialog; the installer waits" >> "$PROG"
xcode-select --install >/dev/null 2>&1
[ -n "${NFSU2_NO_UI:-}" ] || /usr/bin/osascript -e 'display dialog "NFS Underground 2 is built on your Mac with Apple'"'"'s Command Line Tools. Click Install in the system dialog; the installer goes on by itself when they are there." buttons {"OK"} default button "OK" with title "NFS Underground 2"' >/dev/null 2>&1 &
waited=0
until clt_ok; do
  if (( waited >= ${NFSU2_CLT_WAIT:-3600} )); then
    echo "100 ERROR: Apple's Command Line Tools are not installed (Terminal: xcode-select --install)" >> "$PROG"
    exit 1
  fi
  sleep 5; waited=$((waited + 5))
done
