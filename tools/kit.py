#!/usr/bin/env python3
"""The installer's build kit from build/release: the engine's runtime and our host, no game code.

    python3 -I tools/kit.py <build dir> <kit dir>

lift/     xboxrecomp's Python lifter (tools/ without outputs and tests, templates/), the engine's tools/regen.sh,
          config/seed_functions.json and src/recomp_manual.c (regen reads it to skip the hand-written functions)
py/       capstone (BSD) from .venv: the lifter runs on the Command Line Tools' /usr/bin/python3
lib/      the runtime objects of nfsu2_recomp (engine/src: the game's overrides and the Apple host) and the xboxrecomp static
          libraries; link.txt = the build's link line without the lifted chunks (@KIT@ = the kit,
          @FW@ = the app's Frameworks); cflags.txt = the build's flags for the lifted chunks
mac/build_game.sh lifts the player's default.xbe into gen/*.c, compiles it with clang and links (on their Mac).
Adapted from NFSU2Deadware's tools/dmg/kit.py (MIT, LeoDeadware).
"""
import glob
import os
import re
import shlex
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
UP = os.path.join(ROOT, 'engine')
build, kit = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
shutil.rmtree(kit, ignore_errors=True)
for d in ('lift', 'py', 'lib'):
    os.makedirs(os.path.join(kit, d))

ign = shutil.ignore_patterns('output', 'tests', 'conformance', '*.xbe', '__pycache__', '*.pyc', '.pytest_cache')
shutil.copytree(os.path.join(UP, 'xboxrecomp', 'tools'), os.path.join(kit, 'lift', 'tools'), ignore=ign)
shutil.copytree(os.path.join(UP, 'xboxrecomp', 'templates'), os.path.join(kit, 'lift', 'templates'), ignore=ign)
for rel in ('tools/regen.sh', 'config/seed_functions.json', 'src/recomp_manual.c'):
    dst = os.path.join(kit, 'lift', 'com', rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(os.path.join(UP, rel), dst)
cap = glob.glob(os.path.join(ROOT, '.venv', 'lib', 'python3*', 'site-packages', 'capstone'))[0]
shutil.copytree(cap, os.path.join(kit, 'py', 'capstone'), ignore=ign)
for lic in glob.glob(os.path.join(os.path.dirname(cap), 'capstone-*.dist-info', '*LICENSE*')) + \
        glob.glob(os.path.join(os.path.dirname(cap), 'capstone-*.dist-info', 'licenses', '*')):
    shutil.copy2(lic, os.path.join(kit, 'py', 'capstone', 'LICENSE.TXT'))

cmds = subprocess.run(['ninja', '-C', build, '-t', 'commands', 'nfsu2_recomp'], capture_output=True,
                      text=True, check=True).stdout.strip().splitlines()
# the lifted chunks' compile flags: as the build, without its include paths and dependency/output options
gen_cmd = shlex.split(next(c for c in cmds if '/gen/recomp_0000.c' in c))
cflags, skip = [], 0
for a in gen_cmd[1:]:
    if skip:
        skip -= 1
        continue
    if a in ('-MT', '-MF', '-o', '-c', '-I', '-isystem'):
        skip = 1
        continue
    if a == '-MD' or a.startswith(('-I', '-isystem')):
        continue
    cflags.append(a)
open(os.path.join(kit, 'lib', 'cflags.txt'), 'w').write('\n'.join(cflags) + '\n')

link = shlex.split(cmds[-1].split('&&')[1])
args = link[link.index('-o') + 2:]
out, objs, seen = [], [], {}
for a in link[1:link.index('-o')] + args:
    if a.endswith('.o'):
        if '/gen/' in a:
            continue                      # the lifted chunks: built on the player's Mac
        name = a.split('nfsu2_recomp.dir/')[-1].replace('/', '_')
        shutil.copy2(os.path.join(build, a), os.path.join(kit, 'lib', name))
        objs.append('@KIT@/lib/' + name)
        continue
    if a.startswith('-Wl,-rpath') or a in ('-O2', '-O3', '-g', '-DNDEBUG', '-arch', 'arm64') \
            or a.startswith(('-mmacosx-version-min', '-Wl,-search_paths_first', '-Wl,-headerpad')):
        continue
    m = re.match(r'(-Wl,-force_load,)?(.+\.a)$', a)
    if m:
        p = m.group(2) if os.path.isabs(m.group(2)) else os.path.join(build, m.group(2))
        name = os.path.basename(p)
        if name not in seen:
            seen[name] = p
            shutil.copy2(p, os.path.join(kit, 'lib', name))
        a = (m.group(1) or '') + '@KIT@/lib/' + name
    elif a.endswith('.dylib'):
        a = '@FW@/' + os.path.basename(a)
    out.append(a)
open(os.path.join(kit, 'lib', 'link.txt'), 'w').write('\n'.join(objs + out) + '\n')
# no debug info: the objects' paths would name this Mac's folders
for f in os.listdir(os.path.join(kit, 'lib')):
    if f.endswith(('.a', '.o')):
        subprocess.run(['strip', '-S', os.path.join(kit, 'lib', f)], check=True, capture_output=True)
print(f'kit: {kit}: {len(objs)} objects, {len(seen)} libraries, {len(out)} link args, {len(cflags)} cflags')
