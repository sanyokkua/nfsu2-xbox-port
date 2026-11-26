# Changelog

## 0.1.4 (2026-11-26)

Two renderer fixes from the Harry Potter Goblet of Fire port.

- Movies: a changed movie frame is never missed. The movie picture is now checked byte by byte (it was sampled), so the
  EA logo no longer stalls for about a quarter of a second as it fades in. Costs about 0.2 ms a frame while a movie plays.
- Full screen: each frame is laid out in the size of the picture it is drawn into, so frames drawn while the window is
  going full screen can no longer fill only the top-left part of the screen.
- Everything else as in 0.1.3. Installed an earlier version? Open the new installer and choose **Rebuild**: it does not
  ask for the disc again, and your saves and settings stay.

## 0.1.3 (2026-11-25)

Engine and tool fixes from the Harry Potter Prisoner of Azkaban and Chamber of Secrets ports. For players: the first
launch of a scene compiles its shaders about 3 times faster (fewer hitches), the renderer follows the original Xbox more
closely, and the build is checked more strictly. In a menu-to-race route on this game none of the rendering fixes changes
what you see; they matter for other titles on the same engine.

- Faster: shaders compile as MSL 3.0, so a program seen for the first time compiles about 3x faster (3 programs: 194 ms ->
  57 ms). `RECOMP_MTL_LANG=<major>.<minor>` overrides; `0` = Metal's default. The `[hitch]` log line also counts pipelines.
- Graphics, closer to the Xbox: depth is clamped per pixel (not per vertex) and pixels outside the clip range are dropped;
  the polygon offset slope follows the render scale; stencil op 0 is ZERO, not KEEP; the alpha test compares rounded 8-bit
  alpha; lighting no longer flips normals facing away; P8 textures are hashed byte by byte, so a changed palette texture is
  never missed. Each has an off switch (`RECOMP_MTL_ZCLAMP_PIXEL=0`, `RECOMP_MTL_ZCULL=0`, `RECOMP_MTL_ZSLOPE=0`,
  `RECOMP_MTL_STENCIL_ZERO=0`, `RECOMP_ATEST_ROUND=0`, `RECOMP_FF_FLIP_NORMALS=1`).
- Graphics: draws with vertex data pushed inline (immediate-mode style) now also work in fixed-function mode.
- Console info: the game is told the video standard is NTSC-M (it read 0 before); only titles that ask see it.
- Safer build: the function finder no longer counts calls from code decoded out of data as proof of a function start (no
  change on this disc: 20,634 functions). New tools `immscan.py` and `seedcheck.py` look for missed functions; on this
  disc there are none. `stubcheck.py` was rerun over every code section: 27 stubs, no real code.
- Debug: `RECOMP_GL_DUMP_SURF=<va,..>` dumps named render targets.
- Not ported: the learned stick range and texture-coordinate generation (CoS/PoA features this game does not use).
- Everything else as in 0.1.2. Installed an earlier version? Open the new installer and choose **Rebuild**: it does not ask
  for the disc again, and your saves and settings stay.

## 0.1.2 (2026-11-24)

Engine fixes from the Harry Potter Chamber of Secrets port:

- Renderer: textures with border addressing get the stage's own border colour (the fragment shader returns
  `SET_TEXTURE_BORDER_COLOR` outside [0, 1]); Metal samplers only have black or white borders.
- Controller: **LB is White, RB is Black** (they were swapped; as on the original controller and in xemu). The keyboard keeps
  Q = White, E = Black. A press shorter than one of the game's frames is still seen, and held for at least two reads.
- Runtime: the file handle table is locked (two threads opening files at once could share a slot); a read on a handle that
  was just closed ends the file instead of failing as a disc error; an event set hands the CPU to the thread it wakes, as
  on the Xbox (a lost wake-up hung CoS at a loading screen).
- Renderer: no copy of a render target that stays bound on a stage no shader reads (CoS: 24 -> 60 fps).
- Log: one `[metal]` line each for border addressing, W-buffer depth and fog-unit use.
  NFSU2 uses no W-buffer depth; its fog is linear with params 1, 1 (factor = coordinate, as drawn
  already), so the CoS fog unit is not ported.
- **The app no longer aborts when a controller disconnects.** Pads are opened and closed on the main thread only
  (sdl2-compat's pad list has no lock; the game thread re-scanned it while the main thread did, and freed it twice); the game
  thread only reads them. The button-glyph check also enumerates pads on the main thread now.
- Lifter: **272 pieces of real code were empty stubs.** A jump into code the disassembler had not marked as a function
  start (often a shared exit like `pop edi; pop esi; ret`) got an empty body: the pops never ran and the caller got its
  stack and registers back wrong. All 272 are seeded; `tools/stubcheck.py` (run by `tools/relift.sh`) fails when one is left.
- Runtime: a skipped wild indirect call at a caller-cleans-up site keeps esp right; timers signal before their DPC and
  inside the lock, and a set resets inside the lock (lost wake-ups), 256 timer slots; file reads and writes hold their handle
  (a close on another thread can no longer free it in use) and read at an offset in one `pread`/`pwrite`; a handle closes
  once; handle slots are handed out next-fit, 65536 of them; a stale Ke object shadow is dropped; the heap refuses a size
  larger than itself.

## 0.1.1 (2026-11-23)

- Lifter: x87 80-bit operands (`fld`/`fstp` of a 10-byte value) were read as 4-byte floats and not stored at all. The C
  runtime's asin/acos load π/2 that way, which in the Harry Potter Chamber of Secrets port turned the player 90° when the stick
  pointed straight along an axis. Now converted exactly (`recomp_ld_f80` / `recomp_st_f80`); 16 loads in this game.

## 0.1.0 (2026-11-19)

First release: the Xbox USA disc of *Need for Speed: Underground 2*, built on the player's Mac.

- Base: nfsu2-ios `85d2cbf` (nfsu2-sw v0.5.13 with the Apple host and Metal renderer).
- NFSU2Deadware's engine patches (render scale, 16:10 without bars, 30/60/120 fps, Metal anisotropic filtering, FXAA, mip
  chains, bloom, ambient occlusion, motion blur, pacing, car LOD, pad input without focus); not its HD textures and
  translation.
- In-game settings menu (Back + Start, F1 or Cmd+,), in the style of SpeedBreaker's: Display, Graphics, Audio, Input and
  Advanced pages, live where the engine allows (Frame Rate and Keyboard as Controller at the next start, marked "restart"),
  Reset page, Quit Game. The game gets no input while it is open.
- Everything the port is built from is in the repository (`engine/`): no download at build time.
- The app keeps everything in `~/Library/Application Support/NFS Underground 2`; logs in `logs/`.
- Installer DMG (no game code): imports the disc image, checks `default.xbe`, lifts and compiles the game with Apple's
  Command Line Tools, puts the app in Applications. macOS 15+.
