# OpenWorld: Project Plan

## Vision

A native macOS (Apple Silicon, Metal) third-person open-world game you can walk around, with the bright, saturated, stylized tropical-island look of an early-2000s platformer: low-poly geometry, simple textures, vivid water, sunny sky. All art and characters are **original** (no third-party/Nintendo assets). Target hardware: M4 Pro, 60-120 fps at native resolution with MSAA.

Tech stack: Swift 6 toolchain (language mode 5), Metal (runtime-compiled MSL), MetalKit, GameController, SwiftPM. See `AGENTS.md` for architecture and workflow.

## Status: Milestone 0 complete (prototype)

Done and verified via headless renders (live input only smoke-tested):

- [x] SwiftPM executable, runtime-compiled shaders, windowed `MTKView` app with menu + full screen
- [x] Procedural island terrain (beach, grass, hills, mountain, plaza terrace), 240x240 mesh
- [x] Props: 80 palms, bushes, flowers, 5 plaza houses, bell tower
- [x] Sky shader (gradient, sun, procedural clouds) and distance fog
- [x] Water: waves, depth-based shallow/deep color, Fresnel sky reflection, sun glitter, animated shoreline foam, camera-centred grid out to 1500 units
- [x] Player: original character from sphere parts, walk cycle, blob shadow, wading, swimming (buoyancy)
- [x] Physics: gravity, jump, run, terrain snapping, world bounds, circle/AABB obstacle push-out
- [x] Orbit camera with mouse (captured), arrow keys, gamepad; collision against terrain and obstacles
- [x] Headless `--shot` renderer for visual verification

## Known issues / rough edges

Fix opportunistically; none block the next milestones.

1. **Live input unverified.** Mouse capture, key handling, gamepad, and `swift run` window activation have not been exercised interactively. First task for anyone with a display: play it for a minute and fix whatever feels off (sensitivity, camera lag, jump feel, stuck keys).
2. ~~**Thin dark line at some shorelines**~~ (fixed). Root cause was the two-sided lighting hard-flipping the normal at `dot(N,V) = 0`, which lands exactly on the line where the ground is tangent to the view; it is now a smooth front/back blend. The shallows were also made to fade in gradually (alpha ramp + wider `shallow` falloff) instead of going opaque within ~1 m of depth.
3. **Plaza terrace:** the plaza is a flat disc blended into rising hills, so there is a visible bowl/rim with some muddy rock-colored slope near it. Consider lowering surrounding hills there, a retaining wall mesh, or steps.
4. **Shaded walls look tan/drab** compared to the lit sides. Partly addressed by the additive cool sky fill in `fs_main`; still worth a proper ambient/ambient-occlusion term.
5. ~~**Palm frond undersides are dark.**~~ (fixed). The fronds carry a translucency flag in `nrm.w`; `fs_main` adds `albedo * SUNCOL * saturate(-dot(Ng,V)) * saturate(dot(Ng,L)) * 0.55`, so looking up at a sunlit frond glows green instead of going black.
6. **Water vertices "swim"** slightly as the camera moves because the grid is camera-centred with non-uniform spacing. Currently hidden by small amplitude; a stable clip-map would fix it.
7. **Camera** can still clip into the player at its 1.5 min distance when backed into a wall; props' collision is approximated by `topY`.
8. Player can end up inside an obstacle if spawned/teleported there (push-out is per-frame, not swept).
9. **Shadow map is re-rendered every frame** at 4096² (terrain + props + player, ~550k triangles). Only the player actually changes, so caching the static casters would be an easy win if frame time becomes an issue.
10. No tests, no git repo yet.

## Roadmap

Ordered roughly by value-to-effort. Each item should end with updated `shots/` renders and a note here.

### M1: Look and feel polish
- [x] **Real-time shadows** (directional shadow map, PCF or soft edges); replace the blob shadow with a contact-shadow fallback
  - Single 4096² depth map, orthographic light frustum ±160, hardware PCF (`sample_compare`, 3x3 grid), receiver-plane offset along the geometric normal (0.25) plus a slope-scaled bias. The light camera sits at `+sunDir * 300` (it used to be `-sunDir * 300`, which rendered the map from *under* the island and produced no usable shadows).
- [x] Soft bloom + subtle tone mapping / color grading pass for the "sunny" look
  - MSAA HDR (`rgba16Float`) scene target resolves into a half-res bright pass (threshold 1.0, knee 0.5), two ping-pong 9-tap Gaussian blurs, then a composite that adds bloom at 0.30 and applies a highlight-only soft-knee tone curve (identity below 0.86) with a mild saturation lift. ACES was tried first and washed the display-space palette out; the knee curve keeps the authored colours intact. Shaded surfaces get a small additive sky fill so shadows read cool without going muddy.
  - Water deliberately does **not** receive shadows: at grazing angles the shadow-map texel footprint blows up and the island silhouette appeared as hard bands offshore.
  - Composite exposure is trimmed to 0.92 before the tone curve (added with the terrain-detail work) to leave highlight headroom.
- [x] **Better terrain texturing** and plaza tile art
  - The vertex colour still carries the broad material blend (sand -> grass -> rock, by height then slope); `fs_main` modulates it with `fbm` patches plus two `vnoise` octaves for grain, a shallow dune ripple on sand, damp/darker sand near the water line, and low-contrast blotches on rock. Detail fades to its mean through `aaNoise` once an octave gets finer than a pixel, so far ground dissolves instead of shimmering.
  - **Footprint caveat:** `fwidth(wp.xz)` is very anisotropic on flat ground seen at a shallow angle. Summing both derivatives faded detail that was still resolvable, so the LOD uses `max(fwidth(p).x, fwidth(p).y)`.
  - Height-based rock strata were tried and reverted: they read as topographic contour lines.
  - Plaza: per-tile tone from `hash21(cell)` and anti-aliased grout (fixed 4%-of-tile `step` before, which shivered at distance).
  - Composite exposure trimmed to 0.92 before the knee. Lit grass and sand sat at the top of the curve, which was flattening ground detail and blowing out the wet sand.
  - Rock is now a light warm grey (was `0.64, 0.54, 0.42`) and only starts on steeper faces (`0.74 -> 0.52` vs `n.y`); the old colour made the hill shoulder look like a mud slide.
- [x] Underwater look when the camera dips below the surface (fog tint, caustics)
  - `uwAmount(camY)` crossfades 0 -> 1 over `+0.30 .. -0.10`, so the camera passing through the surface blends instead of popping. Three shaders branch on it: `applyFog` (dense teal absorption at 0.065/m, versus 0.0035/m in air), `fs_sky` (open water below the horizon), and `fs_water` (the surface seen from below).
  - Caustics: `fs_main` adds a ridged-noise web to anything with `wp.y < 0` and an upward normal, fading with depth. Only evaluated when submerged.
  - Under the surface the water is a bright rippling ceiling inside the Snell window (~49 degrees from vertical); steeper grazing angles fall back to total internal reflection and go dark.
  - **The camera could never reach the water before.** `updateCamera` clamped it to `y >= 0.5` unconditionally, so the item was unreachable. It now clamps against the seabed while swimming, and the pitch limit went from -0.1 to -0.55 so you can dive the camera by pitching down in open water. On land it still never goes below the waterline.
  - Everything underwater decays to the single colour `UWFOG`. An earlier version varied the fog target with the fragment's own height, which made the distant seabed and the distant surface converge to different colours and drew a hard dark bar along the far waterline.
- [ ] Water refraction/depth-fog improvements; wake and splash particles when the player moves in water
- [ ] Sky: moving cloud shadows, optional time-of-day parameter (sun direction/color)
- [x] **Shorelines + foliage shading** (known issues 2 and 5)
  - Two-sided lighting now blends between the front/back diffuse terms instead of hard-flipping the normal, which removed the dotted dark seam that appeared where the ground was tangent to the view (most obvious along shorelines). Water shallows fade in over a wider band (`exp(-depth*0.30)`, alpha `0.20 + depth*0.30`) and the foam band is wider, so the shore is a gradient rather than a hard cut. Palm fronds carry a translucency flag so their undersides glow rather than going black.
- [ ] Fix known issues 3-4 above

### M2: Character and movement
- [ ] Proper movement feel: variable jump height, coyote time, ground-pound/roll or dive, wall-slide (pick a small set)
- [ ] Better character model and animation (idle, run, jump, fall, swim strokes), still original design
- [ ] Footstep dust / sand / water splash particles
- [ ] Camera polish: auto-recenter behind movement, look-ahead, FOV kick while running
- [ ] Slope handling: slide on steep slopes instead of walking up cliffs

### M3: "Spray pack" mechanic (original water-jet tool)
- [ ] Hold-to-spray with a GPU particle system (spray arc, splash on impact, tint decals)
- [ ] Hover/boost variant with a limited tank that refills in water
- [ ] Interactable targets (e.g. wash away goo/graffiti decals on terrain/walls)

### M4: World scale and streaming
- [ ] Move from one 240-unit island to an archipelago: chunked terrain with LOD and frustum culling
- [ ] Heightmap from tiles/noise per chunk instead of one global mesh; stream by player position
- [ ] Instanced rendering for palms/bushes/flowers (currently one merged static mesh)
- [ ] Bigger water extent with a stable clip-map grid
- [ ] Boats/piers/bridges connecting islands; fast-travel or loading-free transitions

### M5: Gameplay layer
- [ ] Collectibles (coins/shines), HUD (SwiftUI overlay or Metal text), save state
- [ ] NPCs / simple AI wanderers, a few interactive buildings
- [ ] Audio: ambient waves/birds, footsteps, music hooks via `AVAudioEngine`
- [ ] Simple quest/goal loop so there is something to *do*

### M6: Production
- [ ] Precompile shaders into a `.metallib` (move MSL out of the Swift string into `.metal` files; needs an Xcode project or a build plugin)
- [ ] Package as a proper `.app` bundle (icon, Info.plist, signing), consider an Xcode project
- [ ] Settings (resolution scale, MSAA, vsync/fps cap, key remap), pause menu
- [ ] Unit tests for `World.height`, physics, math helpers; golden-image tests built on `--shot`
- [ ] Initialize git, add `.gitignore` (`.build/`), commit baseline

## Working agreement for the next agent

- Read `AGENTS.md` first. Keep Swift/MSL struct layouts in sync, keep `World.height` the single source of truth for terrain.
- Verify visual work with `--shot` renders and actually look at them; be explicit about what is unverified (especially interactive input).
- Keep scope tight per milestone item; keep the original-assets-only constraint.
- Prefer small, reviewable changes; update this file (check boxes, add/close known issues) as part of each change.
