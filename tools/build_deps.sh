#!/bin/bash
# The libraries the game links, for macOS 15 and later, into build/deps (or $1):
#   lib/libSDL3.0.dylib       SDL3 3.4.16 (the same pin as the HP2 port)
#   lib/libSDL2-2.0.0.dylib   sdl2-compat (SDL2's API on SDL3; the game is written against SDL2)
#   include/SDL2, lib/cmake   the SDL2 headers and CMake package the build uses (+ libSDL2main.a)
#   share/licenses/<name>/    their license files
# Built from pinned, SHA-256-checked sources (Homebrew's are built for the newest macOS only). Adapted from the HP2 port's
# tools/build_deps.sh. Needs cmake, ninja and curl.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="$(mkdir -p "${1:-$ROOT/build/deps}" && cd "${1:-$ROOT/build/deps}" && pwd -P)"
TARGET=15.0
DOWNLOADS="$PREFIX/downloads"
mkdir -p "$DOWNLOADS" "$PREFIX/lib" "$PREFIX/include" "$PREFIX/share/licenses"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nfsu2-deps.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# name | URL | SHA-256
SOURCES=(
  "SDL3|https://github.com/libsdl-org/SDL/releases/download/release-3.4.16/SDL3-3.4.16.tar.gz|7322236cd12090c3eb40b9728be4d49c76f66ad17d04369584d4ecad5cf77c68"
  "sdl2-compat|https://github.com/libsdl-org/sdl2-compat/releases/download/release-2.32.74/sdl2-compat-2.32.74.tar.gz|ec68abde77e2e459c8abc4f9587b8976b5d2a657b2bfda2fb3a079b0f8924588"
)
field() { local IFS='|'; local a=($1); echo "${a[$2]}"; }

# unpack <name>: the source folder, from the checked archive
unpack() {
  local s url sum file
  for s in "${SOURCES[@]}"; do [ "$(field "$s" 0)" = "$1" ] && break; done
  url="$(field "$s" 1)"; sum="$(field "$s" 2)"; file="$DOWNLOADS/$1-$(basename "$url")"
  [ -f "$file" ] || { echo "downloading $url" >&2; curl -fsSL -o "$file.part" "$url" && mv "$file.part" "$file"; }
  echo "$sum  $file" | shasum -a 256 -c - >/dev/null || { echo "build_deps.sh: $file isn't the expected archive" >&2; exit 1; }
  mkdir -p "$WORK/$1" && tar -xf "$file" -C "$WORK/$1"
  echo "$WORK/$1/$(ls "$WORK/$1")"
}

# cmake_install <name> <source> [extra cmake args]: release build for macOS $TARGET into $WORK/<name>-install
cmake_install() {
  local name="$1" src="$2"; shift 2
  (cd "$src" && cmake -S . -B build "$@" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WORK/$name-install" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=$TARGET -DCMAKE_OSX_ARCHITECTURES=arm64 -DSDL_TESTS=OFF -DSDL_STATIC=OFF \
      -DSDL2COMPAT_TESTS=OFF -DCMAKE_C_FLAGS_RELEASE="-Os -DNDEBUG" "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local" \
      -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-headerpad_max_install_names >"$WORK/$name.log" 2>&1 \
    && cmake --build build && cmake --install build) >>"$WORK/$name.log" 2>&1 || { tail -20 "$WORK/$name.log" >&2; exit 1; }
}

echo "== SDL3 (macOS $TARGET)" >&2
src="$(unpack SDL3)"; cmake_install SDL3 "$src"
cp -L "$WORK/SDL3-install/lib/libSDL3.0.dylib" "$PREFIX/lib/libSDL3.0.dylib"
install_name_tool -id @rpath/libSDL3.0.dylib "$PREFIX/lib/libSDL3.0.dylib"
ln -sf libSDL3.0.dylib "$PREFIX/lib/libSDL3.dylib"   # the name sdl2-compat loads (@loader_path/libSDL3.dylib)
mkdir -p "$PREFIX/share/licenses/SDL3" && cp "$src/LICENSE.txt" "$PREFIX/share/licenses/SDL3/"

echo "== sdl2-compat (macOS $TARGET)" >&2
src="$(unpack sdl2-compat)"; cmake_install sdl2-compat "$src" -DSDL3_INCLUDE_DIRS="$WORK/SDL3-install/include"
rm -rf "$PREFIX/lib/cmake" "$PREFIX/lib/pkgconfig" "$PREFIX"/lib/libSDL2*
cp -R "$WORK/sdl2-compat-install/lib/." "$PREFIX/lib/"     # dylib + its symlinks, SDL2main, CMake config
install_name_tool -id @rpath/libSDL2-2.0.0.dylib "$PREFIX/lib/libSDL2-2.0.0.dylib"
rm -rf "$PREFIX/include/SDL2" && cp -R "$WORK/sdl2-compat-install/include/SDL2" "$PREFIX/include/SDL2"
mkdir -p "$PREFIX/share/licenses/sdl2-compat" && cp "$src/LICENSE.txt" "$PREFIX/share/licenses/sdl2-compat/"

# every library must run on macOS $TARGET
for f in "$PREFIX"/lib/libSDL3.0.dylib "$PREFIX"/lib/libSDL2-2.0.0.dylib; do
  m="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; b=0}' | sort -u | head -1)"
  awk -v m="$m" -v t="$TARGET" 'BEGIN { exit !(m + 0 <= t + 0) }' || { echo "build_deps.sh: $f needs macOS $m (> $TARGET)" >&2; exit 1; }
  echo "   $(basename "$f"): macOS $m+" >&2
done
echo "deps: $PREFIX" >&2
