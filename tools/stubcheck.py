#!/usr/bin/env python3
"""Are any of the lifter's stubs real code?   tools/stubcheck.py   (.venv: capstone; after a full lift)

engine/gen/recomp_stubs_unresolved.c gives every direct call or jump target the disassembler did not detect as a
function an empty body (`g_esp += 4`, a bare ret, or `+= 4 + N` for a target ending in `ret N`). For bytes the
lifter decoded out of alignment that is harmless: nothing reaches them. For a real instruction start -- typically a
function's shared exit (`pop esi; pop ebp; pop edi; ret`) that another path jumps to -- it is a silent bug: the pops
never happen and the caller gets its registers and stack back wrong (Chamber of Secrets: a pick-up tail-jumped to such
an exit, the entity update's loop registers became pointers, the game froze). Each stub is classed:
  BOUNDARY  an instruction start inside a detected function: real code, seed it (tools/addseed.py)
  code      outside every function but in a code section: real code, seed it
  mid-insn  inside an instruction of a detected function: a misdecode, harmless
  data      outside the code sections: harmless
  table     reviewed: reached only from data the sweep decoded as code (TABLE below)
  pad       int3 padding: a misdecoded caller (a jump table read as code); the console would trap there too
Exits 1 when any stub is real code. Seeding one can split a function and turn its internal jumps into new stubs:
relift (tools/relift.sh) and run this again until it passes. From the hpcos-xbox-port (GPL-3.0-or-later)."""
import bisect, glob, json, os, re, struct, sys
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

R = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
XBE = os.environ.get("NFSU2_XBE", os.path.join(R, "game/extracted/default.xbe"))
GEN = os.environ.get("NFSU2_GEN_DIR", os.path.join(R, "engine/gen"))
# Reviewed stubs that are instruction starts but are only referenced from data walked as code.
TABLE = {0x00257295: "a jb decoded from the jump table at 0x00257270; the code is lifted whole in sub_00257291"}
CODE = {".text", "D3D", "XGRPH", "XNET", "XONLINE", "DSOUND", "XPP"}   # x86 sections (DOLBY is DSP microcode)


def load(path):
    """The XBE's sections as (name, va, raw bytes)."""
    d = open(path, "rb").read()
    base, = struct.unpack_from("<I", d, 0x104)
    n, hdrs = struct.unpack_from("<II", d, 0x11C)
    secs = []
    for i in range(n):
        _, va, _, raw, rawsize, name = struct.unpack_from("<IIIIII", d, hdrs - base + i * 56)
        secs.append((d[name - base:name - base + 16].split(b"\0")[0].decode(), va, d[raw:raw + rawsize]))
    return secs


def read(secs, va, n):
    for _, v, b in secs:
        if v <= va < v + len(b):
            return b[va - v:va - v + n]
    return b""


secs = load(XBE)
code = [(v, v + len(b)) for nm, v, b in secs if nm in CODE]
fs = json.load(open(os.path.join(R, "engine/xboxrecomp/tools/disasm/output/functions.json")))
rng = sorted((int(f["start"], 16), int(f["end"], 16)) for f in fs)
starts = [r[0] for r in rng]
md = Cs(CS_ARCH_X86, CS_MODE_32)
refs = {}
for path in glob.glob(os.path.join(GEN, "recomp_0*.c")):
    cur = None
    for line in open(path, errors="ignore"):
        m = re.match(r"^void (sub_[0-9A-F]{8})(_gen)?\(void\)", line)
        if m:
            cur = m.group(1)
        for t in re.findall(r"\b(sub_[0-9A-F]{8})\(\)", line):
            refs.setdefault(t, set()).add(cur or "?")
stubs = re.findall(r"/\* 0x([0-9A-F]+): ", open(os.path.join(GEN, "recomp_stubs_unresolved.c")).read())
real = 0
for a in (int(x, 16) for x in stubs):
    i = bisect.bisect_right(starts, a) - 1
    if i >= 0 and rng[i][0] <= a < rng[i][1]:
        s = rng[i][0]
        kind = "BOUNDARY" if a in {x.address for x in md.disasm(read(secs, s, a - s + 16), s)} else "mid-insn"
    else:
        kind = "code" if any(lo <= a < hi for lo, hi in code) else "data"
    if kind in ("BOUNDARY", "code") and read(secs, a, 1) == b"\xcc":
        kind = "pad"
    if a in TABLE:
        kind = "table"
    real += kind in ("BOUNDARY", "code")
    ins = [f"{x.mnemonic} {x.op_str}" for x, _ in zip(md.disasm(read(secs, a, 16), a), range(2))]
    print(f"{a:#010x} {kind:8} from {','.join(sorted(refs.get('sub_%08X' % a, [])))} | {' ; '.join(ins)}")
print(f"stubcheck: {len(stubs)} stubs, {real} real code" + (" -- seed them" if real else ""))
sys.exit(1 if real else 0)
