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

    /// Nozzle at the chest, firing at whatever the eye ray hits, so the stream
    /// lands under the middle of the screen. It is not enough to shoot along the
    /// view: at a downward camera angle a shot along the ray hits the ground
    /// several metres short of what is being pointed at, which made the jet feel
    /// like it was refusing to reach the splat in front of it.
    static func aim(_ g: Game) -> (origin: V3, dir: V3) {
        // Slightly past the nozzle in the raised hand, so the stream does not
        // start inside the character's own arm.
        let origin = g.pos + V3(0, 1.24, 0) + V3(sin(g.facing), 0, cos(g.facing)) * 0.48
        let cp = cos(g.camPitch)
        let view = V3(-sin(g.camYaw) * cp, -sin(g.camPitch), -cos(g.camYaw) * cp)
        // `camPos` is only filled in at the end of the first update, so the very
        // first frame aims from the chest instead of from the origin.
        let eye = length(g.camPos) > 0.01 ? g.camPos : origin
        guard let target = rayHit(origin: eye, dir: view, obstacles: g.obstacles, maxDist: 26) else {
            return (origin, normalize(view + V3(0, 0.05, 0)))
        }
        let d = target - origin
        let flat = V2(d.x, d.z)
        let x = length(flat)
        let v2 = speed * speed
        // Throw (at a fixed speed) at a point: the elevation that reaches it
        // exactly. Two arcs pass through any reachable point; take the flatter
        // one so it still reads as a jet rather than a lob.
        let disc = v2 * v2 - gravity * (gravity * x * x + 2 * d.y * v2)
        guard x > 0.15, disc > 0 else { return (origin, normalize(view + V3(0, 0.05, 0))) }
        let tanT = (v2 - sqrt(disc)) / (gravity * x)
        let h = flat / x
        return (origin, normalize(V3(h.x, tanT, h.y)))
    }

    /// Straight-line march, used for the eye ray. Coarse steps: it only has to
    /// find which splat is under the middle of the screen.
    static func rayHit(origin: V3, dir: V3, obstacles: [Obstacle], maxDist: Float) -> V3? {
        var t: Float = 0.4
        while t < maxDist {
            let q = origin + dir * t
            let h = World.height(q.x, q.z)
            if q.y <= h { return V3(q.x, h, q.z) }
            for o in obstacles where q.y < o.topY {
                if o.round {
                    if length(V2(q.x, q.z) - o.center) < o.half.x { return q }
                } else {
                    let lo = o.center - o.half, hi = o.center + o.half
                    if q.x > lo.x && q.x < hi.x && q.z > lo.y && q.z < hi.y { return q }
                }
            }
            t += 0.3
        }
        return nil
    }

    /// First point along the arc that is inside the terrain or a building, with
    /// the time it took to get there — the stream is cut at that age so it ends
    /// on the surface instead of carrying on through it.
    static func impact(origin: V3, dir: V3, obstacles: [Obstacle]) -> (pos: V3, time: Float)? {
        var t: Float = 0.02
        while t < 1.5 {
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
