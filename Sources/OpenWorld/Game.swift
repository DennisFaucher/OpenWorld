import Foundation
import GameController
import simd

enum Key {
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let d: UInt16 = 2
    static let f: UInt16 = 3
    static let e: UInt16 = 14
    static let r: UInt16 = 15
    static let w: UInt16 = 13
    static let space: UInt16 = 49
    static let esc: UInt16 = 53
    static let shift: UInt16 = 56
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

final class Input {
    var keys = Set<UInt16>()
    var mouseDX: Float = 0
    var mouseDY: Float = 0
    var jumpQueued = false
    /// Held spray trigger. Set by the left mouse button and by `F`.
    var spray = false

    func down(_ k: UInt16) -> Bool { keys.contains(k) }
}

final class Game {
    static let spawn = V3(-18, World.plazaHeight, 28)
    static let swimY: Float = -0.8
    static let playerRadius: Float = 0.45
    static let jumpVel: Float = 12.5
    /// Grace period after walking off a ledge during which the jump still fires.
    static let coyote: Float = 0.12
    /// A jump pressed this far ahead of landing is remembered.
    static let jumpBufferTime: Float = 0.12
    /// Ground steeper than this (normal.y, i.e. cos 45°) cannot be stood on.
    static let walkSlopeY: Float = 0.7071
    static let slideAccel: Float = 34
    static let slideDrag: Float = 2.0

    let obstacles: [Obstacle]

    var pos = Game.spawn
    var vel = V3.zero
    var facing: Float = 0
    var onGround = false
    var swimming = false
    /// On ground past the walk limit, so the character is sliding rather than
    /// running. Owned by `update` and read by the rig.
    var sliding = false
    var walkPhase: Float = 0
    var speedNorm: Float = 0
    var time: Float = 0
    /// Wet patches left by the jet, oldest first. Capped, so a long spray
    /// overwrites the driest patch rather than growing without bound.
    var decals: [Decal] = []
    /// Goo splats, in the order they were placed. Washed ones are removed.
    var goos: [Goo] = []
    /// The crystals, in a fixed order. Generated from the terrain, never edited.
    let shards: [Shard]
    /// Indices into `shards` already picked up. Set once by the save file and
    /// then only grown, so the count is the whole of the game's progress.
    private(set) var found: Set<Int> = []
    /// Crystals offered at the tower. `found` is the field, this is the shrine;
    /// the difference is what you are carrying, and it is what the lamps count.
    private(set) var banked: Int = 0
    /// Deposits still rolling in, so the lamps light one after another instead
    /// of all at once. `banked + pending` is what has left your hands.
    private var pending = 0
    private var depositClock: Float = 0
    /// Called whenever the progress the save file holds changes — a crystal
    /// taken or one offered — so the app layer can write it without `Game` ever
    /// touching the disk (the headless paths leave it nil).
    var onProgress: (() -> Void)?
    /// One boat per pier, moored at the seaward end. Index into `boats` while
    /// riding; nil on foot.
    var boats: [Boat] = []
    var riding: Int?
    var spraying = false
    /// Eases the aiming pose in and out, so the arm does not snap up.
    var sprayBlend: Float = 0
    /// Last aim direction and nozzle position, shared by the stream, the thrust
    /// and the pose so they cannot disagree.
    var aimDir = V3(0, 0, 1)
    var aimOrigin = V3.zero
    /// Where the jet would land right now. The reticle is drawn at the middle of
    /// the screen and only needs to know that there is a landing; the point
    /// itself is here because aiming and firing share one arc. Nil when the pack
    /// is dry or the stream reaches nothing.
    var aimImpact: V3?
    /// Water left in the pack, 1 = full. The jet empties it and water refills
    /// it; `tankDry` keeps it off until there is enough for another burst.
    var tank: Float = 1
    var tankDry = false
    /// Crystals in the pack that have not been offered yet.
    var carried: Int { max(0, found.count - banked - pending) }
    /// Every crystal delivered: the lamps are all lit and the crown burns.
    var shrineLit: Bool { !shards.isEmpty && banked >= shards.count }
    /// Blend weights per `Player.State` (same order: idle first), eased so a
    /// state change does not pop.
    var poseWeights: [Float] = [1, 0, 0, 0, 0, 0]
    /// Weighted pose of the states above, advanced every update so headless
    /// shots settle before they render.
    var pose = PlayerPose()
    /// The parts of the walk cycle the pose functions read, so villagers can be
    /// posed by the same code without owning a `Game`.
    var poseClock: PoseClock { PoseClock(time: time, walkPhase: walkPhase, speedNorm: speedNorm) }
    /// The islanders, updated in place every frame.
    var villagers: [Villager] = []
    /// Degrees added to the base field of view, so a sprint has a little kick.
    var fovBoost: Float = 0
    let particles = ParticleSystem()

    var camYaw: Float = Float.pi
    var camPitch: Float = 0.25
    var camDist: Float = 9
    var camPos = V3.zero
    var camTarget = V3.zero
    private var curDist: Float = 9
    private var splashCooldown: Float = 0
    private var camInitialised = false
    private var prevPadJump = false
    private var prevBoard = false
    private var wakeTimer: Float = 0
    private var airTime: Float = 0
    private var jumpBuffer: Float = 0
    private var jumpCutArmed = false
    private var camIdle: Float = 0
    /// Walk-phase step counter. A change means a foot landed.
    private var stepIndex = 0
    private var dustTimer: Float = 0
    /// Session totals for the activity readout. The step count rides the same
    /// walk phase that fires the dust, so it cannot drift from the animation,
    /// and the distance only counts ground covered on foot.
    private(set) var steps: Int = 0
    private(set) var distance: Float = 0
    /// Cosmetic, but a plausible one: a footfall is worth a little under a
    /// twentieth of a kilocalorie.
    var calories: Int { Int(Float(steps) * 0.045) }
    /// Raw move input this frame, so the camera can tell a run from a strafe.
    private var wishInput = V2.zero

    init(obstacles: [Obstacle], save: SaveState? = nil) {
        self.obstacles = obstacles
        boats = World.boatMoorings.map { Boat(pos: $0.pos, heading: $0.heading) }
        goos = Spray.gooSites.map {
            Goo(pos: V3($0.x, World.height($0.x, $0.y), $0.y),
                radius: 0.85 + 0.35 * abs(sin($0.x * 1.7 + $0.y * 0.9)))
        }
        shards = Shards.field(obstacles: obstacles)
        villagers = Villagers.spawn(obstacles: obstacles)
        // A file from a build that placed the crystals somewhere else describes a
        // world that no longer exists, so it is dropped rather than remapped.
        if let save, save.layout == Save.layoutHash(shards) {
            found = Set(save.found.filter { shards.indices.contains($0) })
            // A file that claims more delivered than found is nonsense; clamp it
            // rather than letting the lamps disagree with the counter.
            banked = min(max(0, save.banked ?? 0), found.count)
            steps = max(0, save.steps)
            distance = max(0, save.metres)
        }
    }

    /// Headless only: hand the player the first `n` crystals as already found and
    /// nothing delivered, so the shrine can be checked without walking the
    /// archipelago. Headless runs never save, so this cannot leak into a file.
    func primeFound(_ n: Int) {
        found = Set(shards.indices.prefix(max(0, n)))
        banked = 0
        pending = 0
    }

    /// As above, but with the first `n` already offered, so the lamps and the
    /// crown beam can be rendered without crossing the plaza.
    func primeDelivered(_ n: Int) {
        primeFound(n)
        banked = min(max(0, n), found.count)
    }

    func respawn() {
        pos = Game.spawn
        vel = .zero
        riding = nil
        camInitialised = false
    }

    /// Puts the player aboard a boat. Used by the boarding toggle and by the
    /// headless `--ride` flag, so a boat can be tested without a keyboard.
    func boardBoat(_ i: Int) {
        guard boats.indices.contains(i) else { return }
        riding = i
        let b = boats[i]
        pos = V3(b.pos.x, Boat.deckY, b.pos.y)
        vel = .zero
    }

    /// 0 when `E` would do nothing, 1 next to a boat, 2 aboard a boat that is
    /// slow enough to step off. Drives the on-screen prompt.
    var boardingHint: Int {
        if let i = riding { return abs(boats[i].speed) < 1.5 ? 2 : 0 }
        return nearestBoatIndex() == nil ? 0 : 1
    }

    /// Nearest boat within stepping distance, which is a little more than the
    /// beam so a boat can be caught from the end of a pier or from the water.
    private func nearestBoatIndex() -> Int? {
        var best: Int?
        var bestDist: Float = 3.4
        for (i, b) in boats.enumerated() {
            let d = length(V2(b.pos.x - pos.x, b.pos.y - pos.z))
            if d < bestDist {
                bestDist = d
                best = i
            }
        }
        return best
    }

    /// Steps off onto the water beside the hull. Deep water is fine — the swim
    /// state takes over on the next update.
    private func leaveBoat(_ i: Int) {
        riding = nil
        let b = boats[i]
        let side = V2(-b.forward.y, b.forward.x) * 1.6
        let p = b.pos + side
        pos = V3(p.x, max(World.height(p.x, p.y), Game.swimY), p.y)
        vel = .zero
        onGround = false
    }

    func update(dt: Float, input: Input) {
        time += dt
        let pad = GCController.controllers().first?.extendedGamepad

        // Camera control.
        var camMoved = input.mouseDX != 0 || input.mouseDY != 0
        camYaw -= input.mouseDX * 0.0035
        camPitch += input.mouseDY * 0.0035
        input.mouseDX = 0
        input.mouseDY = 0
        if input.down(Key.left) { camYaw += 2 * dt; camMoved = true }
        if input.down(Key.right) { camYaw -= 2 * dt; camMoved = true }
        if input.down(Key.up) { camPitch -= 1.5 * dt; camMoved = true }
        if input.down(Key.down) { camPitch += 1.5 * dt; camMoved = true }
        if let pad {
            if abs(pad.rightThumbstick.xAxis.value) > 0.05 || abs(pad.rightThumbstick.yAxis.value) > 0.05 {
                camMoved = true
            }
            camYaw -= pad.rightThumbstick.xAxis.value * 2.5 * dt
            camPitch -= pad.rightThumbstick.yAxis.value * 1.8 * dt
        }
        camIdle = camMoved ? 0 : camIdle + dt
        camPitch = clampf(camPitch, -0.55, 1.35)
        if input.down(Key.r) { respawn() }

        // Boarding. One key for both directions: it takes the nearest boat in
        // reach, or steps off the one being ridden, so there is no way to be
        // stuck aboard. Edge-triggered, otherwise holding it would hop in and
        // out every frame.
        let padBoard = pad?.buttonB.isPressed ?? false
        let boardHeld = input.down(Key.e) || padBoard
        if boardHeld && !prevBoard {
            if let i = riding {
                leaveBoat(i)
            } else if let i = nearestBoatIndex() {
                riding = i
                jumpBuffer = 0
                vel = .zero
            }
        }
        prevBoard = boardHeld

        // Aim, tank and impact. The marker, the stream, the thrust and the wash
        // all read the same arc, so no two of them can point somewhere else.
        spraying = (input.spray || input.down(Key.f)) && !swimming && !tankDry
        let aim = Spray.aim(self)
        aimDir = aim.dir
        aimOrigin = aim.origin
        if spraying {
            // Washing is cheap and lifting yourself is not: at one rate, a
            // five-second wash and a hover burst were the same thing.
            let hover = clampf((-aimDir.y - 0.45) / 0.5, 0, 1)
            tank -= dt * (0.07 + 0.26 * hover)
            // The drain has to be able to reach zero: clamping at 0 each frame
            // leaves a sliver that keeps the jet sputtering forever.
            if tank <= 0.001 { tank = 0; tankDry = true; spraying = false }
        } else {
            // Only the player's own body in the water refills the pack: sitting
            // in a boat a hand's width above the surface is not a dip.
            // A lit shrine feeds the pack: the same water, but it comes back
            // nearly three times as fast, which is the reward worth having.
            let fill: Float = shrineLit ? 2.2 : 0.85
            if (swimming || pos.y < 0.45) && riding == nil { tank = min(1, tank + dt * fill) }
            if tankDry && tank > 0.25 { tankDry = false }
        }
        let jetHit = tankDry ? nil : Spray.impact(origin: aimOrigin, dir: aimDir, obstacles: obstacles)
        aimImpact = jetHit?.pos

        // Movement input, relative to the camera.
        var mx: Float = (input.down(Key.d) ? 1 : 0) - (input.down(Key.a) ? 1 : 0)
        var my: Float = (input.down(Key.w) ? 1 : 0) - (input.down(Key.s) ? 1 : 0)
        if let pad {
            mx += pad.leftThumbstick.xAxis.value
            my += pad.leftThumbstick.yAxis.value
        }
        var wish = V2(mx, my)
        let wl = length(wish)
        if wl > 1 { wish /= wl }
        wishInput = wish
        let fwd = V3(-sin(camYaw), 0, -cos(camYaw))
        let right = V3(cos(camYaw), 0, -sin(camYaw))
        let dir = right * wish.x + fwd * wish.y

        var hv = V2(vel.x, vel.z)
        let wasSwimming = swimming
        let wasGrounded = onGround
        let fallSpeed = vel.y
        /// Ground under the player, pier decks included.
        var g = World.height(pos.x, pos.z)
        var blockedBySlope = false

        if let i = riding {
            // The stick the legs use becomes throttle and rudder: forward is
            // throttle, sideways is steer. Nothing here applies gravity, so the
            // hull rides the water line and the player rides the hull.
            let b = boats[i]
            b.update(dt: dt, throttle: wish.y, steer: wish.x, time: time)
            hv = V2(b.forward.x * b.speed, b.forward.y * b.speed)
            vel = V3(hv.x, 0, hv.y)
            pos = V3(b.pos.x, Boat.deckY + b.bob, b.pos.y)
            facing = b.heading
            onGround = true
            swimming = false
            sliding = false
            airTime = 0
            jumpBuffer = 0
            g = Boat.deckY
            if abs(b.speed) > 2 {
                wakeTimer -= dt
                if wakeTimer <= 0 {
                    wakeTimer = 0.05
                    let stern = V3(b.pos.x, 0, b.pos.y) - V3(b.forward.x, 0, b.forward.y) * 1.9
                    particles.wake(at: stern, dir: V3(b.forward.x, 0, b.forward.y), speed: b.speed)
                }
            }
        } else {
            var maxSpeed: Float = 9
            if input.down(Key.shift) || (pad?.rightTrigger.value ?? 0) > 0.3 { maxSpeed = 14 }
            let groundHere = World.height(pos.x, pos.z)
            if swimming {
                maxSpeed *= 0.55
            } else if groundHere < -0.2 && onGround {
                maxSpeed *= 0.85
            }
            let accel: Float = (onGround || swimming) ? 14 : 4
            var hv = V2(vel.x, vel.z)
            // Loose footing. On ground steeper than the walk limit there is no
            // traction at all, so the slope wins and the player slides down the fall
            // line whatever the stick says.
            let nHere = World.normal(pos.x, pos.z)
            sliding = onGround && !swimming && nHere.y < Game.walkSlopeY
            if sliding {
                let dl = max(sqrt(nHere.x * nHere.x + nHere.z * nHere.z), 1e-5)
                hv += V2(nHere.x, nHere.z) / dl * (Game.slideAccel * dt)
                hv *= max(0, 1 - Game.slideDrag * dt)
            } else {
                hv += (V2(dir.x, dir.z) * maxSpeed - hv) * min(1, accel * dt)
            }

            // Jumping. Coyote time keeps a jump alive for a moment after walking off
            // a ledge and the buffer remembers a press made just before landing, so
            // a jump that "definitely happened" is not swallowed by the frame it
            // landed on.
            let padJump = pad?.buttonA.isPressed ?? false
            let jumpPressed = input.jumpQueued || (padJump && !prevPadJump)
            prevPadJump = padJump
            input.jumpQueued = false
            if jumpPressed { jumpBuffer = Game.jumpBufferTime }
            jumpBuffer -= dt

            let canJump = onGround || swimming || airTime < Game.coyote
            if jumpBuffer > 0 && canJump {
                vel.y = swimming ? 9 : Game.jumpVel
                onGround = false
                jumpBuffer = 0
                airTime = Game.coyote          // a jump consumes the coyote window
                jumpCutArmed = !swimming       // rising out of water is not cut short
            }
            // Variable height: releasing during the rise trims the rest of it, so a
            // tap is a hop and a hold is a full jump off the same button.
            let holding = input.down(Key.space) || padJump
            if jumpCutArmed && !holding && vel.y > 0 {
                vel.y *= 0.42
                jumpCutArmed = false
            }

            // Horizontal move, world bounds, then push out of obstacles.
            var np = pos
            np.x += hv.x * dt
            np.z += hv.y * dt
            let fromOrigin = V2(np.x, np.z)
            let dist = length(fromOrigin)
            if dist > World.boundsRadius {
                let c = fromOrigin / dist * World.boundsRadius
                np.x = c.x
                np.z = c.y
            }
            resolveObstacles(&np)

            // The vertical snap below lifts the player onto whatever is under them,
            // so without this any face is climbable, however steep. Strip the uphill
            // part of a step into ground past the walk limit and keep the component
            // that runs along the contour.
            let nDest = World.normal(np.x, np.z)
            if nDest.y < Game.walkSlopeY && World.height(np.x, np.z) > pos.y - 0.05 {
                let ux = -nDest.x, uz = -nDest.z
                let ul = sqrt(ux * ux + uz * uz)
                if ul > 1e-5 {
                    let up = ((np.x - pos.x) * ux + (np.z - pos.z) * uz) / ul
                    if up > 0 {
                        np.x -= ux / ul * up
                        np.z -= uz / ul * up
                        blockedBySlope = true
                    }
                }
            }

            // Vertical: gravity, buoyancy in deep water, terrain snap.
            g = World.height(np.x, np.z)
            // A pier deck is a prop, not terrain, so the snap has to be told about
            // it — but only on the way down: swimming under the deck must not
            // teleport the player up through it.
            if pos.y > World.pierDeckY - 0.25 { g = max(g, World.pierHeight(np.x, np.z)) }
            let deep = g < -1.1
            if deep && pos.y < Game.swimY + 0.35 {
                // Spring towards the swim line, but clamp the displacement: landing
                // deep used to fling the player out of the water, and every bob back
                // in re-triggered the splash.
                let lift = clampf(Game.swimY - pos.y, -0.9, 0.9)
                vel.y += (lift * 60 - vel.y * 9) * dt + sin(time * 2) * 0.4 * dt
            } else {
                // Falling is heavier than rising. That asymmetry is most of what
                // separates a jump that feels sharp from one that feels floaty, and
                // the clamp stops a long drop tunnelling through the terrain.
                vel.y -= (vel.y > 0 ? 30 : 42) * dt
                vel.y = max(vel.y, -48)
            }
            // Jet thrust. With the nozzle aimed at your feet the stream pushes you
            // up; easing toward a target climb rate, rather than adding an
            // acceleration, keeps it a hover instead of a rocket. Ordinary spraying
            // (aim forward) produces no thrust at all, so the jet stays usable.
            let downAim = -aimDir.y
            if spraying && downAim > 0.45 {
                let t = clampf((downAim - 0.45) / 0.5, 0, 1)
                // Above 42, the falling gravity, or the pack cannot break contact
                // with the ground at all; the speed cap keeps it a climb rather
                // than a launch, and a partial aim only a slow one. The tank ends it.
                vel.y += (44 + 18 * t) * dt
                vel.y = min(vel.y, 4.0 * t)
                onGround = false
            }
            np.y += vel.y * dt
            if np.y <= g {
                np.y = g
                vel.y = 0
                onGround = true
            } else if onGround && vel.y <= 0 && np.y - g < (sliding ? 0.9 : 0.35) {
                np.y = g
                vel.y = 0
            } else {
                onGround = false
            }
            airTime = onGround ? 0 : airTime + dt
            swimming = deep && np.y < Game.swimY + 0.35

            vel.x = hv.x
            vel.z = hv.y
            // Distance only counts ground covered on foot: swimming and a boat ride
            // are travel, but they are not what the readout is quoting.
            if !swimming && onGround {
                distance += length(V2(np.x - pos.x, np.z - pos.z))
            }
            pos = np
        }

        Villagers.update(&villagers, dt: dt, time: time, player: pos, obstacles: obstacles)

        // Collecting. Walking into a crystal takes it, with no key to press: the
        // point of scattering them is to make you want to walk over there, and a
        // prompt would turn that into a chore. One per frame is enough — two in
        // reach at once are nine metres apart at the closest.
        if let i = shards.indices.first(where: { !found.contains($0) && inReach(shards[$0]) }) {
            found.insert(i)
            particles.shimmer(at: shards[i].gem(time: time))
            onProgress?()
        }

        // The offering. No key: walking up to the tower with crystals in hand is
        // the whole gesture, and a prompt would turn the one deliberate act in
        // the game into a chore. They go in one at a time so the lamps light in a
        // run, and the count lands on the last one a couple of seconds later.
        if riding == nil, carried > 0, abs(pos.y - World.towerBaseY) < 4,
           length(V2(pos.x, pos.z) - World.towerCenter) < World.shrineRadius {
            pending += carried
        }
        if pending > 0 {
            var bankedNow = false
            depositClock -= dt
            while pending > 0 && depositClock <= 0 {
                pending -= 1
                banked += 1
                bankedNow = true
                depositClock += 0.085
                // Every fourth crystal is a lamp; the light itself is drawn from
                // `banked`, so this is only the sparkle at the socket it just lit.
                if banked % 4 == 0 {
                    let lamp = World.towerLamps[min(World.towerLamps.count - 1, banked / 4 - 1)]
                    particles.shimmer(at: lamp, tint: V3(1.5, 1.2, 0.55))
                }
                if shrineLit {
                    particles.shimmer(at: V3(World.towerCenter.x,
                                             World.towerSpireY + 0.6, World.towerCenter.y),
                                      tint: V3(1.6, 1.3, 0.6))
                }
            }
            // One write per delivery, not one per crystal: the queue is a
            // couple of seconds of roll-up and forty JSON encodes in a row is
            // not free. Anything still pending is still carried, so a quit in
            // the middle of it loses nothing but the walk back.
            if bankedNow && pending == 0 { onProgress?() }
        }


        let speed = length(hv)
        speedNorm = riding == nil ? speed / 9 : 0
        if speed > 0.5 {
            let target = atan2(hv.x, hv.y)
            let d = atan2(sin(target - facing), cos(target - facing))
            facing += d * min(1, 14 * dt)
        }
        if riding == nil { walkPhase += min(speed, 11) * dt * 1.5 }

        let want = Player.weights(self)
        for i in want.indices { poseWeights[i] += (want[i] - poseWeights[i]) * min(1, 12 * dt) }
        let total = poseWeights.reduce(0, +)
        pose = total > 1e-4 ? Player.pose(weights: poseWeights.map { $0 / total }, self)
            : Player.pose(.idle, poseClock)
        // Aiming overrides the right arm and turns the body, so the nozzle and
        // the stream agree even when the feet are running somewhere else. Only
        // the arm is overridden: the legs keep their own motion.
        sprayBlend += ((spraying ? 1 : 0) - sprayBlend) * min(1, 10 * dt)
        if sprayBlend > 0.01 {
            let ay = atan2(aimDir.x, aimDir.z)
            let d = atan2(sin(ay - facing), cos(ay - facing))
            facing += d * min(1, 12 * dt) * sprayBlend
            let local = asin(max(-1, min(1, aimDir.y)))
            pose.shoulderR += (Float.pi / 2 + local - pose.shoulderR) * sprayBlend
            pose.elbowR += (0.10 - pose.elbowR) * sprayBlend
            pose.outR += (0.10 - pose.outR) * sprayBlend
        }

        // Water spray. Wading off the beach is a walk, not a drop: the terrain
        // snap zeroes `vel.y` every frame, so the horizontal speed is what
        // carries the impact there.
        if swimming && !wasSwimming {
            let power = max(-fallSpeed, speed * 0.6)
            if power > 1.8 && splashCooldown <= 0 {
                splashCooldown = 0.7
                particles.splash(at: V3(pos.x, 0, pos.z), strength: min(2.4, 0.55 + power / 5))
            }
        }
        splashCooldown -= dt

        // Ground dust. The stride advances by pi per step, so a change in the
        // step index is a foot contact; the shallows already spray, so only dry
        // ground kicks anything up.
        dustTimer -= dt
        let dry = onGround && !swimming && g > 0.02
        let faceDir = V3(sin(facing), 0, cos(facing))
        let faceSide = V3(cos(facing), 0, -sin(facing))
        let step = Int(walkPhase / Float.pi)
        if step != stepIndex {
            // The walk phase also advances while swimming, but those are kicks,
            // not steps.
            if !swimming { steps += abs(step - stepIndex) }
            stepIndex = step
            if dry && !sliding && speed > 1.4 {
                let foot = pos + faceSide * (step % 2 == 0 ? 0.14 : -0.14)
                particles.footstep(at: foot, dir: -faceDir * 0.5, tint: dustTint(foot),
                                   strength: 0.55 + 0.45 * min(speed / 9, 1.4))
            }
        }
        if dry && !wasGrounded && fallSpeed < -7 {
            particles.footstep(at: pos, dir: .zero, tint: dustTint(pos),
                               strength: clampf(-fallSpeed / 12, 0.7, 1.8))
        }
        if dry && sliding && speed > 1.2 && dustTimer <= 0 {
            dustTimer = 0.06
            particles.skid(at: pos + V3(0, 0.08, 0), dir: V3(vel.x, 0, vel.z) * 0.25,
                           tint: dustTint(pos), strength: clampf(speed / 9, 0.6, 1.6))
        }
        // Scuffing at a face too steep to climb: the stall needs a visible cue,
        // otherwise "this is too steep" reads as "the game is stuck".
        if dry && blockedBySlope && length(wishInput) > 0.4 && dustTimer <= 0 {
            dustTimer = 0.10
            particles.skid(at: pos, dir: -faceDir * 0.5, tint: dustTint(pos), strength: 0.70)
        }
        // Water jet. A single arc per frame gives the impact point, so the
        // splash and the wet patch land where the stream reads as landing.
        if spraying {
            particles.jet(from: aimOrigin, dir: aimDir,
                          life: jetHit.map { $0.time * 1.06 } ?? 1,
                          dt: dt, rate: 0.35 + 0.65 * tank)
            if let hit = jetHit {
                // Washing goo tints the splash, so the spray reads as doing
                // something even before the splat is gone.
                let washing = washGoo(at: hit.pos, dt: dt)
                soak(hit.pos)
                particles.impact(at: hit.pos, normal: World.normal(hit.pos.x, hit.pos.z),
                                 dt: dt, tint: washing ? V3(0.72, 0.78, 0.42) : V3(0.90, 0.97, 1.0))
            }
        }
        for i in decals.indices { decals[i].age += dt }
        decals.removeAll { $0.age > $0.life }

        let wading = !swimming && onGround && g < -0.1
        particles.update(dt: dt, swimming: swimming, speed: speed,
                         feet: V3(pos.x, max(pos.y, 0), pos.z), wading: wading)

        updateCamera(dt: dt)
    }

    /// Whether the player is close enough to take a crystal. The gem floats a
    /// metre off the ground, so this measures to the body rather than the feet.
    private func inReach(_ s: Shard) -> Bool {
        let flat = length(V2(s.pos.x - pos.x, s.pos.z - pos.z))
        return flat < Shards.pickRadius && abs(s.gem(time: time).y - (pos.y + 0.6)) < Shards.pickHeight
    }

    /// Wears down any goo under the impact point. Returns whether it hit any.
    private func washGoo(at p: V3, dt: Float) -> Bool {
        var washing = false
        for i in goos.indices {
            let d = length(V2(goos[i].pos.x - p.x, goos[i].pos.z - p.z))
            // A margin past the splat itself: by the time the jet lands, the
            // water has already spread, so the rim is as wet as the middle.
            if d < goos[i].radius + 0.35 {
                goos[i].health -= dt * 0.9
                washing = true
            }
        }
        goos.removeAll { $0.health <= 0 }
        return washing
    }

    /// Wets the ground at `p`. Holding the jet on one spot grows the patch
    /// instead of stacking a new one every frame.
    private func soak(_ p: V3) {
        if !decals.isEmpty {
            let i = decals.count - 1
            if length(decals[i].pos - p) < 0.6 && decals[i].age < 1.0 {
                decals[i].radius = min(0.95, decals[i].radius + 0.012)
                // Keep it just past the fade-in, so a held jet does not reset
                // the patch to transparent every frame.
                decals[i].age = min(decals[i].age, 0.05)
                return
            }
        }
        if decals.count >= 40 { decals.removeFirst() }
        decals.append(Decal(pos: p, radius: Float.random(in: 0.32 ... 0.46)))
    }

    /// Dust takes the colour of the ground it comes off — pale sand, dry grass,
    /// grey rock — using the same masks as `World.buildTerrain`, then lightened,
    /// because a dust cloud is always paler than the surface it left.
    private func dustTint(_ p: V3) -> V3 {
        let h = World.height(p.x, p.z)
        let n = World.normal(p.x, p.z)
        let sand = V3(0.93, 0.86, 0.64)
        let grass = V3(0.58, 0.63, 0.32)
        let rock = V3(0.66, 0.64, 0.60)
        let ground = lerp(sand, grass, sstep(1.10, 1.95, h))
        let dusty = lerp(ground, rock, sstep(0.74, 0.52, n.y))
        return lerp(dusty, V3(1.0, 0.97, 0.90), 0.35)
    }

    private func resolveObstacles(_ p: inout V3) {
        pushOutOfObstacles(&p, radius: Game.playerRadius, obstacles)
    }

    private func cameraBlocked(_ p: V3) -> Bool {
        if p.y < World.height(p.x, p.z) + 0.3 { return true }
        for o in obstacles where p.y < o.topY {
            if o.round {
                if length(V2(p.x, p.z) - o.center) < o.half.x + 0.3 { return true }
            } else {
                let lo = o.center - o.half - V2(repeating: 0.3), hi = o.center + o.half + V2(repeating: 0.3)
                if p.x > lo.x && p.x < hi.x && p.z > lo.y && p.z < hi.y { return true }
            }
        }
        return false
    }

    private func updateCamera(dt: Float) {
        let flat = V2(vel.x, vel.z)
        let hs = length(flat)

        // Swing back behind the runner once the player has left the camera alone
        // for a moment. Only while pushing forward: recentring during a strafe
        // would rotate the frame the strafe is measured in and fight the player.
        if camIdle > 1.2 && !swimming && onGround && hs > 4 && wishInput.y > 0.5 {
            let want = facing + Float.pi
            let d = atan2(sin(want - camYaw), cos(want - camYaw))
            camYaw += d * min(1, 0.9 * dt)
        }
        // A little look-ahead along the run, so the frame shows where the player
        // is going rather than centring them dead. It fades out as the camera is
        // pulled in, or a collapsed boom would leave the camera inside the head.
        let leanFade = clampf((curDist - 2.5) / 4, 0, 1)
        let lean = hs > 0.8 ? V3(flat.x, 0, flat.y) / hs * (min(hs, 14) * 0.07 * leanFade) : .zero
        let desired = pos + V3(0, 2.15, 0) + lean
        if !camInitialised {
            camTarget = desired
            curDist = camDist
            camInitialised = true
        } else {
            camTarget += (desired - camTarget) * min(1, 12 * dt)
        }
        // A sprint widens the lens slightly; it reads as speed without moving
        // anything in the world.
        let wantFov = (onGround && hs > 10) ? min(6, (hs - 10) * 0.9) : 0
        fovBoost += (wantFov - fovBoost) * min(1, 6 * dt)

        let dirV = V3(sin(camYaw) * cos(camPitch), sin(camPitch), cos(camYaw) * cos(camPitch))

        // March out from the player and stop short of anything solid.
        var allowed = camDist
        let steps = 16
        for i in 1...steps {
            let t = Float(i) / Float(steps) * camDist
            if cameraBlocked(camTarget + dirV * t) {
                allowed = max(t - camDist / Float(steps) - 0.3, 2.2)
                break
            }
        }
        curDist = allowed < curDist ? allowed : curDist + (allowed - curDist) * min(1, 4 * dt)

        camPos = camTarget + dirV * curDist
        let ground = World.height(camPos.x, camPos.z) + 0.6
        // Swimming, the camera may follow the player under the surface so the
        // underwater look is reachable; on land it always stays above the waterline.
        camPos.y = max(camPos.y, swimming ? max(ground, World.seabed + 0.4) : max(ground, 0.5))
    }
}
