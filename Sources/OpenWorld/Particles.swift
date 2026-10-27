import Foundation
import simd

/// A single camera-facing sprite. Simulated on the CPU (a few hundred at most)
/// and rebuilt each frame as billboard quads.
struct Particle {
    var pos: V3
    var vel: V3
    var life: Float
    var maxLife: Float
    var size: Float
    var tint: V3
    var gravity: Float
    var drag: Float
}

/// Water wakes, landing splashes and wading spray. Foam sits pinned to the
/// surface; droplets are thrown up and fall back.
final class ParticleSystem {
    private(set) var parts: [Particle] = []
    private var wakeTimer: Float = 0
    private var wadeTimer: Float = 0
    private static let limit = 600

    func clear() { parts.removeAll(keepingCapacity: true) }

    private func add(_ p: Particle) {
        if parts.count >= ParticleSystem.limit { parts.removeFirst(parts.count - ParticleSystem.limit + 1) }
        parts.append(p)
    }

    /// Droplets thrown out of the water when the player breaks the surface.
    func splash(at p: V3, strength: Float) {
        let n = Int(clampf(strength * 6, 6, 26))
        let s = clampf(strength, 0.5, 2.4)
        for _ in 0..<n {
            let a = Float.random(in: 0 ..< 2 * Float.pi)
            let r = Float.random(in: 0.35 ... 1.0)
            add(Particle(pos: p + V3(0, 0.1, 0),
                         vel: V3(cos(a) * r * 2.2 * s, Float.random(in: 2.2 ... 5.0) * s, sin(a) * r * 2.2 * s),
                         life: Float.random(in: 0.45 ... 0.9), maxLife: 0.9,
                         size: Float.random(in: 0.10 ... 0.26) * s,
                         tint: V3(0.94, 0.98, 1.0), gravity: 17, drag: 1.6))
        }
        // A flat foam collar right where it went in.
        for _ in 0..<Int(4 * s) {
            let a = Float.random(in: 0 ..< 2 * Float.pi)
            let r = Float.random(in: 0.5 ... 1.6) * s
            add(Particle(pos: p + V3(cos(a) * r, 0.04, sin(a) * r),
                         vel: V3(cos(a) * 0.9, 0, sin(a) * 0.9),
                         life: Float.random(in: 0.6 ... 1.1), maxLife: 1.1,
                         size: Float.random(in: 0.14 ... 0.26) * s,
                         tint: V3(0.92, 0.98, 1.0), gravity: 0, drag: 1.1))
        }
    }

    func update(dt: Float, swimming: Bool, speed: Float, feet: V3, wading: Bool) {
        wakeTimer -= dt
        wadeTimer -= dt
        // Foam trail behind a swimmer.
        if swimming && speed > 1.4 && wakeTimer <= 0 {
            wakeTimer = 0.055
            for _ in 0..<2 {
                let a = Float.random(in: 0 ..< 2 * Float.pi)
                let r = Float.random(in: 0.35 ... 0.75)
                add(Particle(pos: V3(feet.x + cos(a) * r, 0.05, feet.z + sin(a) * r),
                             vel: V3(cos(a) * 1.1, 0, sin(a) * 1.1),
                             life: Float.random(in: 0.5 ... 0.95), maxLife: 0.95,
                             size: Float.random(in: 0.12 ... 0.24), tint: V3(0.92, 0.98, 1.0),
                             gravity: 0, drag: 1.4))
            }
        }
        // Kick-up while wading through the shallows.
        if wading && speed > 2.5 && wadeTimer <= 0 {
            wadeTimer = 0.16
            for _ in 0..<3 {
                let a = Float.random(in: 0 ..< 2 * Float.pi)
                add(Particle(pos: V3(feet.x, feet.y + 0.05, feet.z),
                             vel: V3(cos(a) * 1.0, Float.random(in: 1.4 ... 3.0), sin(a) * 1.0),
                             life: Float.random(in: 0.3 ... 0.6), maxLife: 0.6,
                             size: Float.random(in: 0.07 ... 0.16), tint: V3(0.95, 0.99, 1.0),
                             gravity: 16, drag: 1.4))
            }
        }

        for i in parts.indices {
            parts[i].life -= dt
            parts[i].vel.y -= parts[i].gravity * dt
            parts[i].vel *= max(0, 1 - parts[i].drag * dt)
            parts[i].pos += parts[i].vel * dt
            // Foam stays on the surface even when the sea is moving under it.
            if parts[i].gravity == 0 { parts[i].pos.y = 0.05 }
        }
        parts.removeAll { $0.life <= 0 }
    }
}
