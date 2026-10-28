import Foundation
import simd

/// An islander. The same rig as the player, walking between waypoints around a
/// home point, and stopping to look at — and wave at — anyone who comes close.
struct Villager {
    var pos: V3
    /// Where they belong. Waypoints are always drawn within `roam` of this, so
    /// nobody walks to the far end of the island and never comes back.
    var home: V2
    var roam: Float
    var look: Look
    var target = V2.zero
    var facing: Float = 0
    var walkPhase: Float = 0
    var speed: Float = 0
    /// Seconds left standing still at the current waypoint.
    var wait: Float = 0
    /// 0...1 of a raised arm.
    var wave: Float = 0
    /// Seconds of attention spent waving, so the greeting is a greeting and not
    /// a permanent salute.
    var greeted: Float = 0
    /// 0...1 of how much the player's presence has registered.
    var attention: Float = 0
    /// Offset into the idle breath and the wave, so a crowd is not in step.
    var phase: Float = 0
    var rng: RNG
}

/// The islanders' behaviour. They have no combat, no dialogue and no schedules:
/// they walk about, they notice you, and that is the whole of it — which is
/// enough to make an island feel inhabited.
enum Villagers {
    /// A stroll. A villager jogging past reads as a pursuit.
    static let walkSpeed: Float = 1.75
    /// The stride functions are written for the player, whose speedNorm is
    /// metres per second over 9. Dividing a stroll by 9 leaves a shuffle, so
    /// villagers are scaled against a slower nominal speed.
    static let strideScale: Float = 3.4
    /// They stop and turn for a player this close.
    static let noticeRadius: Float = 4.5

    /// Where each islander lives, and how far they stray. Hand picked, unlike
    /// the crystals: these are characters with places to be.
    static let homes: [(centre: V2, radius: Float)] = [
        (V2(-18, 22), 9),    // the plaza
        (V2(22, 34), 10),    // the east beach
        (V2(-42, 36), 9),    // the west beach
        (V2(4, -18), 11),    // the south slope
        (V2(34, -6), 9),     // the east meadow
        (V2(180, 214), 12),  // the big cay, so the boat has somewhere to go
    ]

    static let looks: [Look] = [
        Look(shirt: V3(0.93, 0.38, 0.32), trousers: V3(0.20, 0.24, 0.34),
             skin: V3(0.82, 0.61, 0.45), shoe: V3(0.34, 0.20, 0.12),
             straw: V3(0.95, 0.82, 0.44), band: V3(0.22, 0.56, 0.46),
             scale: 0.96, pack: false),
        Look(shirt: V3(0.96, 0.79, 0.28), trousers: V3(0.30, 0.34, 0.24),
             skin: V3(0.99, 0.82, 0.66), shoe: V3(0.42, 0.26, 0.14),
             straw: V3(0.98, 0.90, 0.58), band: V3(0.72, 0.26, 0.34),
             scale: 1.04, pack: false),
        Look(shirt: V3(0.52, 0.36, 0.80), trousers: V3(0.86, 0.83, 0.74),
             skin: V3(0.62, 0.44, 0.32), shoe: V3(0.28, 0.18, 0.12),
             straw: V3(0.92, 0.78, 0.40), band: V3(0.30, 0.62, 0.66),
             scale: 1.0, pack: false),
        Look(shirt: V3(0.30, 0.68, 0.42), trousers: V3(0.22, 0.26, 0.30),
             skin: V3(0.90, 0.70, 0.54), shoe: V3(0.38, 0.24, 0.13),
             straw: V3(0.96, 0.86, 0.50), band: V3(0.94, 0.52, 0.24),
             scale: 0.92, pack: false),
        Look(shirt: V3(0.95, 0.56, 0.22), trousers: V3(0.32, 0.36, 0.42),
             skin: V3(0.74, 0.54, 0.40), shoe: V3(0.30, 0.19, 0.12),
             straw: V3(0.94, 0.84, 0.52), band: V3(0.34, 0.42, 0.70),
             scale: 1.02, pack: false),
        Look(shirt: V3(0.88, 0.42, 0.62), trousers: V3(0.24, 0.30, 0.36),
             skin: V3(0.97, 0.78, 0.62), shoe: V3(0.36, 0.22, 0.14),
             straw: V3(0.97, 0.88, 0.54), band: V3(0.24, 0.50, 0.44),
             scale: 0.98, pack: false),
    ]

    static func spawn(obstacles: [Obstacle]) -> [Villager] {
        var out: [Villager] = []
        for (i, h) in homes.enumerated() {
            var rng = RNG(seed: UInt64(i) * 7717 + 13)
            var v = Villager(pos: V3(h.centre.x, World.height(h.centre.x, h.centre.y), h.centre.y),
                             home: h.centre, roam: h.radius, look: looks[i % looks.count],
                             rng: rng)
            // Somewhere they can actually stand; the home point itself is only a
            // hint, and a couple of them sit on a slope.
            for _ in 0..<80 {
                let a = rng.range(0, 2 * Float.pi)
                let r = h.radius * 0.6 * sqrt(rng.next())
                let p = V2(h.centre.x + cos(a) * r, h.centre.y + sin(a) * r)
                if standable(p, obstacles: obstacles) {
                    v.pos = V3(p.x, World.height(p.x, p.y), p.y)
                    break
                }
            }
            rng = v.rng
            v.target = V2(v.pos.x, v.pos.z)
            v.facing = rng.range(0, 2 * Float.pi)
            v.phase = rng.range(0, 2 * Float.pi)
            v.wait = rng.range(0, 1.6)
            v.rng = rng
            out.append(v)
        }
        return out
    }

    static func update(_ vs: inout [Villager], dt: Float, time: Float, player: V3,
                       obstacles: [Obstacle]) {
        for i in vs.indices {
            var v = vs[i]
            let toPlayer = player - v.pos
            let flat = length(V2(toPlayer.x, toPlayer.z))
            let near = flat < noticeRadius && abs(toPlayer.y) < 3.0
            // Noticed slowly and forgotten faster, so a walk past does not leave
            // the whole island staring after you.
            let rate: Float = near ? 2.6 : 1.2
            v.attention += ((near ? 1 : 0) - v.attention) * min(1, rate * dt)

            // Someone being greeted stops; so does someone at a waypoint.
            let pause = v.attention > 0.55 || v.wait > 0
            let want: Float = pause ? 0 : walkSpeed
            v.speed += (want - v.speed) * min(1, 5 * dt)

            if v.wait > 0 { v.wait -= dt }

            let toTarget = v.target - V2(v.pos.x, v.pos.z)
            let arrive = length(toTarget)
            if !pause && arrive < 0.7 {
                v.target = waypoint(around: v.home, radius: v.roam, from: v.pos,
                                   obstacles: obstacles, rng: &v.rng)
                v.wait = v.rng.range(0.5, 2.8)
            }

            // Face where they are going, or the player once they have noticed.
            // Turning is rate limited: a snap reads as a bug even on a model
            // with no neck.
            if v.attention > 0.5 && flat > 1e-3 {
                v.facing = turn(v.facing, toward: atan2(toPlayer.x, toPlayer.z), max: 3.0 * dt)
            } else if arrive > 1e-3 {
                v.facing = turn(v.facing, toward: atan2(toTarget.x, toTarget.y), max: 2.4 * dt)
            }

            if v.speed > 0.02 {
                let fwd = V3(sin(v.facing), 0, cos(v.facing))
                var np = v.pos + fwd * (v.speed * dt)
                // The sea is the one thing they cannot walk on. A step that would
                // leave the land is refused and the waypoint abandoned, which
                // also covers a waypoint that turned out to be across a bay.
                if World.height(np.x, np.z) < 0.5 {
                    v.target = v.home
                    v.wait = 0
                } else {
                    pushOutOfObstacles(&np, radius: 0.38, obstacles)
                    np.y = World.height(np.x, np.z)
                    v.pos = np
                    v.walkPhase += v.speed * dt * 1.5
                }
            }

            if v.attention > 0.6 { v.greeted += dt } else if v.attention < 0.3 { v.greeted = 0 }
            let greet: Float = (v.attention > 0.6 && v.speed < 0.5 && v.greeted < 2.2) ? 1 : 0
            v.wave += (greet - v.wave) * min(1, 3.5 * dt)
            v.pos.y = World.height(v.pos.x, v.pos.z)
            vs[i] = v
        }
    }

    /// Walk cycle when moving, idle otherwise, with the greeting blended over
    /// the right arm. No jump, swim or slide: villagers have no state machine.
    static func pose(_ v: Villager, time: Float) -> PlayerPose {
        let clock = PoseClock(time: time + v.phase, walkPhase: v.walkPhase,
                              speedNorm: clampf(v.speed / strideScale, 0, 1))
        // Idle and walk are blended by speed rather than switched: stopping is a
        // half-second affair, and a single threshold popped the arms.
        let walk = clampf(v.speed / 0.9, 0, 1)
        var p = PlayerPose()
        p.add(Player.pose(.idle, clock), 1 - walk)
        p.add(Player.pose(.run, clock), walk)
        if v.wave > 0.01 {
            let swing = sin(time * 7.5 + v.phase)
            // A raised arm spreads with a negative `out`, same as the rise pose.
            // Up and out: a shoulder near pi puts the arm overhead (it travels
            // through the front, which is how a hand goes up), and `out` swings
            // it clear of the hat. The wobble is the wave.
            p.shoulderR = lerp(p.shoulderR, 2.95, v.wave)
            p.outR = lerp(p.outR, -0.62 + 0.16 * swing, v.wave)
            p.elbowR = lerp(p.elbowR, 0.25 + 0.10 * swing, v.wave)
            p.headPitch = lerp(p.headPitch, -0.06, v.wave)
        }
        return p
    }

    static func standable(_ p: V2, obstacles: [Obstacle]) -> Bool {
        if World.height(p.x, p.y) < 0.6 { return false }
        // Gentler than the player's 45 deg walk limit: a villager strolling up a
        // 40 deg face looks like a bug even though the physics allow it.
        if World.normal(p.x, p.y).y < 0.82 { return false }
        if World.pierHeight(p.x, p.y) > 0 { return false }
        return obstacleDistance(p, obstacles) > 0.9
    }

    /// A random point they can stand on, near home and not right next to where
    /// they already are. Rejection sampled for the same reason the crystals are:
    /// there is no list of coordinates to keep in step with the terrain.
    private static func waypoint(around home: V2, radius: Float, from pos: V3,
                                 obstacles: [Obstacle], rng: inout RNG) -> V2 {
        var best = home
        for _ in 0..<24 {
            let a = rng.range(0, 2 * Float.pi)
            let r = radius * sqrt(rng.next())
            let p = V2(home.x + cos(a) * r, home.y + sin(a) * r)
            best = p
            if !standable(p, obstacles: obstacles) { continue }
            if length(p - V2(pos.x, pos.z)) < 3.5 { continue }
            return p
        }
        return best
    }

    /// Turns `a` towards `b` by at most `max`, the short way round.
    private static func turn(_ a: Float, toward b: Float, max step: Float) -> Float {
        var d = b - a
        d -= (2 * Float.pi) * (d / (2 * Float.pi)).rounded()
        return a + clampf(d, -step, step)
    }
}
