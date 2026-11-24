#!/usr/bin/env python3
"""Is a VA a safe seed? tools/seedcheck.py <va> ...  (.venv: capstone)
Prints the byte before it, its first instructions, and the lifted function it falls inside (a seed inside one splits it:
fine only after padding or a ret, never inside an instruction)."""
import bisect, json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from sigmatch import load, read
from capstone import Cs, CS_ARCH_X86, CS_MODE_32
R = os.path.join(os.path.dirname(__file__), "..")
secs = load(os.path.join(R, "game/extracted/default.xbe"))
fs = json.load(open(os.path.join(R, "engine/xboxrecomp/tools/disasm/output/functions.json")))
rng = sorted((int(f["start"], 16), int(f["end"], 16)) for f in fs); starts = [r[0] for r in rng]
md = Cs(CS_ARCH_X86, CS_MODE_32)
for a in (int(x, 16) for x in sys.argv[1:]):
    i = bisect.bisect_right(starts, a) - 1
    inside = i >= 0 and rng[i][0] <= a < rng[i][1]
    prev = read(secs, a - 1, 1)
    ins = [f"{x.mnemonic} {x.op_str}" for x, _ in zip(md.disasm(read(secs, a, 32) or b"", a), range(3))]
    print(f"{a:#x}: prev={prev.hex() if prev else None} {'START' if inside and rng[i][0]==a else ('inside %#x-%#x' % rng[i] if inside else 'free')} | {' ; '.join(ins)}")
