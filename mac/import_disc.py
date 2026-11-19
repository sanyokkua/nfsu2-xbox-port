#!/usr/bin/env python3
"""The installer's disc import: the player's own disc image into the game folder.

    python3 -I import_disc.py <disc image> <game dir>

Extracts the XDVDFS image (xiso.py) into <game dir>.part, checks default.xbe, then renames it to <game dir>. The port is
lifted from the USA executable (SHA-1 below); runtime overrides are at its addresses, so another one cannot run.
Exit 0 = done; 3 = not an Xbox disc; 4 = an Xbox game, not NFS Underground 2; 5 = NFS Underground 2, another edition.
Adapted from NFSU2Deadware's tools/dmg/import_disc.py (MIT, LeoDeadware).
"""
import hashlib
import os
import shutil
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xiso  # noqa: E402

XBE_SHA1 = "428b5a70b9400f19cc5be7679db6c72a6f80a1c9"   # Need for Speed Underground 2 (USA), default.xbe
TITLE_ID = 0x4541005A                                      # NFSU2, every edition
REGIONS = {1: "USA", 2: "Japan", 4: "Europe"}


def certificate(data):
    """(title ID, region name) from the XBE certificate, or (None, None)."""
    try:
        base = struct.unpack_from("<I", data, 0x104)[0]
        o = struct.unpack_from("<I", data, 0x118)[0] - base
        tid = struct.unpack_from("<I", data, o + 8)[0]
        reg = struct.unpack_from("<I", data, o + 0xA0)[0]
    except struct.error:
        return None, None
    names = [n for bit, n in REGIONS.items() if reg & bit]
    return tid, "+".join(names) or "region %#x" % reg


def main():
    iso, dest = sys.argv[1], sys.argv[2]
    tmp = dest + ".part"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    print("import: %s -> %s" % (iso, dest), flush=True)
    try:
        xiso.extract(iso, tmp, log=lambda *a: print("import:", *a, flush=True))
    except ValueError:
        shutil.rmtree(tmp, ignore_errors=True)
        print("import: not an Xbox disc image", flush=True)
        return 3
    xbe = os.path.join(tmp, "default.xbe")
    if not os.path.isfile(xbe):
        shutil.rmtree(tmp, ignore_errors=True)
        print("import: no default.xbe: not an Xbox game", flush=True)
        return 3
    with open(xbe, "rb") as f:
        data = f.read()
    sha = hashlib.sha1(data).hexdigest()
    if sha != XBE_SHA1:
        shutil.rmtree(tmp, ignore_errors=True)
        tid, region = certificate(data)
        if tid == TITLE_ID:
            print("import: default.xbe %s: NFS Underground 2 (%s), another edition" % (sha, region), flush=True)
            return 5
        print("import: default.xbe %s: not NFS Underground 2" % sha, flush=True)
        return 4
    shutil.rmtree(dest, ignore_errors=True)
    os.rename(tmp, dest)
    print("import: done, default.xbe %s" % sha, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
