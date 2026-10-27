import simd

typealias V2 = SIMD2<Float>
typealias V3 = SIMD3<Float>
typealias V4 = SIMD4<Float>
typealias M4 = simd_float4x4

func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
func lerp(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }

func sstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }

extension M4 {
    static func translation(_ t: V3) -> M4 {
        var m = matrix_identity_float4x4
        m.columns.3 = V4(t, 1)
        return m
    }

    static func scale(_ s: V3) -> M4 {
        M4(diagonal: V4(s, 1))
    }

    static func rotationX(_ a: Float) -> M4 {
        let c = cos(a), s = sin(a)
        return M4(columns: (V4(1, 0, 0, 0), V4(0, c, s, 0), V4(0, -s, c, 0), V4(0, 0, 0, 1)))
    }

    static func rotationY(_ a: Float) -> M4 {
        let c = cos(a), s = sin(a)
        return M4(columns: (V4(c, 0, -s, 0), V4(0, 1, 0, 0), V4(s, 0, c, 0), V4(0, 0, 0, 1)))
    }

    /// Right-handed perspective with Metal's 0...1 clip-space depth.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> M4 {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return M4(columns: (V4(xs, 0, 0, 0), V4(0, ys, 0, 0), V4(0, 0, zs, -1), V4(0, 0, zs * near, 0)))
    }

    /// Right-handed orthographic with Metal's 0...1 clip-space depth.
    static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> M4 {
        let xs = 2 / (right - left)
        let ys = 2 / (top - bottom)
        let zs = 1 / (near - far)
        let tx = (right + left) / (left - right)
        let ty = (top + bottom) / (bottom - top)
        let tz = near / (near - far)
        return M4(columns: (
            V4(xs, 0, 0, 0),
            V4(0, ys, 0, 0),
            V4(0, 0, zs, 0),
            V4(tx, ty, tz, 1)
        ))
    }

    static func lookAt(eye: V3, center: V3, up: V3) -> M4 {
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return M4(columns: (
            V4(x.x, y.x, z.x, 0),
            V4(x.y, y.y, z.y, 0),
            V4(x.z, y.z, z.z, 0),
            V4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        ))
    }
}

/// Small deterministic RNG so the island is the same every launch.
struct RNG {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float((state >> 40) & 0xFFFFFF) / Float(0x1000000)
    }

    mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * next() }
}
