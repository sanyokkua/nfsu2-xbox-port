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

## 7. Lifter: x87 80-bit operands (2026-11-23)

From the Harry Potter Chamber of Secrets port: `fld xword ptr [m80]` was lifted as a 4-byte float (`fp_push(MEMF(..)); /* fld */`)
and `fstp m80` as a no-op. The C runtime's asin/acos load π/2 that way for |x| = 1 and got ≈ 0 (in CoS the player's heading came
out 90° off). The lifter now emits `recomp_ld_f80` / `recomp_st_f80` (`recomp_types.h`, before `recomp_cvt_si`), with a unit
test. NFSU2: 16 loads changed to `/* fld tbyte */`, no m80 stores. Relift, build, `tools/smoke.sh` and a scripted race
(`RECOMP_PAD_PRESS=0x10,2500,200` plus `a` every 2.5 s from 21 s in `RECOMP_PAD_SCRIPT`) pass.

## 8. Engine fixes from the Chamber of Secrets port (2026-11-23, released in 0.1.2)

From `hpcos-xbox-port` (its notes: XBOX360_PORTING_NOTES.md section 14), commits 459e9a8, 6804dcd, d6e8046, afa393e,
dab3b89, bc9538e:

- **Texture border colour in the shader** (CoS `ca756e0`): border addressing (mode 4) samples clamp-to-edge and the fragment
  shader returns the stage's `SET_TEXTURE_BORDER_COLOR` outside [0, 1] (`nv2a_samp`, `Nv2aMslFs.bc/bm`). A `[metal] border
  addressing` line names each stage and colour a title uses. Checked: a scripted race (START every 2.5 s, then A every 2.5 s
  from 21 s, 100 s): no stage with border addressing (the old sampler gave transparent black); race frames before and after
  are the same picture at a different moment of the race.
- **LB = White, RB = Black** and the **press latch** (CoS `dcc5179`, `12f88fc`): the bumpers were swapped in
  `xinput_device.c` in every port of this engine; the keyboard keeps Q = White, E = Black (`apple_keyboard.c`). Presses are
  latched from SDL's controller events between two reads (`RECOMP_PAD_LATCH=0` off) and held for `RECOMP_PAD_MIN_READS`
  reads (default 2). `RECOMP_PAD_SCRIPT` does not go through SDL events, so scripted runs do not exercise the latch; needs a
  pad in a play test.
- **Runtime** (CoS `dcc5179`, `f38f328`, `cf6d9c2`): the handle table under a spinlock; a read on a handle closed within 2 s
  returns `STATUS_END_OF_FILE`; `NtSetEvent` waits (2 ms at most) until the waiter it releases has queued for the guest lock
  (`RECOMP_WAKE_HANDOFF=0` off, `RECOMP_EVT_TRACE=1`).
- **No feedback copy** for a render target bound on a stage no combiner reads (CoS `9178756`, `nv2a_psh_reads_tex`).
- **Not ported:** NFSU2 uses no W-buffer depth; it enables the fog unit only as linear fog with params 1, 1, where the fog
  factor is the coordinate the vertex program writes, as drawn already. The CoS fog unit is not ported. The InsertCallback
  latch hold is not needed: this tree has no clear-value latch (only CoS's XDK 5028 calls back through it). Viewport
  constants 58/59 from `SET_VIEWPORT_*`: this XDK writes the constants itself. The worker wait, loader callbacks, file-cache
  hold, DirectSound address tag, 2D tile seams, cutscene skip and left-stick range are CoS's own code or tuning.
- Verified: `cmake --build build/release`; `tools/smoke.sh` OK; the Metal shader test (463 shader pairs, 63 recorded by the
  run, 0 failures); frame throughput as before. The runtime's own unit tests (`engine/xboxrecomp/tests/kernel_*`) need
  `pkg-config`, not installed on this Mac: not run.

## 9. More from the Chamber of Secrets port: lifetimes, stub check, pad hotplug (2026-11-24, released in 0.1.2)

From `hpcos-xbox-port` `58773a1`, `33a2b93` (runtime), `6ce58e0` (stub check), `e64d110` (pads). Both runtime patches applied
cleanly on top of this repo's own handle lock (`d6e8046`, itself from CoS): the next-fit allocation sits inside that lock.

- **Runtime:** `recomp_icall_skip_esp` (a skipped wild call followed by `add esp, N` pops only the return address); timer
  fire signals inside `g_timer_lock` before the DPC, `kernel_set_timer` resets inside it and logs when its 256 slots run out;
  `BRIDGE_HANDLE_MAX` 65536, next-fit; `kdisp_is_guest` drops a shadow whose memory now holds a guest event; Ke objects get
  their shadow after their header; `win32_compat`: open handles counted apart from references (`obj_get`), `CloseHandle`
  drops one handle once, `DuplicateHandle` adds one, `WaitForSingleObject` and `NtReadFile`/`NtWriteFile` hold the object
  (`w32_handle_get_fd`/`w32_handle_put`), `pread`/`pwrite` at an offset; registry 262144 slots with a log when full; heap
  sizes larger than the heap refused (one near 4 GB rounded to 0). Not taken: CoS's game region `0x104` (its NTSC choice),
  its spawner guard, entity diagnostics and `HPCOS_*` switches.
- **Stub check:** `engine/gen/recomp_stubs_unresolved.c` gives every jump or call target the disassembler did not detect an
  empty body. `tools/stubcheck.py` (after a full lift) classes each: an instruction start in a detected function (BOUNDARY) or
  undetected code is real and must be seeded (`tools/addseed.py`); mid-instruction, data, int3 padding and reviewed table
  bytes are harmless. Adapted for this XBE: x86 sections `.text D3D XGRPH XNET XONLINE DSOUND XPP` read from the headers, and
  the `ret N` stubs counted too (CoS's regex saw only the `not detected` ones). `tools/relift.sh` = regen, stubcheck, build.
  - NFSU2 had 133 real of 157. Seeding splits functions and exposes new cross-boundary jumps: rounds of 130, 111, 24, 5, 2
    seeds (272 in all, `seed_functions.json` 17 -> 289, each noted "Stub check round N"), then 0 real of 27 stubs. Most were
    loop heads or branch targets inside functions the sweep had cut at a `tail_jump_alias` (e.g. a dozen aliases at
    0x00100002..0x001000DF all jumping back to 0x000FFF60); 23 were epilogues (`pop`/`leave`/`ret`), the CoS freeze shape.
  - Not seeded: 0x001154DA, 0x00115502 (int3, jumped to from a jump table walked as code) and 0x00257295: a `jb` decoded from
    the jump table at 0x00257270. The disassembler rejects that seed (inside an instruction of the misdecoded table), and the
    real code there is lifted whole in `sub_00257291`; stubcheck lists it as `table`.
  - The list with each stub's instructions: the side-session notes `nfsu2-stubcheck-seeds.md` (outside the repo).
- **Pads:** `xbox_input_rescan()` opens and closes pads on the main thread (at start and on `SDL_JOYDEVICEADDED/REMOVED`); the
  game thread reads them under `g_pad_lock` with no `SDL_GameControllerUpdate`; rumble takes the lock. NFSU2's own
  `apple_prompts.m` (button glyphs) enumerated pads from the game thread on its first 32x32 texture and from an event watch:
  now `nfsu2_prompts_pads_changed()`, called next to the rescan. `NFSU2_PAD_HOTPLUG_TEST=<ms>` attaches and detaches a
  virtual pad that often.
- Verified: `tools/relift.sh` (stubcheck 0 real, build OK, no new warnings); `tools/smoke.sh` OK (75 s, last mean 45); a
  scripted race (START every 2.5 s, A every 2.5 s from 21 s, 100 s): clean exit, last frame in a race (lap 1/3); the same for
  120 s with `NFSU2_PAD_HOTPLUG_TEST=37`: 3586 rescans, clean exit, no abort, last frame mean 51. All in throwaway HOMEs.

## 10. Backports from the Prisoner of Azkaban port (2026-11-24, released in 0.1.3)

1. **Disassembler `_prune_data_call_targets`** (hppoa 7b59edc, 2 new tests; the 35 disasm tests pass). A function known only
   as a call target and called only from outside every function is itself a body decoded out of data; its calls are no
   longer a "real caller". Relift (`tools/relift.sh`, 196 s): `functions.json` has the same 20,634 starts before and after,
   so nothing was dropped or added on this disc. 20,645 functions translated, 27 stubs, 0 real code, build OK.
2. **`XC_FACTORY_AV_REGION` (0x103)** (hppoa c053b83): answered 0x00400100 (NTSC-M, `XGetVideoStandard` = 1). This port has
   no region switch in the kernel: `NFSU2_REGION_PAL` is a compile definition set after `xboxrecomp` is added, so the
   vendored kernel never sees it. The value is right for the NTSC-U disc; a PAL build would need PAL-I (0x00800300) passed in.
3. **`tools/stubcheck.py` range** (hppoa 79c7af5): nothing to change. This script already takes every section named
   `.text`, `D3D`, `XGRPH`, `XNET`, `XONLINE`, `DSOUND`, `XPP` and builds the range from the raw size, so zero fill past a
   section's raw data is already data. Rerun on the fresh lift: 27 stubs, 0 real code, no seed added.
4. **Smoke** (`tools/smoke.sh 75`, own HOME): OK, 6 frames, last frame mean 45.

## 11. More PoA backports (2026-11-24, released in 0.1.3)

1. **MSL 3.0** (hppoa b85ffa1). `s_copts.languageVersion` = 3.0, `RECOMP_MTL_LANG` overrides, the hitch line counts pipelines. Two
   `tools/smoke.sh 75` runs on fresh HOMEs, same binary: log says `shader language 3.0` (4.0 with `RECOMP_MTL_LANG=0`),
   no `shader failed`, no `pipeline creation failed`. First-seen programs: 3 compiled in **57 ms vs 194 ms** (the one hitch
   with compiles: 234 ms at 4.0). Hitch count and total are the same (10 each; the others are texture loads and the menu).
   Frame dumps 1200..4200 are pixel-identical; dump 600 differs (menu animation timing). Menu run only, no route run.
2. **`tools/immscan.py` + `seedcheck.py`** (with `sigmatch.py`, copied from hppoa). 2,669 immediates into code, 3 hits, all
   false: the target is int3 padding, and the real function after it (0x4C260, 0x10C2D0, 0x119150) is already a start.
   0x4C25D and 0x10C2C9 are bytes of `fstp [ecx+68h]` / `... 68 c9 c2 10 00` read as `push imm32` (the immediate is the
   following `pop ebp; ret 4` / `leave; ret 10h`); 0x119144 is `mov eax, 0x119144; pop ebp; ret`, a constant, not a pointer
   (the 2 callers push it as a value). No seeds, so no relift; stubcheck unchanged (27 stubs, 0 real).
3. **Learned stick range** (hppoa 8cfb709): not applicable. This port has no `stick_deadzone.h` and no fixed 0.65
   `RECOMP_STICK_RANGE` (the CoS change was never backported here), so steering is unchanged.

## 12. Pushbuffer executor from PoA (hppoa 006d8a3, 2026-11-25, released in 0.1.3)

The three executor changes only (`batch_is_ffp` no longer excludes inline batches; `SET_VERTEX_DATA4F(3)` diffuse; `prim_min_vertices`
for point/line batches). The PoA debug aids (capture action, `[dl]` uv) were left out.

**Proof it is safe here.** Scripted route (`RECOMP_PAD_PRESS` START every 2.5 s, `a` every 2.5 s from 21 s, 150 s, own HOME:
boot, intro, menus, race grid with HUD) on the new binary, with and without `RECOMP_INLINE_FF=0`, plus temporary counters:
- `batch_is_ffp()` was **never called** (0 calls in 150 s): every NFSU2 draw is a vertex program, so the changed rule has nothing to
  act on. No 1- or 2-vertex batch was drawn and no `SET_VERTEX_DATA4F(3)` write happened. (Counters not committed.)
- Frames at the same dump numbers: menu and HUD frames 300, 900, 1800, 2100 differ by 0.0-0.3 % of pixels between the two
  runs. From the race on, runs differ by up to 20-45 % **between two identical new-binary runs as well**: the race is not
  deterministic in time (camera pose and lap-time digits differ), so those frames cannot be compared pixel by pixel.
- Same-state check: a build that used the new rule on odd flips and the old rule on even flips (temporary) over one run;
  stationary race frames 6321 (odd) and 6622 (even) differ only in the lap-time digits, the flashing red arrows and a far car (animation);
  HUD, map, speedometer and the 2D layers are identical. No stale-matrix 2D movement anywhere.
- Smoke OK (75 s, 7 frames, last mean 45).

Not covered: the pause menu (the START presses of the route did not reach it) and online/other modes. The change cannot
reach any path the route did not either, since NFSU2 draws no fixed-function batch at all.

## 13. Shared-renderer fixes from PoA (hppoa b010ad5, 918dac2; 2026-11-25, released in 0.1.3)

1. **P8 hash** (`bytes_hash_all` in `tex_get`): applied. `RECOMP_TEX_CHANGES=1` over the 150 s route (boot, menus, race grid)
   logged 348 texture changes in formats 12, 06 and 19 only: no P8 (0x0B) texture is used, so no visible change.
2. **Polygon offset slope x render scale** (`apply_dynamic`, `RECOMP_MTL_ZSLOPE=0` off): applied. The route (400 % scale)
   never logged "polygon offset in use", so no draw takes it and on/off are identical here; it only matters if a draw sets one.
3. **Texgen modes 0x8512/0x8511/0x2402**: not applicable. This port's Metal back end has no fixed-function texgen at all (no
   `u_tg`, no "not generated" warning; every draw is a vertex program), so there is nothing to extend. Not taken.
   The PoA-only `skin_second_layer` was left out as asked.
Smoke OK after the build (75 s). The route logs had no "texgen ... not generated" lines before or after.

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

## 14. Round 5 backport (PoA xemu audit, 5ef50c3..66ff266) (released in 0.1.3)

Five renderer fixes, each behind an env var (see CHANGELOG). `nv2a_clip` no longer clamps z per vertex (`VsU.u_clampv`);
`vZw` carries unclamped z/zmax and w to the fragment shader for the clip-range cull (`FsU.u_zcull`; skipped when
CONTROL0 bit 16 is set, since this port has no W-buffer). Verified: build, `tools/smoke.sh 75` OK, 150 s scripted route
with all five off vs on: both render correctly; byte compares are useless (the route diverges run to run, even new vs new).
Temporary counters showed that stencil op 0 and `lit_color` (fixed-function lighting) never run on that route and
SET_CLIP_MIN/MAX is always 0..zmax, so these are no-ops for NFSU2 as played; the shader plumbing is exercised by every draw.
