# How engine/ was made

`engine/` is [myUdav4iik/nfsu2-ios](https://github.com/myUdav4iik/nfsu2-ios) at `85d2cbf` (branch `ios`; nfsu2-sw v0.5.13 by
antoxa2584x with the Apple host and the Metal renderer) with these patches applied in order (`git am`), imported on 2026-11-19
so that the port builds from this repository alone. Later changes to `engine/` are in this repository's git history.

- `0001`-`0024`: NFSU2Deadware's patches by LeoDeadware (MIT), without its HD texture loader (0005's `apple_textures.m` part,
  0010's `apple_textures.m` hunks) and its Ukrainian text and fonts (its 0024, 0025). Their numbers here differ from
  NFSU2Deadware's from 0024 on.
- `0025`-`0027`: this project's (Settings window, player folder, F1).

The upstream agent notes (`CLAUDE.md` of nfsu2-ios) are in `engine/docs/NFSU2_IOS_AGENT_NOTES.md`.
