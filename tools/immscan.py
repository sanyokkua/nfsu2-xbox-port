#!/usr/bin/env python3
"""tools/immscan.py: missed functions referenced only by an immediate (push imm32 / mov eax, imm32) in code: static initializers
that fill state tables with member-function pointers, callbacks pushed as arguments. Lists targets after int3/ret padding
that are no function start in functions.json ("free" = no lifted code at all, a sure [ICALL] miss). Check with seedcheck.py; .venv.
Usage: tools/immscan.py [repo root, default this one]."""
import sys, os, json, struct, re, bisect
R = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..')   # another port's root: read only
sys.path.insert(0,os.path.dirname(__file__)); from sigmatch import load, read
secs=load(os.path.join(R,'game/extracted/default.xbe'))
fs=json.load(open(os.path.join(R,'engine/xboxrecomp/tools/disasm/output/functions.json')))
rng=sorted((int(f['start'],16),int(f['end'],16)) for f in fs); st=[r[0] for r in rng]; starts=set(st)
CODE=('.text','D3D','D3DX','XGRPH','DSOUND','XPP','WMADEC','XACTENG','XNET','XONLINE')
code=[(v,v+len(b)) for nm,v,vs,b in secs if nm in CODE]
def incode(a): return any(s<=a<e for s,e in code)
tot=0; out={}
for nm,v,vs,b in secs:
    if nm not in CODE: continue
    for m in re.finditer(rb'(\xb8|\x68)(....)', b, re.S):
        a,=struct.unpack('<I',m.group(2)); 
        if not incode(a): continue
        tot+=1
        if a in starts: continue
        p=read(secs,a-1,1)
        if p and p[0] in (0xcc,0xc3):
            out.setdefault(a,[]).append(v+m.start())
print('imm refs to code',tot)
for a in sorted(out): 
    i=bisect.bisect_right(st,a)-1; ins= rng[i][0]<=a<rng[i][1]
    print(hex(a),[hex(x) for x in out[a][:3]], 'inside' if ins else 'free')
