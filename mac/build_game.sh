#!/bin/bash
# Builds the game's binary on the player's Mac from their own disc (the installer carries no lifted or generated game code;
# Apple's Command Line Tools only, no Homebrew):
#   mac/build_game.sh <kit> <disc dir> <frameworks dir> <work dir> <out binary> [progress file]
# kit (tools/kit.py): lift/ (xboxrecomp's Python lifter, the engine's regen.sh, seeds, recomp_manual.c), py/capstone,
# lib/ (runtime objects, static libraries, link.txt, cflags.txt). frameworks: libSDL2-2.0.0.dylib + libSDL3.dylib.
# Steps: lift default.xbe -> gen/*.c (CLT python3 + the kit's capstone); compile on the performance cores; link.
# Progress lines "N text" (N = 5..95) go to the progress file. NFSU2_BUILD_JOBS=<n> sets the compile jobs.
# Adapted from NFSU2Deadware's tools/dmg/build_game.sh (MIT, LeoDeadware).
set -uo pipefail
KIT=$1 DISC=$2 FW=$3 WORK=$4 OUT=$5 PROG="${6:-/dev/null}"
mkdir -p "$WORK" "$(dirname "$OUT")"
abs() { (cd "$(dirname "$1")" && echo "$(pwd -P)/$(basename "$1")"); }   # regen.sh changes directory
KIT="$(abs "$KIT")" DISC="$(abs "$DISC")" FW="$(abs "$FW")" WORK="$(abs "$WORK")" OUT="$(abs "$OUT")"
report() { echo "$1 $2" >> "$PROG"; echo "build_game: [$1%] $2"; }
die() { echo "build_game: ERROR $1" >&2; exit 1; }
CC="$(xcrun -f clang)" && CXX="$(xcrun -f clang++)" || die "no clang (Command Line Tools)"
SDK="$(xcrun --show-sdk-path 2>/dev/null)"
[[ -d "$SDK" ]] || die "no macOS SDK in the Command Line Tools (xcrun --show-sdk-path)"
[[ -f "$DISC/default.xbe" ]] || die "no default.xbe in $DISC"
echo "build_game: $("$CC" --version | head -1), SDK $SDK"

# 1. lift (resumable: a finished lift leaves gen/.done)
mkdir -p "$WORK/obj"
if [[ ! -f "$WORK/gen/.done" ]]; then
  report 10 "Translating the game's program (default.xbe) to C"
  rm -rf "$WORK/gen" "$WORK/tk"; mkdir -p "$WORK/gen" "$WORK/tk"
  cp -R "$KIT/lift/tools" "$KIT/lift/templates" "$WORK/tk/"
  env PATH=/usr/bin:/bin PYTHONPATH="$KIT/py" PYTHONDONTWRITEBYTECODE=1 XBOXRECOMP_DIR="$WORK/tk" \
    NFSU2_XBE="$DISC/default.xbe" NFSU2_GEN_DIR="$WORK/gen" \
    nice -n 10 bash "$KIT/lift/com/tools/regen.sh" > "$WORK/lift.log" 2>&1 || die "lift failed: $(tail -2 "$WORK/lift.log")"
  touch "$WORK/gen/.done"
fi

# 2. compile (objects newer than their source are kept)
srcs=("$WORK"/gen/*.c); n=${#srcs[@]}
(( n > 1 )) || die "no generated code"
jobs=${NFSU2_BUILD_JOBS:-$(/usr/sbin/sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || /usr/sbin/sysctl -n hw.ncpu)}
{ printf '"%s"\n' -isysroot "$SDK" -I "$WORK/gen"; sed 's/.*/"&"/' "$KIT/lib/cflags.txt"; } > "$WORK/flags.rsp"
export CC WORK
done_n() { find "$WORK/obj" -name '*.o' | wc -l | tr -d ' '; }
printf '%s\0' "${srcs[@]}" | xargs -0 -P "$jobs" -n 1 bash -c '
  s="$1"; o="$WORK/obj/$(basename "${s%.c}").o"
  [[ -f "$o" && "$o" -nt "$s" ]] && exit 0
  nice -n 10 "$CC" @"$WORK/flags.rsp" -c "$s" -o "$o.tmp" 2>>"$WORK/compile.log" && mv "$o.tmp" "$o"' _ &
cpid=$!
while kill -0 $cpid 2>/dev/null; do
  report $((30 + 60 * $(done_n) / n)) "Compiling the game: $(done_n) of $n files"
  sleep 2
done
wait $cpid
(( $(done_n) == n )) || die "compile failed: $(grep -m2 error "$WORK/compile.log")"

# 3. link
report 92 "Linking the game"
FWA="$(cd "$FW" && pwd)"
args=(); while IFS= read -r l; do l="${l//@KIT@/$KIT}"; args+=("${l//@FW@/$FWA}"); done < "$KIT/lib/link.txt"
mkdir -p "$(dirname "$OUT")"
"$CXX" -isysroot "$SDK" -arch arm64 -mmacosx-version-min=15.0 -Wl,-headerpad_max_install_names \
  -Wl,-rpath,@executable_path/../Frameworks -o "$OUT.tmp" "$WORK"/obj/*.o "${args[@]}" > "$WORK/link.log" 2>&1 \
  || die "link failed: $(grep -m2 -i error "$WORK/link.log")"
mv "$OUT.tmp" "$OUT"
echo "build_game: $OUT"
