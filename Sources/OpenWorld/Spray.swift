import Foundation
import simd

/// A wet patch left where the jet lands. Darkens the ground, then dries.
struct Decal {
    var pos: V3
    var radius: Float
    var age: Float = 0
    var life: Float = 9
}

/// A splat of goo stuck to the ground. The jet washes it away, which is the
/// only thing in the world to aim at so far.
struct Goo {
    var pos: V3
    var radius: Float
    /// 1 = untouched, 0 = washed off.
    var health: Float = 1
}

/// The water jet. The stream is solved once per frame as a single ballistic arc,
/// and the particles are only the look of it: the impact point, the splash and
/// the wet patch then agree with each other instead of every droplet guessing at
/// its own collision.
enum Spray {
    /// Metres per second at the nozzle — fast enough to read as a jet rather
    /// than a fountain, slow enough that the arc is visible over 10 m.
    static let speed: Float = 26
    static let gravity: Float = 5.5

    /// Goo sits where a player walks into it: the plaza, the paths out to the
    /// beach, the bell tower approach. Only x and z are given; the height comes
    /// from the terrain.
    static let gooSites: [V2] = [
        V2(-18, 27), V2(-13, 33), V2(-24, 16), V2(-8, 23),
        V2(-31, 35), V2(-50, 46), V2(-53, 37), V2(5, 50),
        V2(-1, 17), V2(19, 9), V2(-40, 20), V2(-62, 30),
    ]

    /// Nozzle at the chest, aimed along the camera, so whatever is under the
    /// reticle is what gets wet. The aim deliberately does not use `camPos`:
    /// that is only computed at the end of the first update, and the first
    /// frame of a jet would fire at the origin.
    static func aim(_ g: Game) -> (origin: V3, dir: V3) {
        // Slightly past the nozzle in the raised hand, so the stream does not
        // start inside the character's own arm.
        let origin = g.pos + V3(0, 1.24, 0) + V3(sin(g.facing), 0, cos(g.facing)) * 0.48
        let cp = cos(g.camPitch)
        var dir = V3(-sin(g.camYaw) * cp, -sin(g.camPitch), -cos(g.camYaw) * cp)
        // The arc droops, so lift the aim a little to keep the impact where the
        // camera points.
        dir.y += 0.05
        return (origin, normalize(dir))
    }

    /// First point along the arc that is inside the terrain or a building, with
    /// the time it took to get there — the stream is cut at that age so it ends
    /// on the surface instead of carrying on through it.
    static func impact(origin: V3, dir: V3, obstacles: [Obstacle]) -> (pos: V3, time: Float)? {
        var t: Float = 0.02
        while t < 1.0 {
            let q = origin + dir * (speed * t) - V3(0, 0.5 * gravity * t * t, 0)
            let h = World.height(q.x, q.z)
            if q.y <= h { return (V3(q.x, h, q.z), t) }
            for o in obstacles where q.y < o.topY {
                if o.round {
                    if length(V2(q.x, q.z) - o.center) < o.half.x { return (q, t) }
                } else {
                    let lo = o.center - o.half, hi = o.center + o.half
                    if q.x > lo.x && q.x < hi.x && q.z > lo.y && q.z < hi.y { return (q, t) }
                }
            }
            t += 0.015
        }
        return nil
    }
}
