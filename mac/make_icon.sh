#!/bin/bash
# mac/make_icon.sh <default.xbe> <out.icns>: the app icon from the disc's title image (the XBE's $$XTIMAGE), made on the
# player's Mac at install time (the image is the disc's: never in this repository or the DMG). squircle fits the round Xbox
# art into the macOS icon grid. Adapted from NFSU2Deadware's tools/icon/make_icns.sh (MIT, LeoDeadware).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
XBE="$1"; OUT="$2"
T="$(mktemp -d "${TMPDIR:-/tmp}/nfsu2-icon.XXXXXX")"; trap 'rm -rf "$T"' EXIT
/usr/bin/python3 -I "$HERE/icon/xbe_title_image.py" "$XBE" "$T/title.png" >/dev/null
if [[ -x "$HERE/icon/squircle" ]]; then "$HERE/icon/squircle" "$T/title.png" "$T/sq.png"
else swift "$HERE/icon/squircle.swift" "$T/title.png" "$T/sq.png"; fi
mkdir -p "$T/i.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/sq.png" --out "$T/i.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$T/sq.png" --out "$T/i.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$OUT" "$T/i.iconset"
