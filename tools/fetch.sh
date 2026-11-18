#!/bin/bash
# upstream/ = myUdav4iik/nfsu2-ios (branch ios) at BASE + patches/*.patch (git am).
# The base is not ours and is not copied into this repo. mirror/nfsu2-ios.bundle (local) is the fallback.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL=https://github.com/myUdav4iik/nfsu2-ios.git
BASE=85d2cbf
D="$ROOT/upstream"
[[ -e "$D" ]] && { echo "upstream/ exists; remove it to fetch again"; exit 1; }
if ! git clone -q -b ios "$URL" "$D" 2>/dev/null; then
  [[ -f "$ROOT/mirror/nfsu2-ios.bundle" ]] || { echo "fetch: clone failed and no mirror bundle"; exit 1; }
  git clone -q "$ROOT/mirror/nfsu2-ios.bundle" "$D"
fi
git -C "$D" checkout -q -B clean "$BASE"
git -C "$D" -c user.name=build -c user.email=build@localhost am -q "$ROOT"/patches/*.patch
echo "upstream/ = nfsu2-ios $BASE + $(ls "$ROOT"/patches/*.patch | wc -l | tr -d ' ') patches ($(git -C "$D" rev-parse --short HEAD))"
