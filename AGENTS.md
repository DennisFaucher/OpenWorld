# AGENTS.md

Guidance for AI coding agents working on **OpenWorld**: a native macOS, Apple Silicon, Swift + Metal third-person "open world" prototype in the visual style of a bright tropical island (stylized, saturated, low-poly, lots of water). See `PROJECT_PLAN.md` for status and next steps.

## Quick start

```bash
swift build -c release          # build (first build ~15 s, incremental ~3 s)
swift run -c release            # launch the windowed game
.build/release/OpenWorld --shot shots/out.png   # render one frame headlessly to PNG
```

Always use `-c release`. Terrain/props generation does hundreds of thousands of noise evaluations at launch and is very slow in debug.

Requirements: macOS 14+, Apple Silicon, Xcode/Swift 6.x toolchain. There is no Xcode project; it is a plain SwiftPM executable (`Package.swift`, tools-version 6.0, **Swift language mode 5**).

## Verifying visual changes (important)

You cannot "see" the live window, so use the headless screenshot mode and look at the PNG:

```bash
.build/release/OpenWorld --shot shots/x.png \
  [--pos X Z] [--yaw RAD] [--pitch RAD] [--dist D] [--time T] [--size W H]
```

- Runs 90 simulation steps (so physics/camera settle), then renders a single 4x-MSAA frame offscreen. Default 1920x1080.
- `--pos` places the player on the terrain at (X, Z). `--yaw` is camera orbit angle (0 = camera on +Z side looking toward -Z; pi = the default spawn view). `--time` sets the animation clock (water/clouds).
- Several shots can run in parallel (`&` then `wait`).
- Don't place test positions inside building footprints (see `World.buildProps` specs, plaza centre is (-18, 22)); the camera collision will pull in to its 1.5 minimum and you'll get a useless close-up.
- Use `Read` on the PNG to inspect it. Good standard views: spawn (default), a beach (`--pos -50 40 --yaw 1.9 --pitch 0.22 --dist 10`), and an overview (`--pos -18 5 --yaw 0.5 --pitch 0.85 --dist 90`).
- `shots/` holds reference renders from the initial version.

Live input (keyboard, mouse capture, gamepad) is **not** covered by the headless path and has only been smoke-tested (app launches and stays up). If you change input code, say clearly that it is unverified, or ask the user to try it.

## Architecture / file map

All code is in `Sources/OpenWorld/`:

| File | Responsibility |
|---|---|
| `main.swift` | Entry point. `--shot` headless mode, otherwise starts `NSApplication` + `AppDelegate`. |
| `AppDelegate.swift` | Window, menu (Quit, Toggle Full Screen), and `GameView` (an `MTKView` subclass that turns key/mouse events into `Input` state, handles mouse capture). |
| `Game.swift` | `Input` state, `Key` codes, `Game`: player physics (gravity, jump, swim buoyancy, terrain snap), obstacle push-out, orbit camera with collision, gamepad via `GameController`. No rendering. |
| `World.swift` | Procedural terrain `height(x,z)` + `normal`, terrain mesh, height texture for the water shader, props (palms, bushes, flowers, houses, tower) and the `Obstacle` list. |
| `MeshBuilder.swift` | `Vertex` struct and CPU mesh helpers (quad, box, pyramid, frustum, sphere, palm tree). |
| `Renderer.swift` | Metal setup, pipelines, frame encode (shadow map -> HDR scene -> bloom -> composite), player drawing from sphere parts, headless `renderPNG`. Also the `MTKViewDelegate`. |
| `Shaders.swift` | All MSL as one Swift raw string, compiled at launch via `makeLibrary(source:)`. |
| `MathUtil.swift` | `V2/V3/V4/M4` aliases, matrix helpers (Metal 0...1 depth, right-handed), `lerp`, `sstep`, `RNG`. |

### Frame order

1. Shadow map (`encodeShadowMap`): depth-only render from the sun into a 4096² `depth32Float`, orthographic ±160.
2. Scene (`encodeScene`) into the MSAA HDR target (`rgba16Float`), resolved: sky (fullscreen triangle at far plane, depth test off, view ray via `invViewProj`), opaque (terrain, props, player parts, `vs_main`/`fs_main`), water (camera-centred grid, alpha blended, depth-tested, no depth write, no shadows).
3. Bloom: bright pass at half res (threshold 1.0, knee 0.5) -> two ping-pong 9-tap separable blurs.
4. Composite: scene + 0.30 * bloom -> highlight-only soft-knee tone curve -> drawable.

## Conventions and gotchas

- **Struct layouts are mirrored by hand** between Swift and MSL: `Vertex` (3x float4, 48 B) <-> `VIn`; `FrameUniforms` <-> `Frame`; `ObjUniforms` <-> `Obj`. Change both sides together. Buffer indices: 0 = vertices, 1 = `Frame`, 2 = `Obj`.
- **`nrm.w` is a translucency flag**, not padding: `MeshBuilder.add(..., translucency:)` writes it and `fs_main` uses it to let sunlight bleed through thin foliage (palm fronds). It is read straight from `in.nrm.w`, so it deliberately bypasses `normalMat`.
- **Culling is off everywhere.** Two-sided lighting is *blended*, not flipped: `fs_main` weights the front- and back-facing diffuse terms by `smoothstep(-0.12, 0.12, dot(Ng, V))`. Do not reintroduce a hard `if (dot(N, V) < 0) N = -N;` — it puts a discontinuity exactly where the ground is tangent to the view, which showed up as a dotted dark seam along shorelines. Triangle winding in `MeshBuilder` still does not matter; don't turn culling on without auditing the meshes.
- **Terrain is flagged by vertex alpha = 0.5** (props/characters use 1.0). `fs_main` uses `col.a < 0.75` to add ground detail and the plaza checker pattern (analytic, from `PLAZA`/`PLAZA_R` constants injected into the shader source from `World`). Ground detail only *modulates* the vertex colour — `World.buildTerrain` owns the sand/grass/rock blend, so re-deriving those masks in the shader double-blends them. Detail octaves fade through `aaNoise` keyed on `max(fwidth(p).x, fwidth(p).y)`; summing the two axes over-fades on flat ground seen obliquely.
- **World constants are shared with the shader** through string interpolation in `Shaders.swift` (`World.extent`, `plazaCenter`, `plazaRadius`). If you change them, the height texture and shader stay in sync automatically; don't hard-code duplicates.
- **Height is analytic and CPU-side**: `World.height(x,z)` is the single source of truth for terrain mesh, normals, water-depth texture, placement, player physics, and camera collision. Keep it deterministic and cheap.
- **Underwater is a shader state, not a separate pass.** Everything is driven by `uwAmount(camY)` (0 above, 1 below, crossfaded over `+0.30 .. -0.10`). `applyFog`, `fs_sky` and `fs_water` all branch on it, and everything decays to the single constant `UWFOG` — do not give the underwater fog a height-dependent target colour, or the distant seabed and distant surface converge to different colours and the far waterline draws a hard dark bar. `Game.updateCamera` only lets the camera drop below the surface while `swimming`; on land it is clamped above the waterline.
- Water level is y = 0, seabed is -4, swimming rest height is `Game.swimY` (-0.8). Terrain mesh covers +/-120; players are clamped to radius 104.
- Water grid vertices are in a quadratic radial layout centred on the camera (fine near, coarse far). Vertex wave amplitude is deliberately small because vertices move with the camera; fine detail comes from fragment normals.
- Colors are authored directly in display space (framebuffer is `bgra8Unorm`, no gamma handling). Keep that consistent.
- **Shadow mapping gotchas.** `sunDir` points *towards* the sun, so the light camera must sit at `+sunDir * 300`; `-sunDir` puts it under the island and shadows silently vanish. Sample the depth map with `sample_compare` (a `depth2d<float>` and a compare-function sampler), remap light clip space as `uv = (x*0.5+0.5, 0.5-y*0.5)`, and use clip `z/w` directly as the depth (Metal depth is already 0...1, don't rescale it).
- Code style: match the existing files: compact, few comments (explain *why*, not *what*), `///` on non-obvious types, Swift naming, `V3(...)` style. Don't add dependencies.
- Shaders compile at launch, so MSL errors show up at runtime as a `fatalError` with the compiler message; run `--shot` after any shader edit.

## Constraints

- **No Nintendo (or other third-party) assets, names, characters, or ripped models/textures.** The target is an *original* world in a similar stylized-tropical aesthetic. The character is an original design. Keep it that way.
- Don't commit large binary assets without asking. There is currently no git repository in this folder.

## Definition of done for a change

1. `swift build -c release` succeeds with no new warnings.
2. For anything visual: at least the default spawn shot and one relevant shot rendered and inspected.
3. For gameplay/input changes: state what you could and could not verify headlessly.
4. Update `PROJECT_PLAN.md` (check off items, add known issues).
