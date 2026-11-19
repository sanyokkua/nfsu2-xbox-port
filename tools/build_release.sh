#!/bin/bash
# The release build (build/release): lift the disc in game/extracted (once), then the Metal build against build/deps for
# macOS 15+. Its objects (minus the lifted chunks) go into the installer's kit (tools/kit.py, tools/make_dmg.sh).
# Needs: tools/fetch.sh, tools/build_deps.sh, .venv with capstone<6 (python3 -m venv .venv && .venv/bin/pip install 'capstone<6').
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
export PATH="$ROOT/.venv/bin:/opt/homebrew/bin:$PATH"
[[ -f upstream/gen/recomp_dispatch.c ]] || \
  NFSU2_XBE="$ROOT/game/extracted/default.xbe" NFSU2_GEN_DIR="$ROOT/upstream/gen" upstream/tools/regen.sh
cmake -S upstream -B build/release -G Ninja -DCMAKE_BUILD_TYPE=Release -DNFSU2_GEN_DIR="$ROOT/upstream/gen" \
  -DNFSU2_VULKAN=OFF -DNFSU2_METAL=ON -DNFSU2_GEN_OPT=-O2 -DXBOXRECOMP_D3D8_NULL=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_PREFIX_PATH="$ROOT/build/deps" "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local" >/dev/null
cmake --build build/release
echo "release: build/release/nfsu2_recomp"
