# OpenWorld: Project Plan

## Vision

A native macOS (Apple Silicon, Metal) third-person open-world game you can walk around, with the bright, saturated, stylized tropical-island look of an early-2000s platformer: low-poly geometry, simple textures, vivid water, sunny sky. All art and characters are **original** (no third-party/Nintendo assets). Target hardware: M4 Pro, 60-120 fps at native resolution with MSAA.

Tech stack: Swift 6 toolchain (language mode 5), Metal (runtime-compiled MSL), MetalKit, GameController, SwiftPM. See `AGENTS.md` for architecture and workflow.

## Status: v1.0 released — M1 (look and feel) and M2 (character and movement) complete, M3 next

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
3. ~~**Plaza terrace**~~ (fixed). The floor now ends on a modelled stone kerb ring (`World.buildProps`, 72 segments of three quads) plus a narrow stone border band and a contact shadow in the tile shader, so the checker stops on a deliberate edge instead of being cut off by grass. The mud-coloured slope is gone with the rock recolouring from the terrain item.
4. ~~**Shaded walls look tan/drab**~~ (fixed). The ambient is now a hemispheric three-colour blend with a per-face term (vertical faces facing the sun get a little more warmth), so a building's four walls no longer receive identical light. Contact occlusion is baked into the mesh: `MeshBuilder.groundedBox` ramps the wall colour darker over the lowest ~2.4 m through `quad4` per-corner colours.
5. ~~**Palm frond undersides are dark.**~~ (fixed). The fronds carry a translucency flag in `nrm.w`; `fs_main` adds `albedo * SUNCOL * saturate(-dot(Ng,V)) * saturate(dot(Ng,L)) * 0.55`, so looking up at a sunlit frond glows green instead of going black.
6. **Water vertices "swim"** slightly as the camera moves because the grid is camera-centred with non-uniform spacing. Currently hidden by small amplitude; a stable clip-map would fix it.
7. **Camera** can still clip into the player at its 1.5 min distance when backed into a wall; props' collision is approximated by `topY`.
8. Player can end up inside an obstacle if spawned/teleported there (push-out is per-frame, not swept).
9. **Shadow map is re-rendered every frame** at 4096² (terrain + props + player, ~550k triangles). Only the player actually changes, so caching the static casters would be an easy win if frame time becomes an issue.
10. No tests. The repo is public at https://github.com/DennisFaucher/OpenWorld (v0.1 released).

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
- [x] Water refraction/depth-fog improvements; wake and splash particles when the player moves in water
  - **Refraction** is done in the depth lookup rather than the image: the seabed height is re-sampled at `wp.xz + N.xz * (0.35 + depth * 0.55)`, so the shoreline and the shallow shelf wobble with the waves. A real screen-space refraction would need a second scene pass, which the single-pass layout does not have.
  - `Particles.swift` is a CPU pool of ~600 sprites (`--walk` renders them headlessly). Foam is pinned to `y = 0.05` and spreads; droplets get gravity. The renderer rebuilds them as camera-facing quads each frame into one dynamic buffer, drawn after the water with depth test but no depth write.
  - The particle pass is skipped entirely while the camera is submerged: the water plane is opaque from below but writes no depth, so spray above the surface would otherwise punch through it.
  - **Play-test fixes.** The entry splash never fired in practice: walking off a beach into deep water is a continuous seabed, so the terrain snap zeroes `vel.y` every frame and the `fallSpeed < -3.5` test could only ever see a real jump-drop. It now uses `max(-fallSpeed, speed * 0.6)` and has a cooldown. The wake also read as a trail of bubbles — a soft round sprite does that no matter the tint — so foam is squashed into an ellipse, faded at grazing angles, and broken up with world-space noise in `fs_particle`.
  - **Buoyancy was launching the player out of the water.** The spring used the raw displacement, so landing even a metre deep accelerated at ~150 m/s^2, throwing the player clear; every bob back in re-triggered the splash, which is what painted the sea with white smears. The displacement is now clamped to +/-0.9 m with stronger damping.
  - Two water shader knock-ons turned up while chasing that: depth was measured from the displaced surface (`wp.y`) rather than mean sea level, so the shallow band and its foam tracked the wave crests, and the fine breakup noise had to replace a 2.2/m one that read as cloud-shaped smears. Clouds are also excluded from the water reflection, where the wave normals shredded their edges.
- [x] Sky: moving cloud shadows, optional time-of-day parameter (sun direction/color)
  - One cloud field (`cloudField`) at altitude 260. The sky intersects it along the view ray, so the clouds converge towards the horizon; `fs_main` projects the *same* field along the sun, so the shadow crossing the island belongs to the cloud overhead.
  - `--hour` swings the sun on an arc that passes exactly through the original hand-picked direction at 12:00. `Renderer.sun(hour:)` also returns the light colour (warming to `1.0, 0.52, 0.28` at the horizon), which now travels in the frame uniform (`f.sunCol`) instead of the old `SUNCOL` constant. The ambient dims and warms with `L.y`, and `horizonColor` warms the sky and the distance fog together.
  - A full sunset (17:30+) is dim and desaturated on the ground — physically right, since there is no bounce light, but it is the weakest part of the range.
- [x] **Shorelines + foliage shading** (known issues 2 and 5)
  - Two-sided lighting now blends between the front/back diffuse terms instead of hard-flipping the normal, which removed the dotted dark seam that appeared where the ground was tangent to the view (most obvious along shorelines). Water shallows fade in over a wider band (`exp(-depth*0.30)`, alpha `0.20 + depth*0.30`) and the foam band is wider, so the shore is a gradient rather than a hard cut. Palm fronds carry a translucency flag so their undersides glow rather than going black.
- [x] Fix known issues 3-4 above
  - Stone kerb around the plaza, ambient/face term for shaded walls, contact-AO gradient baked into building walls. See issues 3 and 4.

### M2: Character and movement
- [x] Proper movement feel: variable jump height, coyote time, jump buffering, heavier falling
  - Variable height cuts `vel.y` by 0.42 on release, so a tap is a 0.58 m hop and a hold is a 2.43 m jump off the same button. Coyote (0.12 s) and the buffer (0.12 s) cover presses made just after leaving / just before landing, and falling uses 42 m/s² against 30 rising so the arc does not float.
  - Measured with `--sim`: apex 2.43 m held vs 0.58 m tapped, 0.70 s of air, and a press 0.07 s before touchdown fires on the landing frame instead of being swallowed.
  - **Coyote time is barely exercised.** Slope handling below removed the worst of the glue, and walking off the rocky outcrop does now produce airborne frames, but every drop on this island ends in the sea within a frame or two — and swimming makes jumping legal anyway. The window is real code waiting for cliffs, which M4 brings.
- [x] Better character model and animation (idle, run, jump, fall, swim strokes), still original design
  - Rebuilt as a real rig in `Player.swift`: hips, chest, head and hat, plus two segments and a hand or foot per limb, drawn from overlapping sphere primitives. Same character (straw hat, red band, blue shirt, cream trousers, brown shoes), now about 20 parts instead of a torso, a head and four sticks.
  - Six states — idle, run, rise, fall, swim, slide — each a pure function of the walk phase and time. Weights are blended *between states* rather than between joint angles: a 10/s low-pass on a 2 Hz stride flattened the legs to a shuffle (hip swing came out at 29° instead of 46°). Transitions still ease because the weights ease.
  - Airborne weight cross-fades on `vel.y` rather than switching at the apex, so the jump does not pop between rise and fall. The stride rate is now `min(speed, 11) * 1.5` — the old 2.6 multiplier was about twice a believable cadence.
  - Rig gotchas worth keeping: `out` is a Z rotation in the torso frame, so the same sign that abducts a hanging arm adducts a raised one (the rise pose uses a negative value to spread the arms). Limb angles are positive forward, which is why every joint applies `rotationX(-angle)`.
  - Verified headlessly with `--jump` on the shot path and `--look RAD`, which re-orbits the finished frame so a run cycle can be seen from the side: stride extremes at frames 38 and 50 of a `--walk` (hip ±45.8°, knee 11–63°), tucked-leg V-armed rise, arms-out fall, horizontal swim with the head and back above the surface, braced slide.
- [x] Footstep dust / sand / water splash particles
  - A third particle kind (`Particle.kind`: 0 droplet, 1 foam, 2 dust) rather than inferring the look from gravity, which was standing in for "is this foam". Dust gets its own high-frequency noise breakup in `fs_particle` and a soft edge; foam keeps the low-frequency one.
  - Emission: one puff per foot contact (the stride advances by pi, so a change in the step index is the contact, alternating feet), a wider cloud on landing from a fall, a continuous skid while sliding, and a scuff when the player presses into a face too steep to climb. The last one closes the loop on the slope work: a silent stall read as "the game is stuck", and now it reads as digging in.
  - Tint comes from the ground it left — sand, dry grass or rock via the same masks as `World.buildTerrain` — lightened 35% toward white, because a dust cloud is always paler than the surface. Dry ground only: the shallows already spray.
  - Gotcha: on a steep face a puff spawned at the feet is *inside* the terrain and never draws, because it is depth-tested against the ground it just left. The skid cloud is lifted and given upward velocity for that reason.
  - Verified headlessly: sand puffs trailing a run along the beach, a scuff cloud at the foot of the scarp while holding forward, a skid trail on the 48° face, an impact ring on landing on the plaza, nothing at all while idle.
- [x] Camera polish: auto-recenter behind movement, look-ahead, FOV kick while running
  - Look-ahead offsets the boom pivot along the run by up to 1.0 m, faded out as the camera pulls in. Auto-recenter only runs after 1.2 s without camera input and only while pushing forward — recentring during a strafe would rotate the frame the strafe is measured in. The FOV kick is +3.6° at a sprint, eased in over about half a second.
  - Chasing the look-ahead turned up a real bug: the boom floor was 1.5 m, but the pivot is pushed forward, so a pulled-in camera sat inside the player's head (reproduce with `--walk-fast` from the spawn, frame 60). The floor is now 2.2 m and the look-ahead fades below 2.5 m.
- [x] Slope handling: slide on steep slopes instead of walking up cliffs
  - The vertical snap lifted the player onto whatever was under them, so any face was climbable at full speed. A step into ground past the walk limit now keeps only the component that runs along the contour, and standing on such ground removes traction entirely: `Game.slideAccel` 34 m/s² down the fall line against `slideDrag` 2/s, whatever the input says.
  - 45° (`Game.walkSlopeY`) is measured rather than guessed — `--slope-scan` histograms the terrain gradient. The island peaks at 65° around the rocky outcrop at (55, -38); 1% of the sampled area is past 45°, and the mountain flank tops out at 44°, so the one landmark stays climbable.
  - Verified headlessly: walking west into the outcrop from the shore climbs 38° → 45° and then stops advancing in x, sliding along the face instead; starting on a 54° patch with forward held slides down the fall line from y 3.27 to the waterline, `grounded` never dropping; the 44° mountain flank still walks at full pace.
  - Play-test spawns: `--pos 60 -30 --yaw 1.571` stands you at the foot of the scarp, where holding forward climbs to 44.5° and stalls; `--pos 59 -29 --yaw 1.571` starts you on a 52° face, which slides immediately.
  - Emergent result worth keeping: the mountain flank crosses 45° on some bearings, so the direct line to the summit is blocked and the player has to switchback up it. That reads as terrain rather than as an obstacle, which is the argument for keeping the limit at 45° instead of loosening it to keep every route open.

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
