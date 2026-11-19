#!/bin/bash
# The players' DMG holds no game code and no game data. Fails on:
#   - the disc's files by name (*.xbe, *.BIN, *.xmv, NFSUNDER, B3) or *.iso
#   - the lifted C or objects made from it (recomp_*.c but the engine's hand-written recomp_manual.c, recomp_*.o,
#     recomp_dispatch*) or a game binary (nfsu2)
#   - a file with more than 150 distinct lifted function names (sub_XXXXXXXX; a lifted chunk has ~250-400, recomp_manual.c 77): generated code under another name
#   - any file with the SHA-1 of a file on the disc of 64 bytes or more (game/extracted, when it is there)
#   - two or more of 64 64-byte windows of default.xbe's executable sections in one file
#   - this Mac's home folder path (the builder's)
# Adapted from the HP2 port's test (itself from NFSU2Deadware's, MIT).   tests/dmg_no_game_code.sh <dmg>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$1"; MNT="$(mktemp -d "${TMPDIR:-/tmp}/nfsu2dmg.XXXXXX")"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
trap 'hdiutil detach -quiet "$MNT"; rmdir "$MNT"' EXIT
fail=0
bad() { echo "FAIL: $1"; fail=1; }
while IFS= read -r f; do bad "a game file by name: ${f#$MNT/}"; done < <(find "$MNT" \( -iname '*.xbe' -o -iname '*.BIN' \
  -o -iname '*.xmv' -o -iname NFSUNDER -o -iname B3 -o -iname '*.iso' -o \( -name 'recomp_*.c' -not -name recomp_manual.c \) -o -name 'recomp_*.o' \
  -o -name 'recomp_dispatch*' -o -name nfsu2 \) -not -path '*/Applications/*')
GAME="$ROOT/game/extracted"
python3 -I - "$MNT" "$GAME" <<'PY' || fail=1
import hashlib, os, re, struct, sys
mnt, game = sys.argv[1], sys.argv[2]
def files(top):
    for d, dirs, names in os.walk(top):
        if d.startswith(os.path.join(mnt, 'Applications')): continue
        for n in names:
            p = os.path.join(d, n)
            if os.path.isfile(p) and not os.path.islink(p): yield p
bad = 0
sub = re.compile(rb'sub_[0-9A-F]{8}')
for p in files(mnt):
    n = len(set(sub.findall(open(p, 'rb').read())))
    if n > 150:
        print('FAIL: %d lifted function names in %s' % (n, p[len(mnt):])); bad = 1
if os.path.isdir(game):
    disc = set()
    for p in files(game):
        if 64 <= os.path.getsize(p) < 512 * 1024 * 1024:   # tiny files (empty ones) say nothing
            disc.add(hashlib.sha1(open(p, 'rb').read()).hexdigest())
    xbe = open(os.path.join(game, 'default.xbe'), 'rb').read()
    base = struct.unpack_from('<I', xbe, 0x104)[0]
    n, addr = struct.unpack_from('<II', xbe, 0x11C)
    code = b''
    for i in range(n):
        flags, _, _, raw, size = struct.unpack_from('<IIIII', xbe, addr - base + i * 56)
        if flags & 4:                              # executable section
            code += xbe[raw:raw + size]
    windows = [code[i:i + 64] for i in range(0, len(code) - 64, len(code) // 64)][:64]
    for p in files(mnt):
        data = open(p, 'rb').read()
        if hashlib.sha1(data).hexdigest() in disc:
            print('FAIL: a file of the disc:', p[len(mnt):]); bad = 1
        hits = sum(1 for w in windows if w in data)
        if hits >= 2:
            print('FAIL: %d windows of the program\'s code in %s' % (hits, p[len(mnt):])); bad = 1
    print('checked: %d disc files, %d code windows (%d KB of executable sections)' % (len(disc), len(windows), len(code) // 1024))
else:
    print('note: no game/extracted here: the SHA-1 and code-window checks were skipped')
home = os.path.expanduser('~').encode()
for p in files(mnt):
    if home in open(p, 'rb').read():
        print('FAIL: this Mac\'s home path in', p[len(mnt):]); bad = 1
sys.exit(bad)
PY
[ $fail -eq 0 ] && echo "dmg_no_game_code: PASS ($DMG)" || { echo "dmg_no_game_code: FAILED"; exit 1; }
