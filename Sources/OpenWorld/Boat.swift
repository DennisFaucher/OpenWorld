import Foundation
import simd

/// A small open boat, moored at the end of each island's pier. It floats on the
/// water line, is driven by the same throttle and steer as the character, and
/// refuses to run aground: the bow is sampled ahead and the hull stops when the
/// water is shallower than its draft.
final class Boat {
    static let maxSpeed: Float = 12
    static let reverseSpeed: Float = 3.5
    /// The bow stops where the water is shallower than this.
    static let minDepth: Float = -1.0
    /// How far the hull sits below the water line, and the height of the
    /// interior floor above it — which is where the player stands.
    static let draft: Float = 0.22
    static let deckY: Float = 0.12
    /// Mesh-space height of the rail, above the keel.
    static let railY: Float = 0.62

    var pos: V2
    var heading: Float
    var speed: Float = 0
    /// Bob and heel are cosmetic: the water surface under the hull is a shader.
    var bob: Float = 0
    var roll: Float = 0

    init(pos: V2, heading: Float) {
        self.pos = pos
        self.heading = heading
    }

    var forward: V2 { V2(sin(heading), cos(heading)) }

    func update(dt: Float, throttle: Float, steer: Float, time: Float) {
        let target = throttle >= 0 ? throttle * Boat.maxSpeed : throttle * Boat.reverseSpeed
        // Coasting slows the hull gently, powering up is quicker; anything else
        // feels like a car with the handbrake on.
        speed += (target - speed) * min(1, (abs(throttle) < 0.05 ? 0.7 : 1.5) * dt)
        if abs(speed) < 0.03 { speed = 0 }

        // A boat only answers the stick when it has way on, and backs the other
        // way when the throttle is reversed.
        let authority = clampf(abs(speed) / Boat.maxSpeed, 0, 1)
        heading += steer * (0.22 + 0.55 * authority) * dt * (speed < -0.2 ? -1 : 1)

        let f = forward
        let next = pos + f * (speed * dt)
        let bow = World.height(next.x + f.x * 1.8, next.y + f.y * 1.8)
        let stern = World.height(next.x - f.x * 1.8, next.y - f.y * 1.8)
        if bow > Boat.minDepth || stern > Boat.minDepth {
            speed *= 0.35
        } else {
            pos = next
        }
        let d = length(pos)
        if d > World.boundsRadius {
            pos = pos / d * World.boundsRadius
        }

        bob = sin(time * 1.7) * 0.045 + sin(time * 2.3 + 1.1) * 0.025
        roll = lerp(roll, steer * authority * 0.10, min(1, 5 * dt))
    }
}

extension Boat {
    /// Hull with a painted stripe, floor, two thwarts and a pair of oars: about
    /// 90 triangles, built once and drawn once per boat.
    static func buildMesh() -> MeshBuilder {
        let b = MeshBuilder()
        let cream = V3(0.96, 0.94, 0.88)
        let coral = V3(0.93, 0.42, 0.26)
        let wood = V3(0.56, 0.38, 0.22)
        let floor = V3(0.74, 0.56, 0.34)

        // Stations along the hull, keel to gunwale: (keel x, keel half-beam,
        // gunwale x, gunwale half-beam). The bow closes to a point.
        let stations: [(Float, Float, Float, Float)] = [
            (-1.35, 0.30, -1.62, 0.62),
            (0.15, 0.20, 0.15, 0.74),
            (1.55, 0.00, 1.86, 0.00),
        ]

        /// A hull point: `t` runs up the planking, 0 at the keel, 1 at the rail.
        func pt(_ s: Int, _ t: Float, _ side: Float) -> V3 {
            let st = stations[s]
            return V3(lerp(st.0, st.2, t), lerp(0.02, Boat.railY, t), side * lerp(st.1, st.3, t))
        }

        func quad(_ a: V3, _ c: V3, _ d: V3, _ e: V3, _ col: V3) {
            var n = normalize(cross(c - a, d - a))
            if n.y < 0 { n = -n }
            let i0 = b.add(a, n, col), i1 = b.add(c, n, col)
            let i2 = b.add(d, n, col), i3 = b.add(e, n, col)
            b.tri(i0, i1, i2)
            b.tri(i0, i2, i3)
        }

        for side in [Float(-1), Float(1)] {
            for s in 0..<2 {
                quad(pt(s, 0, side), pt(s + 1, 0, side),
                     pt(s + 1, 0.76, side), pt(s, 0.76, side), cream)
                quad(pt(s, 0.76, side), pt(s + 1, 0.76, side),
                     pt(s + 1, 1, side), pt(s, 1, side), coral)
            }
        }
        // Bottom and transom.
        quad(pt(0, 0, -1), pt(1, 0, -1), pt(1, 0, 1), pt(0, 0, 1), wood)
        quad(pt(1, 0, -1), pt(2, 0, -1), pt(2, 0, 1), pt(1, 0, 1), wood)
        quad(pt(0, 0, -1), pt(0, 0, 1), pt(0, 1, 1), pt(0, 1, -1), cream)

        // Floor clear of the water line, thwarts at knee height above it.
        b.box(min: V3(-1.15, 0.26, -0.44), max: V3(0.95, 0.34, 0.44), color: floor)
        for x: Float in [-0.55, 0.35] {
            b.box(min: V3(x - 0.15, 0.46, -0.52), max: V3(x + 0.15, 0.54, 0.52), color: floor)
        }
        for z: Float in [-0.58, 0.58] {
            b.box(min: V3(-0.75, 0.38, z - 0.05), max: V3(1.15, 0.44, z + 0.05), color: wood)
        }
        return b
    }
}
