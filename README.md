# OpenWorld

A native macOS third-person island prototype in a bright, stylized, low-poly tropical style. Swift and Metal, no engine, no asset files — the terrain, water, props and character are all generated from code at launch.

![The island from above](docs/overview.jpg)

## Download

Grab a build from the [releases page](https://github.com/DennisFaucher/OpenWorld/releases) — `OpenWorld-vX.Y-macos-arm64.zip`, unzip it and run `./OpenWorld`. macOS 14 or later on Apple Silicon.

The binary is unsigned, so macOS quarantines it on first launch. Right-click it and choose **Open** once, or clear the flag with `xattr -dr com.apple.quarantine ./OpenWorld`.

Or build it from source below.

## Requirements

- macOS 14 or later on Apple Silicon
- Swift 6 toolchain (Xcode 16, or the standalone Swift toolchain)

## Build and run

```bash
swift build -c release
swift run -c release
```

Always use `-c release`. Terrain and prop generation evaluates a few hundred thousand noise samples at launch and is very slow in a debug build.

## Controls

| Input | Action |
| --- | --- |
| `W` `A` `S` `D` | Move, relative to the camera |
| `Shift` | Sprint |
| `Space` | Jump |
| Mouse | Orbit the camera (click the window first to capture the cursor) |
| Left mouse / `F` | Hold to fire the water jet (after the cursor is captured) |
| Aim down + fire | Lift off on the jet — the pack holds about three seconds of water and refills in the sea |
| Arrow keys | Orbit the camera |
| `R` | Respawn |
| `Esc` | Release the captured cursor |

Gamepad: left stick moves, right stick orbits, right trigger sprints, `A` jumps.

Swimming out into open water and pitching the camera down dips it below the surface.

## Headless rendering

The game can render a single frame to a PNG without opening a window, which is how the visuals were checked during development:

```bash
.build/release/OpenWorld --shot shots/beach.png --pos -50 40 --yaw 1.9 --pitch 0.10 --dist 9
```

| Flag | Meaning |
| --- | --- |
| `--shot PATH` | Render one frame to `PATH` and exit |
| `--pos X Z` | Place the player on the terrain at `X, Z`. Also a spawn override for the live window, so a play-test does not start with a run across the island |
| `--yaw RAD` | Camera orbit angle (`0` puts the camera on `+Z`, `pi` is the spawn view); pairs with `--pos` in the live window |
| `--pitch RAD` | Camera elevation |
| `--dist D` | Camera distance |
| `--time T` | Animation clock, for the water and clouds |
| `--hour H` | Time of day, `0`–`24`; `12` (the default) is the original key light |
| `--walk` | Hold forward for the simulated frames, so wakes and splashes can be checked |
| `--spray` | Hold the water jet for the simulated frames |
| `--spray-frames N` | Fire for the first `N` frames and then let go, so the wet patches can be seen drying |
| `--frames N` | Number of simulation steps before the frame, default `90`; use it to catch a splash mid-air |
| `--sim N` | Skip rendering and print the player state (position, velocity, grounded, swimming, FOV, terrain slope, current pose) for `N` frames — how jump timing and the stride were measured |
| `--jump F D` | Press jump at frame `F` and hold it for `D` frames, with `--sim` or `--shot`. Repeat the flag for several presses |
| `--look RAD` | With `--shot`: orbit the finished frame by `RAD` without re-simulating, for a side view of a run cycle |
| `--slope-scan` | Print a histogram of the terrain gradient — how the 45° walkable limit was picked |
| `--size W H` | Output resolution, default 1920x1080 |

It runs 90 simulation steps first so physics and the camera settle, then renders one 4x-MSAA frame offscreen.

`.build/release/OpenWorld --version` prints the version.

## What's in it

- **Terrain.** An analytic height function (`World.height`) — value-noise fbm warped into an island profile — sampled into a 240x240 mesh. Sand, grass and rock are blended per vertex by height and slope, with fragment-space detail layered underneath that fades out before it can alias.
- **Spray pack.** Hold the trigger and the character raises a nozzle and fires a water jet along the camera: a ballistic stream cut off exactly where it lands, a splash at the impact, and a wet patch that dries over a few seconds. The body turns to the jet while the legs keep walking.
- **Hover and washing.** Aim the jet at your feet and the thrust lifts you, at a steady climb that lasts as long as the tank does (the tank on the character's back shrinks as it empties) and refills when you swim or wade. Twelve splats of goo are stuck to the plaza and the paths; a jet on one wears it away and tints the splash.
- **Water.** A camera-centred radial grid with summed travelling waves, depth-based shallow/deep colour read from a height texture, Fresnel sky reflection, sun glitter, refracted shoreline, and animated foam along the shore. Swimming and wading leave foam and spray behind.
- **Ground contact.** Every footfall kicks up dust tinted by the ground it came off — sand, dry grass or rock — plus a wider cloud on landing, a skid trail while sliding, and a scuff when you push into a face too steep to climb.
- **Underwater.** Absorption fog, caustics on submerged surfaces, and the surface seen from below with the Snell window and total internal reflection.
- **Sky and time of day.** One cloud layer at a fixed altitude, drawn both by the sky (where the view ray meets it) and by shading (projected along the sun), so drifting cloud shadows cross the island under the clouds that cast them. `--hour` swings the sun across the sky, warming and dimming as it drops.
- **Props.** Palms, bushes, flowers, houses and a tower, all built from the same handful of mesh primitives, with collision shapes for the camera and the player.
- **Character.** An original design assembled from sphere primitives, rigged two segments per limb, with idle, run, jump, fall, swim and slide poses. States are weight-blended, so a jump eases out of the run instead of snapping.
- **Movement.** Variable jump height with coyote time and input buffering, sprinting, wading and swimming. Ground steeper than 45° can't be walked up — the player slides down the fall line instead, whatever the stick says.
- **Lighting.** A 4096x4096 directional shadow map with hardware PCF, hemispheric ambient with a baked contact shadow where walls meet the ground, plus HDR rendering with bloom and a highlight-only tone curve.
- **Camera.** Orbit with collision against terrain and props.

![Washing goo off the plaza](docs/spray.jpg)

![Hovering over the plaza](docs/hover.jpg)

![Running the beach](docs/beach.jpg)

![On the plaza at spawn](docs/spawn.jpg)

![Late afternoon](docs/dusk.jpg)

![Under the surface](docs/underwater.jpg)

## Layout

All code lives in `Sources/OpenWorld/`:

| File | Responsibility |
| --- | --- |
| `main.swift` | Entry point; `--shot` headless mode, otherwise starts `NSApplication` |
| `AppDelegate.swift` | Window, menu, and the `MTKView` that turns key/mouse events into input state |
| `Game.swift` | Player physics, swimming, obstacle push-out, orbit camera with collision, gamepad |
| `Particles.swift` | CPU particle pool for wakes, splashes, footfall dust, skids and jet spray |
| `Spray.swift` | The water jet: aim, the solved ballistic arc, wet patches and the goo splats |
| `World.swift` | Terrain height and normals, terrain mesh, height texture, props, obstacles |
| `MeshBuilder.swift` | CPU mesh primitives: quad, box, pyramid, frustum, sphere, palm |
| `Renderer.swift` | Metal setup, render passes, bloom chain, headless PNG output |
| `Player.swift` | Character rig: proportions, per-state poses, weight blending, sphere parts |
| `Shaders.swift` | All Metal Shading Language, compiled at launch |
| `MathUtil.swift` | Vector/matrix helpers |

`PROJECT_PLAN.md` tracks milestones and known rough edges; `AGENTS.md` documents the architecture in more detail, including the parts that are easy to break.

## Status

Playable prototype, `v2.0`. Two milestones are complete. **Look and feel:** terrain detail, water, shadows, bloom, the underwater view, drifting cloud shadows, time of day. **Character and movement:** variable jump height with coyote time and buffering, camera look-ahead and recentring, a measured 45° walkable limit with sliding, a rigged character with six weight-blended states, and ground-contact particles. Next is the water-jet mechanic, then world content.

The repository is not a complete game — there is no goal, no saving, and no audio.

## Notes

All art is generated in code. Nothing is ripped, imported, or derived from another game.
