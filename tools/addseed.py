#!/usr/bin/env python3
"""tools/addseed.py <va> "<note>" ...: add seeds to engine/config/seed_functions.json (skips ones already there).
A seed must be an instruction start: tools/stubcheck.py lists the stubs that are (BOUNDARY, code). From the hpcos-xbox-port."""
import json, os, sys
p = os.path.join(os.path.dirname(__file__), "../engine/config/seed_functions.json")
s = json.load(open(p)); have = {int(x["start"], 16) for x in s}
args = sys.argv[1:]
for va, note in zip(args[::2], args[1::2]):
    a = int(va, 16)
    if a in have: print(f"{a:#x} already seeded"); continue
    s.append({"start": f"0x{a:08X}", "note": note}); have.add(a); print(f"{a:#x} added")
json.dump(s, open(p, "w"), indent=1)
