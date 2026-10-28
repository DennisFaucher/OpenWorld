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
  [--pos X Z] [--yaw RAD] [--pitch RAD] [--dist D] [--time T] [--hour H] [--walk] [--frames N] [--size W H] \
  [--jump F D] [--look RAD] [--spray] [--spray-frames N]

.build/release/OpenWorld --sim 60 [--walk] [--walk-fast] [--pos X Z] [--yaw RAD] [--jump F D]   # physics trace, no render
.build/release/OpenWorld --slope-scan                                    # terrain gradient histogram
```

- Runs 90 simulation steps (so physics/camera settle), then renders a single 4x-MSAA frame offscreen. Default 1920x1080.
- `--pos` places the player on the terrain at (X, Z). The live window honours `--pos`/`--yaw` too, which is the fast way to play-test one spot: `.build/release/OpenWorld --pos 60 -30 --yaw 1.571` drops you at the foot of the steep scarp instead of a 90 s run away. `--yaw` is camera orbit angle (0 = camera on +Z side looking toward -Z; pi = the default spawn view). `--time` sets the animation clock (water/clouds); `--hour` (0-24, default 12) moves the sun, which also moves the cloud shadows.
- `--walk` holds forward for the simulated frames. Use it for anything that only happens while moving — test candidate: a swimming wake, `--pos 62 62 --yaw 0.9 --pitch 0.32 --dist 9 --walk`.
- `--sim N` runs the same simulation with no window and no render, printing `x, y, z, vy, grounded, swimming, fov, slope`, then the current pose (`hipL`, `hipR`, `kneeL` in degrees and `speedNorm`), per frame. It honours `--pos`, `--walk`, `--walk-fast` and `--yaw`. `--jump F D` presses jump at frame `F` for `D` frames (repeatable), which is how jump height, the buffer and the coyote window are measured. This is the only way to check movement timing without a keyboard. The `slope` column is the terrain angle in degrees at the player, which is how the 45° walk limit was checked.
- `--slope-scan` walks a 1 m grid over the island and histograms `World.normal().y`. Use it before picking any slope threshold: the island peaks at 65° around (55, -38) and only 1% of the sampled area is past 45°.
- `--jump F D` works on the shot path too, so an airborne frame can be rendered (jump at frame `F`, hold `D`). `--look RAD` re-orbits the *finished* frame without re-simulating: turning the camera before the frames also turns the player, because the controls are camera-relative, so this is the only way to see a run cycle from the side.
- `--spray` holds the trigger; `--spray-frames N` fires for `N` frames and then lets go, which is how a wet patch was checked after the stream stopped. Because the jet is aimed along the camera, a straight-behind shot looks straight down the stream and shows almost nothing: use `--look 1.57` for a side view of it.
- Several shots can run in parallel (`&` then `wait`).
- Don't place test positions inside building footprints (see `World.buildProps` specs, plaza centre is (-18, 22)); the camera collision will pull in to its 2.2 minimum and you'll get a useless close-up.
- Use `Read` on the PNG to inspect it. Good standard views: spawn (default), a beach (`--pos -50 40 --yaw 1.9 --pitch 0.10 --dist 9`), an overview (`--pos 40 -30 --yaw 2.6 --pitch 0.55 --dist 110`), the plaza (`--pos -18 40 --yaw 3.14 --pitch 0.22 --dist 22`), underwater (`--pos 62 62 --yaw 0.9 --pitch -0.28 --dist 5`).
- `shots/` holds reference renders from the initial version.

Live input (keyboard, mouse capture, gamepad) is **not** covered by the headless path and has only been smoke-tested (app launches and stays up). If you change input code, say clearly that it is unverified, or ask the user to try it.

## Architecture / file map

All code is in `Sources/OpenWorld/`:

| File | Responsibility |
|---|---|
| `main.swift` | Entry point. `--shot` headless mode, otherwise starts `NSApplication` + `AppDelegate`. |
| `AppDelegate.swift` | Window, menu (Quit, Toggle Full Screen), and `GameView` (an `MTKView` subclass that turns key/mouse events into `Input` state, handles mouse capture). |
| `Game.swift` | `Input` state, `Key` codes, `Game`: player physics (gravity, jump, swim buoyancy, terrain snap), obstacle push-out, orbit camera with collision, gamepad via `GameController`. Spawns water spray. No rendering. |
| `Particles.swift` | `Particle` and `ParticleSystem`: a CPU pool of billboarded droplets, foam, dust and jet spray, integrated in `Game.update`. |
| `Spray.swift` | The water jet: nozzle placement and aim, the ballistic arc solved once per frame, and the `Decal` list of wet patches. |
| `Player.swift` | The character. `PlayerPose` (joint angles), `Player.State` (idle, run, rise, fall, swim, slide), per-state poses, weight blending, and `Player.parts` which turns a pose into sphere transforms. |
| `World.swift` | Procedural terrain `height(x,z)` + `normal`, terrain mesh, height texture for the water shader, props (palms, bushes, flowers, houses, tower) and the `Obstacle` list. |
| `MeshBuilder.swift` | `Vertex` struct and CPU mesh helpers (quad, `quad4`, box, `groundedBox`, pyramid, frustum, sphere, palm tree). |
| `Renderer.swift` | Metal setup, pipelines, frame encode (shadow map -> HDR scene -> bloom -> composite), character drawn from `Player.parts`, headless `renderPNG`. Also the `MTKViewDelegate`. |
| `Shaders.swift` | All MSL as one Swift raw string, compiled at launch via `makeLibrary(source:)`. |
| `MathUtil.swift` | `V2/V3/V4/M4` aliases, matrix helpers (Metal 0...1 depth, right-handed), `lerp`, `sstep`, `RNG`. |

### Frame order

1. Shadow map (`encodeShadowMap`): depth-only render from the sun into a 4096² `depth32Float`, orthographic ±160.
2. Scene (`encodeScene`) into the MSAA HDR target (`rgba16Float`), resolved: sky (fullscreen triangle at far plane, depth test off, view ray via `invViewProj`), opaque (terrain, props, player parts, `vs_main`/`fs_main`), water (camera-centred grid, alpha blended, depth-tested, no depth write, no shadows).
3. Bloom: bright pass at half res (threshold 1.0, knee 0.5) -> two ping-pong 9-tap separable blurs.
4. Particles (`encodeParticles`): the CPU pool is rebuilt as camera-facing quads into one dynamic buffer and drawn after the water, depth-tested, no depth write. Skipped while the camera is submerged, because the water plane is opaque from below but writes no depth.
5. Composite: scene + 0.30 * bloom -> highlight-only soft-knee tone curve -> drawable.

## Conventions and gotchas

- **Struct layouts are mirrored by hand** between Swift and MSL: `Vertex` (3x float4, 48 B) <-> `VIn`; `FrameUniforms` <-> `Frame`; `ObjUniforms` <-> `Obj`. Change both sides together. Buffer indices: 0 = vertices, 1 = `Frame`, 2 = `Obj`.
- **`nrm.w` is a translucency flag**, not padding: `MeshBuilder.add(..., translucency:)` writes it and `fs_main` uses it to let sunlight bleed through thin foliage (palm fronds). It is read straight from `in.nrm.w`, so it deliberately bypasses `normalMat`.
- **Culling is off everywhere.** Two-sided lighting is *blended*, not flipped: `fs_main` weights the front- and back-facing diffuse terms by `smoothstep(-0.12, 0.12, dot(Ng, V))`. Do not reintroduce a hard `if (dot(N, V) < 0) N = -N;` — it puts a discontinuity exactly where the ground is tangent to the view, which showed up as a dotted dark seam along shorelines. Triangle winding in `MeshBuilder` still does not matter; don't turn culling on without auditing the meshes.
- **Terrain is flagged by vertex alpha = 0.5** (props/characters use 1.0). `fs_main` uses `col.a < 0.75` to add ground detail and the plaza checker pattern (analytic, from `PLAZA`/`PLAZA_R` constants injected into the shader source from `World`). Ground detail only *modulates* the vertex colour — `World.buildTerrain` owns the sand/grass/rock blend, so re-deriving those masks in the shader double-blends them. Detail octaves fade through `aaNoise` keyed on `max(fwidth(p).x, fwidth(p).y)`; summing the two axes over-fades on flat ground seen obliquely.
- **World constants are shared with the shader** through string interpolation in `Shaders.swift` (`World.extent`, `plazaCenter`, `plazaRadius`). If you change them, the height texture and shader stay in sync automatically; don't hard-code duplicates.
- **Height is analytic and CPU-side**: `World.height(x,z)` is the single source of truth for terrain mesh, normals, water-depth texture, placement, player physics, and camera collision. Keep it deterministic and cheap.
- **Cloud shadows and the sky share one field.** `cloudField(xz, time)` is a noise field on a plane at `CLOUD_H` (260). `fs_sky` intersects it along the view ray, `fs_main` projects it along the sun (`cloudShade`), so a shadow crossing the island belongs to the cloud above it. Change the frequency or the drift in `cloudField` and both follow.
- **The sun comes from `Renderer.sun(hour:)`.** `--hour` moves it along an arc that passes exactly through the original key light at 12:00; the light colour rides in `Frame.sunCol` (there is no `SUNCOL` constant any more). Anything that tints sunlit surfaces must use `f.sunCol.rgb`, or a sunset will keep white highlights.
- **Underwater is a shader state, not a separate pass.** Everything is driven by `uwAmount(camY)` (0 above, 1 below, crossfaded over `+0.30 .. -0.10`). `applyFog`, `fs_sky` and `fs_water` all branch on it, and everything decays to the single constant `UWFOG` — do not give the underwater fog a height-dependent target colour, or the distant seabed and distant surface converge to different colours and the far waterline draws a hard dark bar. `Game.updateCamera` only lets the camera drop below the surface while `swimming`; on land it is clamped above the waterline.
- **Movement feel lives in `Game.update`.** Variable jump height trims `vel.y` by 0.42 when the button is released mid-rise; `Game.coyote` (0.12 s) and `Game.jumpBufferTime` (0.12 s) cover late and early presses; falling uses 42 m/s² against 30 rising. The coyote window is barely exercised: the only ground steeper than the walk limit is the rocky outcrop at (55, -38), and every drop off it ends in the sea, where swimming makes jumping legal anyway. It only becomes observable in play once the world has dry cliffs.
- **The vertical snap will climb anything, so slopes are gated by the horizontal move.** `if np.y <= g { np.y = g }` lifts the player onto whatever is under them, which made every face walkable. Two guards in `Game.update` cover it: a step into ground past `Game.walkSlopeY` (45°) keeps only the contour-parallel component, and standing on such ground replaces the input-driven velocity with a slide down the fall line (`slideAccel` 34, `slideDrag` 2/s). Measure any threshold change with `--slope-scan` first — the 45° value is what keeps the 44° mountain flank climbable. While `sliding` the step-down snap widens from 0.35 m to 0.9 m per frame, otherwise the player skips down the face instead of riding it.
- **The character is `Player.swift`, and its states blend by weight, not by joint.** Each state (idle, run, rise, fall, swim, slide) is a pure function of `walkPhase`/`time`; `Game.poseWeights` eases toward the active one and `Player.pose(weights:)` sums them. Do *not* go back to low-passing the accumulated pose: a filter on the joints flattens cyclic motion (at 10/s against a 2 Hz stride the hip swing dropped from 46° to 29° and the run read as a shuffle). A new state is a new `State` case plus a pose function; nothing else needs to know.
- **Rig conventions.** Limb angles are positive forward, so every joint applies `rotationX(-angle)`. `out` is a Z rotation in the torso frame, which means the same sign abducts a hanging arm and *adducts* a raised one — the rise pose uses a negative value to spread the arms overhead. `parts` builds from the pelvis down, so the feet sit on y = 0 in every pose; the rig's joint heights are its proportions. Adding a part is one `add(...)` line and one more draw call (the character is ~20 spheres, drawn in both the shadow and scene passes).
- **Camera.** `curDist` never collapses below 2.2 and the look-ahead offset fades out under `curDist` 2.5, because the boom's pivot is pushed forward: with the old 1.5 m minimum a pulled-in camera ended up inside the player's head. The boom is anchored 2.15 m above the feet, not at the chest: the camera looks *at* that point, so at chest height the whole middle of the screen was the character, and whatever you were aiming at sat behind them.
- Water level is y = 0, seabed is -4, swimming rest height is `Game.swimY` (-0.8). Terrain mesh covers +/-120; players are clamped to radius 104.
- **Water depth is measured from mean sea level**, `-ground`, not from the displaced surface `wp.y`. Using `wp.y` made the shallow band and the shoreline foam follow the wave crests and smear into vertical streaks.
- **Particles.** `Particle.kind` is the look (0 droplet, 1 foam, 2 dust, 3 spray, 4 wet patch) and is carried into the shader as `nrm.z`; gravity is only physics. The wet patches are not particles: they are `Game.decals` quads emitted into the same vertex buffer, oriented to the terrain normal, so they need no pipeline of their own. Foam is pinned to `y = 0.05`, squashed into an ellipse and faded at grazing angles. Foam and dust are both broken up with world-space noise — a plain soft disc reads as a bubble no matter how it is tinted — but dust needs a higher noise frequency and a softer edge, because its sprites are small. Never splash on every `swimming` transition without the cooldown: buoyancy bobbing will fire it repeatedly.
- **The jet is one solved arc, not collided droplets.** `Spray.impact` marches the ballistic path once per frame and returns the hit *and its time*; the droplets are then given exactly that lifetime, so the stream ends on the surface. If you let them live their full life they carry on through it and read as a cloud of foam lying on the ground. The splash and the wet patch use the same point, so they cannot disagree.
- **The jet is aimed at a point, not fired along the view.** `Spray.aim` marches the eye ray (`Spray.rayHit`) and then solves the launch elevation that puts the arc *through* that point at a fixed 26 m/s, taking the flatter of the two solutions. Firing along the camera direction instead — which is what it did first — lands several metres short on any downward aim, because the drop over half a second is real; the stream then visibly refuses to reach the splat in front of it. Only if the target is unreachable or the ray hits nothing does it fall back to shooting along the view.
- **The reticle is screen-space because the aim point is behind the player.** The camera looks at the player, so the ground under the middle of the screen is always behind their body, and a world-space marker (a ring quad in the particle buffer) was never visible. A ring at `res * 0.5` is not a compromise: since the arc is solved to the eye-ray hit, the middle of the screen *is* where the water lands. It is drawn in `fs_bloom_composite` from the same `gauge` uniform as the tank bar — `gauge = (level, dry, aimValid, 0)` — and `Renderer.setGauge` must pass `MemoryLayout<V4>.stride`. With the old `V2` stride only the first two floats upload, which draws the bar perfectly and silently disables the reticle, since its flag reads as zero.
- **Hover thrust must beat falling gravity.** `Game` adds `(44 + 18 * t) * dt` with `t` from how far the aim points down, against 42 m/s² of falling gravity: below 42 the pack cannot break contact with the ground and the snap holds the player down forever, which is exactly what the first version did. The climb is capped at `4 * t` m/s. The tank drains `0.07`/s, plus `0.26`/s once the aim is more than ~25° down, so washing lasts ~14 s and lifting ~3 s; a single rate made a hover burst and a long wash the same thing. The drain has to be able to reach zero (clamping at zero each frame left a sliver that sputtered), and the gauge turns amber under 25% — amber and aqua blended across the whole range made a muddy olive, so the crossfade is a narrow band at 0.22–0.28.
- **Goo and wet patches share one pass.** They are `kind` 5 and 4 quads in the particle buffer, emitted *before* the sprites because nothing in that pass writes depth, so emission order is paint order: goo, wet patches, spray. Goo radius scales with health, so washing visibly shrinks the splat before it goes.
- **Aiming turns the body.** The spray input overrides `pose.shoulderR`/`elbowR`/`outR` and eases `facing` toward the aim yaw, because the arm and the stream have to point the same way. It is the one place joint angles are overridden directly rather than blended by state weight: a held aim pose has no cyclic motion to flatten, and the legs keep their own state.
- **Footfall detection is the walk phase, not a timer.** The stride advances by pi per step, so `Int(walkPhase / pi)` changing is a contact and its parity is which foot. Dust is emitted on dry ground only (`g > 0.02`) — wading has its own spray. A puff spawned at the feet on a steep face is *inside* the terrain and never draws, since particles are depth-tested: the skid cloud is lifted and given upward velocity.
- **Building walls are baked with a contact shadow.** `MeshBuilder.groundedBox` emits each wall as three vertical bands (below ground, an AO ramp, plain wall) using `quad4` per-corner colours, because there is no SSAO. Plain `box` has no such ramp — use `groundedBox` for anything that stands on the terrain.
- Water grid vertices are in a quadratic radial layout centred on the camera (fine near, coarse far). Vertex wave amplitude is deliberately small because vertices move with the camera; fine detail comes from fragment normals.
- Colors are authored directly in display space (framebuffer is `bgra8Unorm`, no gamma handling). Keep that consistent.
- **Shadow mapping gotchas.** `sunDir` points *towards* the sun, so the light camera must sit at `+sunDir * 300`; `-sunDir` puts it under the island and shadows silently vanish. Sample the depth map with `sample_compare` (a `depth2d<float>` and a compare-function sampler), remap light clip space as `uv = (x*0.5+0.5, 0.5-y*0.5)`, and use clip `z/w` directly as the depth (Metal depth is already 0...1, don't rescale it).
- Code style: match the existing files: compact, few comments (explain *why*, not *what*), `///` on non-obvious types, Swift naming, `V3(...)` style. Don't add dependencies.
- Shaders compile at launch, so MSL errors show up at runtime as a `fatalError` with the compiler message; run `--shot` after any shader edit.

## Constraints

- **No Nintendo (or other third-party) assets, names, characters, or ripped models/textures.** The target is an *original* world in a similar stylized-tropical aesthetic. The character is an original design. Keep it that way.
- Don't commit large binary assets without asking. The package is versioned in git and published at https://github.com/DennisFaucher/OpenWorld; `.build/` and `shots/` are ignored, and `docs/` holds the README screenshots.

## Definition of done for a change

1. `swift build -c release` succeeds with no new warnings.
2. For anything visual: at least the default spawn shot and one relevant shot rendered and inspected.
3. For gameplay/input changes: state what you could and could not verify headlessly.
4. Update `PROJECT_PLAN.md` (check off items, add known issues).
