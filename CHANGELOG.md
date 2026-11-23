# Changelog

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
