import Foundation
import simd

/// A crystal lying on an island. Only the ground anchor is stored: the float
/// height, the spin and the bob are all derived from the clock, so a save file
/// needs nothing but the index of the ones already taken.
struct Shard {
    /// Where it sits on the ground, not where the gem floats.
    var pos: V3
    /// Per-shard offset for the spin and the bob, so a beach with six of them
    /// does not pulse in unison.
    var phase: Float
    var scale: Float

    /// The centre of the gem itself, bobbing a hand's width above the ground.
    /// Slightly above eye level of the character, so it reads as a thing to
    /// reach for rather than something underfoot.
    func gem(time: Float) -> V3 {
        pos + V3(0, Shards.floatHeight + 0.11 * sin(time * 1.6 + phase), 0)
    }

    func spin(time: Float) -> Float { time * 1.1 + phase }
}

/// The collectibles. Placed by rejection sampling against the height function
/// rather than by hand, so they follow the islands automatically, and the same
/// seed means the same field on every launch and every machine — which is what
/// lets a save file store indices instead of coordinates.
enum Shards {
    /// Roughly how many the archipelago holds. Island shares are proportional to
    /// area, so the home island gets the most and the smallest cay the fewest.
    static let target = 40
    /// The gem floats this far above the ground it sits on.
    static let floatHeight: Float = 0.95
    /// Pickup reach: generous, because the character is a metre wide and the gem
    /// bobs. A near miss that has to be lined up would feel like a bug.
    static let pickRadius: Float = 1.5
    static let pickHeight: Float = 2.4

    /// Two crystals closer than this would be picked up in one stride.
    private static let spacing: Float = 9
    /// Clearance from anything the player would have to walk through.
    private static let clearance: Float = 2.2

    static func field(obstacles: [Obstacle]) -> [Shard] {
        var out: [Shard] = []
        let area = World.islands.reduce(Float(0)) { $0 + $1.radius * $1.radius }
        var rng = RNG(seed: 0x5eed)
        for island in World.islands {
            let share = Float(target) * island.radius * island.radius / area
            let want = max(3, Int(share.rounded()))
            var islandRNG = RNG(seed: UInt64(island.seed * 131 + 7))
            var placed: [V3] = []
            var tries = 0
            while placed.count < want && tries < 6000 {
                tries += 1
                // Uniform over the disc, not over the radius: sampling r evenly
                // piles everything up on the coast.
                let a = islandRNG.range(0, 2 * Float.pi)
                let r = island.radius * sqrt(islandRNG.next())
                let x = island.centre.x + cos(a) * r
                let z = island.centre.y + sin(a) * r
                let h = World.height(x, z)
                // Dry land, and ground the player can actually stand on. The walk
                // limit is 45 deg; 0.78 keeps a margin so a shard is never on the
                // lip of a slide.
                if h < 0.7 || World.normal(x, z).y < 0.78 { continue }
                // Not on the jetty (it is a prop, not terrain) and not inside a
                // wall, a tower or a palm's collision shape.
                if World.pierHeight(x, z) > 0 { continue }
                if obstacleDistance(V2(x, z), obstacles) < clearance { continue }
                if length(V2(x, z) - V2(Game.spawn.x, Game.spawn.z)) < 6 { continue }
                let p = V3(x, h, z)
                if placed.contains(where: { length($0 - p) < spacing }) { continue }
                placed.append(p)
            }
            for p in placed {
                out.append(Shard(pos: p, phase: rng.range(0, 2 * Float.pi),
                                 scale: rng.range(0.88, 1.12)))
            }
        }
        return out
    }

    /// A four-sided bipyramid: eight triangles that read as a cut gem, and each
    /// face carries its own normal so the facets catch the light separately
    /// instead of shading as one smooth blob.
    static func buildMesh() -> MeshBuilder {
        let mb = MeshBuilder()
        let top = V3(0, 0.78, 0)
        let bottom = V3(0, -0.38, 0)
        let ring = (0..<4).map { i -> V3 in
            let a = Float(i) * Float.pi / 2 + Float.pi / 4
            return V3(cos(a) * 0.31, 0.10, sin(a) * 0.31)
        }
        // Faces are added one at a time so each gets its own vertices: sharing
        // them would average the normals across the ridge.
        func face(_ a: V3, _ b: V3, _ c: V3, _ colour: V3) {
            let n = normalize(cross(b - a, c - a))
            let i0 = mb.add(a, n, colour)
            let i1 = mb.add(b, n, colour)
            let i2 = mb.add(c, n, colour)
            mb.tri(i0, i1, i2)
        }
        for i in 0..<4 {
            let a = ring[i], b = ring[(i + 1) % 4]
            face(top, a, b, V3(1.00, 0.86, 0.44))
            face(bottom, b, a, V3(0.92, 0.60, 0.20))
        }
        return mb
    }
}
