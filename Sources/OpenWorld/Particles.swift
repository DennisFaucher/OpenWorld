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
    /// 0 droplet, 1 foam (pinned to the surface, squashed, broken up by noise),
    /// 2 dust (rises, spreads, softer edge). Read by the renderer and shader.
    var kind: Float = 0
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
                         size: Float.random(in: 0.06 ... 0.12) * s,
                         tint: V3(0.94, 0.98, 1.0), gravity: 17, drag: 1.6))
        }
        // A flat foam collar right where it went in.
        for _ in 0..<Int(4 * s) {
            let a = Float.random(in: 0 ..< 2 * Float.pi)
            let r = Float.random(in: 0.5 ... 1.6) * s
            add(Particle(pos: p + V3(cos(a) * r, 0.04, sin(a) * r),
                         vel: V3(cos(a) * 0.9, 0, sin(a) * 0.9),
                         life: Float.random(in: 0.6 ... 1.1), maxLife: 1.1,
                         size: Float.random(in: 0.10 ... 0.22) * s,
                         tint: V3(0.92, 0.98, 1.0), gravity: 0, drag: 1.1, kind: 1))
        }
    }

    /// A footfall: a few small puffs that spread and settle back down.
    func footstep(at p: V3, dir: V3, tint: V3, strength: Float) {
        let s = clampf(strength, 0.5, 1.8)
        for _ in 0..<Int(3 + s * 3) {
            let a = Float.random(in: 0 ..< 2 * Float.pi)
            let r = Float.random(in: 0.04 ... 0.20)
            add(Particle(pos: p + V3(cos(a) * r, 0.02, sin(a) * r),
                         vel: dir * Float.random(in: 0.2 ... 0.6)
                            + V3(cos(a) * 0.55, Float.random(in: 0.5 ... 1.4), sin(a) * 0.55),
                         life: Float.random(in: 0.40 ... 0.75), maxLife: 0.75,
                         size: Float.random(in: 0.13 ... 0.24) * s,
                         tint: tint, gravity: 1.4, drag: 2.4, kind: 2))
        }
    }

    /// A skid: bigger, faster dust thrown along the direction of travel. Sliding
    /// and scuffing at a face too steep to climb both use this.
    func skid(at p: V3, dir: V3, tint: V3, strength: Float) {
        let s = clampf(strength, 0.5, 1.8)
        for _ in 0..<Int(2 + s * 3) {
            let a = Float.random(in: 0 ..< 2 * Float.pi)
            let r = Float.random(in: 0 ... 0.18)
            // Lifted clear of the surface: on a steep face a puff spawned at
            // the feet is buried inside the terrain and never draws.
            add(Particle(pos: p + V3(cos(a) * r, 0.10, sin(a) * r),
                         vel: dir * Float.random(in: 0.4 ... 1.2)
                            + V3(cos(a) * 0.8, Float.random(in: 0.9 ... 2.2), sin(a) * 0.8),
                         life: Float.random(in: 0.50 ... 0.90), maxLife: 0.90,
                         size: Float.random(in: 0.16 ... 0.30) * s,
                         tint: tint, gravity: 2.2, drag: 2.0, kind: 2))
        }
    }

    func update(dt: Float, swimming: Bool, speed: Float, feet: V3, wading: Bool) {
        wakeTimer -= dt
        wadeTimer -= dt
        // Foam trail behind a swimmer. It has to overlap into a continuous wash:
        // sparse round sprites read as bubbles rather than churned water.
        if swimming && speed > 1.4 && wakeTimer <= 0 {
            wakeTimer = 0.035
            for _ in 0..<5 {
                let a = Float.random(in: 0 ..< 2 * Float.pi)
                let r = Float.random(in: 0.20 ... 0.85)
                add(Particle(pos: V3(feet.x + cos(a) * r, 0.05, feet.z + sin(a) * r),
                             vel: V3(cos(a) * 0.55, 0, sin(a) * 0.55),
                             life: Float.random(in: 0.40 ... 0.78), maxLife: 0.78,
                             size: Float.random(in: 0.10 ... 0.20), tint: V3(0.95, 0.99, 1.0),
                             gravity: 0, drag: 1.4, kind: 1))
            }
        }
        // Kick-up while wading through the shallows.
        if wading && speed > 2.0 && wadeTimer <= 0 {
            wadeTimer = 0.11
            for _ in 0..<4 {
                let a = Float.random(in: 0 ..< 2 * Float.pi)
                add(Particle(pos: V3(feet.x, feet.y + 0.05, feet.z),
                             vel: V3(cos(a) * 1.3, Float.random(in: 1.8 ... 3.6), sin(a) * 1.3),
                             life: Float.random(in: 0.35 ... 0.7), maxLife: 0.7,
                             size: Float.random(in: 0.10 ... 0.20), tint: V3(0.94, 0.99, 1.0),
                             gravity: 16, drag: 1.4))
            }
        }

        for i in parts.indices {
            parts[i].life -= dt
            parts[i].vel.y -= parts[i].gravity * dt
            parts[i].vel *= max(0, 1 - parts[i].drag * dt)
            parts[i].pos += parts[i].vel * dt
            // Foam stays on the surface even when the sea is moving under it.
            if parts[i].kind == 1 { parts[i].pos.y = 0.05 }
        }
        parts.removeAll { $0.life <= 0 }
    }
}
