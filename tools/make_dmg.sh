#!/bin/bash
# The players' DMG: "NFS Underground 2 Installer.app" with its kit (the lifter, upstream's runtime and our Apple host as compiled
# objects, SDL for macOS 15+). No game code and no game data: the installer builds the game on the player's Mac from their own
# disc. Checked by tests/dmg_no_game_code.sh before it is called done.
#   tools/make_dmg.sh            -> build/dmg/NFS-Underground-2-<version>.dmg (+ .sha256)
# Needs: tools/fetch.sh (upstream/), tools/build_deps.sh (build/deps), the release build (build/release, tools/build_release.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
export PATH="/opt/homebrew/bin:$PATH"
VERSION="$(cat VERSION)"
OUT=build/dmg; STAGE="$OUT/stage"; APP="$STAGE/NFS Underground 2 Installer.app"; KIT="$APP/Contents/Resources/kit"
DMG="$OUT/NFS-Underground-2-$VERSION.dmg"
[ -z "$(git -C upstream status --porcelain -- src xboxrecomp CMakeLists.txt tools config)" ] \
  || { echo "upstream/ has changes not in patches/: commit them there and export"; exit 1; }
[ -f build/deps/lib/libSDL3.0.dylib ] || { echo "run tools/build_deps.sh first"; exit 1; }
cmake --build build/release >/dev/null

rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$KIT/mac/icon" "$KIT/libs" "$KIT/licenses"
# the installer
cp installer/install.sh "$APP/Contents/MacOS/installer" && chmod 755 "$APP/Contents/MacOS/installer"
cp installer/clt.sh installer/progress.js VERSION "$KIT/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NFS Underground 2 Installer</string>
  <key>CFBundleIdentifier</key><string>io.github.sanyokkua.nfsu2.installer</string>
  <key>CFBundleExecutable</key><string>installer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
# the kit: lifter + runtime objects (tools/kit.py), our scripts, SDL
/usr/bin/python3 -I tools/kit.py build/release "$KIT/build"
cp mac/build_game.sh mac/assemble_app.sh mac/make_icon.sh mac/import_disc.py mac/xiso.py "$KIT/mac/"
cp mac/icon/xbe_title_image.py mac/icon/squircle.swift "$KIT/mac/icon/"
swiftc -O -o "$KIT/mac/icon/squircle" mac/icon/squircle.swift -target arm64-apple-macos15.0 2>/dev/null || echo "note: no swiftc, squircle compiled at install"
cp build/deps/lib/libSDL2-2.0.0.dylib build/deps/lib/libSDL3.0.dylib "$KIT/libs/"
# licenses and notices
cp -R LICENSES/. "$KIT/licenses/"
cp -R build/deps/share/licenses/. "$KIT/licenses/"
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "$KIT/"
PIN="$(sed -n 's/^BASE=\([0-9a-f]*\).*/\1/p' tools/fetch.sh)"
echo "nfsu2-ios by myUdav4iik (https://github.com/myUdav4iik/nfsu2-ios), commit $PIN, with this project's patches/ applied; its source: $(git remote get-url origin 2>/dev/null || echo 'this project')/tree/v$VERSION" > "$KIT/SOURCE.txt"
codesign --force --sign - "$APP" >/dev/null 2>&1
# the DMG's other files
cp docs/dmg/read-me-first.txt "$STAGE/Read me first.txt"
cp THIRD_PARTY_NOTICES.md "$STAGE/Third-party notices.md"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "NFS Underground 2" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
tests/dmg_no_game_code.sh "$DMG"
echo "dmg: $DMG ($(du -h "$DMG" | cut -f1))"
