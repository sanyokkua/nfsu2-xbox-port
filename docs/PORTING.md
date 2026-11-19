# How the port was made

A log of the steps, the decisions and what went wrong, for the next port (NFS Underground 1 uses the same layout).

## Sources (pinned)

| What | Where | Pin |
|---|---|---|
| Base | [myUdav4iik/nfsu2-ios](https://github.com/myUdav4iik/nfsu2-ios), branch `ios` | `85d2cbf` (= nfsu2-sw v0.5.13 + Apple host + `nv2a_metal`); newest on 2026-11-19 |
| Engine patches | [LeoDeadware/NFSU2Deadware](https://github.com/LeoDeadware/NFSU2Deadware) `patches/` | its 26 patches for `85d2cbf` |
| Disc | Xbox USA, `default.xbe` SHA-1 `428b5a70b9400f19cc5be7679db6c72a6f80a1c9`, 4,038,656 bytes, title `0x4541005A` | |

At first `tools/fetch.sh` cloned the base and `git am`ed `patches/`; since the overlay work the patched tree is in the
repository as `engine/` (section 5), the patches kept in `docs/upstream-patches/` as the record.

## 1. A clean patch set

"Clean" = only the disc's assets; engine improvements are welcome. Of NFSU2Deadware's 26 patches:

- **Dropped:** 0005's `apple_textures.m` part (the HD pack loader), 0024 (Ukrainian strings), 0025 (Ukrainian fonts).
- **Kept from 0005:** its `nv2a_metal.m` / `nv2a_backend.h` hunks (mips for replaced textures, `Nv2aTexInfo.flat`): 0016 and
  0017 build on those lines, and they do nothing without an HD provider.
- **0010:** its `apple_textures.m` hunks (HD preload) excluded.
- **0004 kept:** it redraws the disc's own PS/LT/RT button glyphs (matched by hash) with CoreGraphics; no files.

`git am --3way --exclude=src/apple/apple_textures.m` for 0005 and 0010 applied all 24 without conflicts; the result was
exported with `git format-patch` as `patches/0001-0024`. Ours: 0025 (Settings window), 0026 (player folder).

## 2. Lift, build, boot

- Disc: `extract-xiso -x <iso> -d game` ignored `-d` (it made a folder named after the ISO): rename it to `game/extracted`.
- Lift: `upstream/tools/regen.sh` with a venv's capstone 5.0.7 (`capstone<6`): 2 min 23 s, 83 C files, 129 MB.
- Build: CMake + Ninja, `-DNFSU2_METAL=ON -DNFSU2_VULKAN=OFF -DXBOXRECOMP_D3D8_NULL=ON`, about a minute with 8 jobs.
- First boot on the M1 Pro: intro, menus and the profile dialog right away; the user then played several races at 60 fps,
  smooth and stable.
- **Frame dumps:** `RECOMP_FB_DUMP` reads guest memory and is black under Metal (the picture never goes back there); use
  `RECOMP_GL_DUMP=<prefix>,<every n frames>` (Metal's own read-back, BMP).
- **Gate:** `tools/smoke.sh` runs the game for 75 s in a throwaway HOME on an APFS clone of the disc
  (`RECOMP_PAD_PRESS=0x10,2500,200` = START every 2.5 s), and checks the smoke timer's clean exit and a non-black last frame.

## 3. Settings and the player folder (patches 0025, 0026)

- NFSU2Deadware set its options in a launcher window before the game (JXA) and passed them as environment variables. Here they
  are a **Settings window inside the game** (Cmd+,), the same window and `settings.ini` as the NFS Underground 1 port, so all the
  ports configure the same way. Resolution Scale is live (it is the game's Options row, `nfsu2_options_set_scale`); the
  post-effects are read once at start (`post_settings`), so those rows say "next start".
- The app needs no launcher: `apple_player.c` sets `NFSU2_GAME_DIR`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, the working directory and
  the log when `NFSU2_GAME_DIR` isn't set. The game writes its saves (`UDATA/`) in the game folder.

## 4. The installer (the HP2 model)

The DMG holds no game code: the installer imports the disc, lifts `default.xbe` and compiles it on the player's Mac.

- **Kit** (`tools/kit.py`, from NFSU2Deadware's): the lifter (Python) + capstone, upstream's runtime and our host as
  compiled objects and static libraries, the link line and the lifted chunks' compile flags, both read from the release build's
  Ninja commands (so the player's build matches ours).
- **Player's build** (`mac/build_game.sh`): `/usr/bin/python3` (CLT 3.9) lift, gives the same C as the 3.15 venv; clang on the
  performance cores (23 s on the M1 Pro); link; then the icon from the disc's title image.
- **SDL** for macOS 15: SDL3 3.4.16 and sdl2-compat 2.32.74 from source (`tools/build_deps.sh`). sdl2-compat loads
  `@loader_path/libSDL3.dylib`, so the app has `Frameworks/libSDL2-2.0.0.dylib` + `Frameworks/libSDL3.dylib`. The game builds
  for macOS 15 without availability warnings.
- **`tests/dmg_no_game_code.sh`**: disc file names, the disc's SHA-1s, 64 windows of the XBE's executable sections, more than 150
  lifted function names in one file, the builder's home path.
- **Measured:** a headless install from the DMG into a clean HOME (`NFSU2_NO_UI=1 NFSU2_IMPORT_ISO=… NFSU2_INSTALL_DIR=…`):
  copy 2.6 GB + lift + compile + link + icon = **3 min 42 s** on the M1 Pro; the installed app booted to the menus from its
  player folder. DMG 4.6 MB. Proven negative: a DMG with 1.2 MB of `default.xbe` (19 windows)
  and a lifted chunk renamed `notes.txt` (398 names) fails.

## 5. A self-contained repository

The port must build from this repository alone (the user's rule for all the ports): `git archive` of the patched tree went into
`engine/` (535 files, 10 MB; its `CLAUDE.md` moved to `engine/docs/NFSU2_IOS_AGENT_NOTES.md` so it doesn't instruct agents
working here), `patches/` to `docs/upstream-patches/` with a README, `tools/fetch.sh` removed. `engine/gen/` (the lift) is
ignored. `publish_check.sh` allows one file it would flag: xboxrecomp's 4 KB synthetic `conformance/test.xbe` (its `mkxbe.py`).

## 6. The settings menu (overlay)

Modelled on SpeedBreaker's (`runtime/ui/settings_menu.cpp`, Dear ImGui over Vulkan): written anew for this engine in
`engine/src/overlay/` so every port can take it.

- **Drawing:** Dear ImGui 1.92.9 (the core as in SpeedBreaker, the Metal backend from the same tag) draws into the drawable in
  `nv2a_metal.m`'s `present()`, after the game's picture and the fps counter, through a hook (`nv2a_mtl_overlay_hook`) so
  the renderer doesn't depend on the menu. Roboto Medium is compiled in (CMake writes it as a byte array).
- **Threads:** the game presents on its render thread; SDL events come on the main thread. `overlay_event` (main) turns keys,
  pad buttons, the stick and the mouse into menu actions on a locked queue; `overlay_present_metal` (render) runs them and
  lays the menu out. Full screen, Quit and opening Finder are requested back to the main thread (`overlay_main_tick`, run each
  turn of the event loop, which now waits at most 16-50 ms instead of forever).
- **Input:** `xbox_input_blocked` (xinput_device.c) gives the game a connected, neutral pad while the menu is open and after,
  until every key and button is up (so B closing the menu doesn't reach the game). Key releases still go to the keyboard pad.
- **Options:** one table per game (`nfsu2_options.c`): settings.ini rows (`key`, `values`, `apply`) or the game's own
  Options rows (`get`/`set` into `recomp_manual.c`'s `nfsu2_option_get/set`). Made live for the menu: draw distance
  (`nfsu2_set_draw_distance`), gamma and effects (`nv2a_mtl_post_reload`: the post settings are read again at the next
  frame; `post_frame` calls `post_settings` every flip, which at first only the shader build did, so Gamma and Effects
  needed a restart until the user noticed), motion blur (`nv2a_mtl_blur_off`), volume (`xa2_set_master_volume`), fps counter. Frame Rate and Keyboard as
  Controller stay "restart".
- **Tests:** `NFSU2_OVERLAY_SCRIPT="25:open,26:next,27:down,28:right,29:shot,30:close"` runs menu steps; `NFSU2_OVERLAY_SHOT`
  makes the drawable readable and writes `shot<n>.bmp`. `tools/smoke.sh` opens and closes the menu. Checked from shots: every
  page, a live change saved to `settings.ini`, the "restart" mark, the Quit prompt.

## Pitfalls (each cost a run)

- **zsh doesn't split `$VAR` into words:** `AM="git am -q"; $AM p` is "command not found". Use a function.
- **regen.sh `cd`s into the toolkit:** relative paths given to it break; `build_game.sh` makes every argument absolute.
- **`env -i PATH=/usr/bin:/bin` has no `/usr/sbin`:** `sysctl` (the job count) was missing, `xargs -P ""` compiled nothing.
- **A file made with the Write tool isn't executable:** the installer app could not start (`Permission denied`). `make_dmg.sh` now
  sets 755 itself.
- **Empty files share a SHA-1:** the disc has a 0-byte `streamed.dat`, so every empty `__init__.py` "was a disc file". The test
  ignores disc files under 64 bytes, and `recomp_manual.c` (upstream's hand-written overrides) by name.
- **The lifted C is split 250 functions a file:** a "more than 2000 names" check missed a renamed chunk; 150 catches it
  (`recomp_manual.c` has 77).
- **sdl2-compat loads `libSDL3.dylib`:** `build/deps` had only `libSDL3.0.dylib`, so the dev build aborted at start with an
  empty log; `build_deps.sh` adds the symlink (the app's `Frameworks/` has the right name).
- **A pipe hides a failed check:** `publish_check.sh | tail` let a commit through; run checks unpiped before committing.
- **`nv2a_metal` is built with `-Wno-unguarded-availability`:** "no availability warnings for macOS 15" needed a compile of it
  with them on (none).
- **`apple_main.c` declares `s_win` after `set_full`:** functions for the Settings window that use it go after that declaration.
