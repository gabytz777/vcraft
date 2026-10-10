# VCraft

A small Minecraft-like voxel sandbox written entirely in [V](https://vlang.io).
Procedural terrain, biomes, water, mining/building, a hotbar, and a HUD — no
Mojang assets, all textures are generated as pixel art at startup.

## Build

Needs V (with the `gcc` backend) plus the system `SDL2`, `EGL`, `OpenGL`, and
`zlib` dev libraries.

```sh
./build.sh          # -> build/vcraft
```

## Run

```sh
./build/vcraft
```

Controls: `WASD` move · mouse look · `LMB` break · `RMB` place · `1-9` hotbar ·
`[` `]` cycle · `space` jump · `shift` sneak · `ctrl` sprint · `F` fly · `Esc` quit.

## How it's built

- **All game logic is in V.** `src/` holds world generation, meshing, physics,
  raycasting, textures, and input handling.
- **No project-owned C.** `src/ffi.v` talks to SDL2 / EGL / OpenGL / zlib
  directly through V's FFI — those libraries only expose a C ABI, but every line
  of our own platform code is V.
- **Headless self-test.** An EGL surfaceless context plus synthetic input
  injection drive a full render + input + physics test with no window or human:

  ```sh
  EGL_PLATFORM=surfaceless VHEADLESS=1 VTEST=1 ./build/vcraft
  ```

  It prints a per-test line and `SELFTEST PASS`.
