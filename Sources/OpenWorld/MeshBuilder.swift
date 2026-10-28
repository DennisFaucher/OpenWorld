import simd

/// Layout must match `VIn` in the shader: three float4s, 48 bytes.
struct Vertex {
    var pos: V4
    var nrm: V4
    var col: V4
}

/// Collision shape in the XZ plane. `round` uses `half.x` as the radius.
struct Obstacle {
    var center: V2
    var half: V2
    var round: Bool
    var topY: Float
}

/// Distance from `p` to the nearest obstacle edge in the XZ plane, negative
/// inside one. Shared by anything that has to place or push a character.
func obstacleDistance(_ p: V2, _ obstacles: [Obstacle]) -> Float {
    var best = Float.greatestFiniteMagnitude
    for o in obstacles {
        let d: Float
        if o.round {
            d = length(p - o.center) - o.half.x
        } else {
            let q = abs(p - o.center) - o.half
            d = length(max(q, V2(repeating: 0)))
        }
        best = min(best, d)
    }
    return best
}

/// Pushes `p` out of any obstacle it is inside: a slide along the near face,
/// which is all a walking character needs. Boxes are escaped through their
/// nearest side when the centre is somehow already inside.
func pushOutOfObstacles(_ p: inout V3, radius r: Float, _ obstacles: [Obstacle]) {
    for o in obstacles {
        let xz = V2(p.x, p.z)
        if o.round {
            let d = xz - o.center
            let l = length(d)
            let minD = o.half.x + r
            if l < minD && l > 1e-4 {
                let c = o.center + d / l * minD
                p.x = c.x
                p.z = c.y
            }
        } else {
            let lo = o.center - o.half, hi = o.center + o.half
            let c = V2(clampf(xz.x, lo.x, hi.x), clampf(xz.y, lo.y, hi.y))
            let d = xz - c
            let l = length(d)
            if l > 1e-5 {
                if l < r {
                    let e = c + d / l * r
                    p.x = e.x
                    p.z = e.y
                }
            } else {
                let dl = xz.x - lo.x, dr = hi.x - xz.x, db = xz.y - lo.y, dt = hi.y - xz.y
                let m = min(min(dl, dr), min(db, dt))
                if m == dl { p.x = lo.x - r } else if m == dr { p.x = hi.x + r } else if m == db { p.z = lo.y - r } else { p.z = hi.y + r }
            }
        }
    }
}

final class MeshBuilder {
    var vertices: [Vertex] = []
    var indices: [UInt32] = []

    @discardableResult
    func add(_ p: V3, _ n: V3, _ c: V3, alpha: Float = 1, translucency: Float = 0) -> UInt32 {
        vertices.append(Vertex(pos: V4(p, 1), nrm: V4(n, translucency), col: V4(c, alpha)))
        return UInt32(vertices.count - 1)
    }

    func tri(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        indices.append(a)
        indices.append(b)
        indices.append(c)
    }

    /// Flat quad spanned by `u` and `v` from `origin`; the normal is cross(u, v).
    func quad(origin: V3, u: V3, v: V3, color: V3) {
        let n = normalize(cross(u, v))
        let a = add(origin, n, color)
        let b = add(origin + u, n, color)
        let c = add(origin + u + v, n, color)
        let d = add(origin + v, n, color)
        tri(a, b, c)
        tri(a, c, d)
    }

    func box(min lo: V3, max hi: V3, color: V3) {
        let d = hi - lo
        quad(origin: V3(hi.x, lo.y, hi.z), u: V3(0, 0, -d.z), v: V3(0, d.y, 0), color: color)
        quad(origin: V3(lo.x, lo.y, lo.z), u: V3(0, 0, d.z), v: V3(0, d.y, 0), color: color)
        quad(origin: V3(lo.x, hi.y, hi.z), u: V3(d.x, 0, 0), v: V3(0, 0, -d.z), color: color * 1.05)
        quad(origin: V3(lo.x, lo.y, lo.z), u: V3(d.x, 0, 0), v: V3(0, 0, d.z), color: color * 0.6)
        quad(origin: V3(lo.x, lo.y, hi.z), u: V3(d.x, 0, 0), v: V3(0, d.y, 0), color: color)
        quad(origin: V3(hi.x, lo.y, lo.z), u: V3(-d.x, 0, 0), v: V3(0, d.y, 0), color: color)
    }

    /// Quad with per-corner colours, ordered `origin`, `+u`, `+u+v`, `+v`.
    func quad4(origin: V3, u: V3, v: V3, c0: V3, c1: V3, c2: V3, c3: V3) {
        let n = normalize(cross(u, v))
        let a = add(origin, n, c0)
        let b = add(origin + u, n, c1)
        let c = add(origin + u + v, n, c2)
        let d = add(origin + v, n, c3)
        tri(a, b, c)
        tri(a, c, d)
    }

    /// Box whose four vertical faces darken towards `groundY`. There is no SSAO,
    /// so this bakes the contact shadow into the wall: without it buildings read
    /// as cardboard standing on the grass.
    func groundedBox(min lo: V3, max hi: V3, color: V3, groundY: Float,
                     aoDepth: Float = 2.4, aoStrength: Float = 0.30) {
        let d = hi - lo
        let dark = color * (1 - aoStrength)
        let baseY = min(max(groundY, lo.y), hi.y)
        let midY = min(baseY + aoDepth, hi.y)
        quad(origin: V3(lo.x, hi.y, hi.z), u: V3(d.x, 0, 0), v: V3(0, 0, -d.z), color: color * 1.05)
        quad(origin: V3(lo.x, lo.y, lo.z), u: V3(d.x, 0, 0), v: V3(0, 0, d.z), color: color * 0.6)
        let sides: [(V3, V3)] = [
            (V3(hi.x, 0, hi.z), V3(0, 0, -d.z)), (V3(lo.x, 0, lo.z), V3(0, 0, d.z)),
            (V3(lo.x, 0, hi.z), V3(d.x, 0, 0)), (V3(hi.x, 0, lo.z), V3(-d.x, 0, 0)),
        ]
        for (o, u) in sides {
            if baseY > lo.y { quad(origin: V3(o.x, lo.y, o.z), u: u, v: V3(0, baseY - lo.y, 0), color: dark) }
            if midY > baseY {
                quad4(origin: V3(o.x, baseY, o.z), u: u, v: V3(0, midY - baseY, 0),
                      c0: dark, c1: dark, c2: color, c3: color)
            }
            if hi.y > midY { quad(origin: V3(o.x, midY, o.z), u: u, v: V3(0, hi.y - midY, 0), color: color) }
        }
    }

    /// Four-sided hip roof.
    func pyramid(center: V3, hx: Float, hz: Float, height: Float, color: V3) {
        let apex = center + V3(0, height, 0)
        let corners = [
            center + V3(-hx, 0, -hz), center + V3(hx, 0, -hz),
            center + V3(hx, 0, hz), center + V3(-hx, 0, hz),
        ]
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            var n = normalize(cross(b - a, apex - a))
            if n.y < 0 { n = -n }
            let shade: Float = 0.9 + 0.1 * Float(i % 2)
            let ia = add(a, n, color * shade)
            let ib = add(b, n, color * shade)
            let ic = add(apex, n, color * shade)
            tri(ia, ib, ic)
        }
    }

    func frustum(base: V3, r0: Float, r1: Float, height: Float, sides: Int, color: V3) {
        let start = UInt32(vertices.count)
        for ring in 0..<2 {
            let r = ring == 0 ? r0 : r1
            for j in 0...sides {
                let a = Float(j) / Float(sides) * 2 * Float.pi
                let n = V3(cos(a), 0, sin(a))
                add(base + V3(0, height * Float(ring), 0) + n * r, n, color)
            }
        }
        let stride = UInt32(sides + 1)
        for j in 0..<UInt32(sides) {
            let a = start + j, b = a + 1, c = a + stride, d = b + stride
            tri(a, c, b)
            tri(b, c, d)
        }
    }

    func sphere(center: V3, radii: V3, color: V3, rings: Int = 10, segs: Int = 16) {
        let base = UInt32(vertices.count)
        for i in 0...rings {
            let phi = Float(i) / Float(rings) * Float.pi
            for j in 0...segs {
                let th = Float(j) / Float(segs) * 2 * Float.pi
                let n = V3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
                add(center + n * radii, normalize(n / radii), color)
            }
        }
        let stride = UInt32(segs + 1)
        for i in 0..<UInt32(rings) {
            for j in 0..<UInt32(segs) {
                let a = base + i * stride + j, b = a + 1, c = a + stride, d = c + 1
                tri(a, c, b)
                tri(b, c, d)
            }
        }
    }

    func palm(base: V3, height: Float, leanDir: Float, lean: Float, seed: Float) {
        let segs = 8, sides = 7
        var centers: [V3] = []
        for i in 0...segs {
            let t = Float(i) / Float(segs)
            centers.append(base + V3(cos(leanDir) * lean * t * t, height * t, sin(leanDir) * lean * t * t))
        }
        let ringStart = UInt32(vertices.count)
        for i in 0...segs {
            let t = Float(i) / Float(segs)
            let r = lerp(0.34, 0.2, t)
            let band: Float = i % 2 == 0 ? 1.0 : 0.82
            let col = V3(0.62, 0.44, 0.26) * band
            for j in 0..<sides {
                let a = Float(j) / Float(sides) * 2 * Float.pi
                let n = V3(cos(a), 0, sin(a))
                add(centers[i] + n * r, n, col)
            }
        }
        for i in 0..<segs {
            for j in 0..<sides {
                let j2 = (j + 1) % sides
                let a = ringStart + UInt32(i * sides + j)
                let b = ringStart + UInt32(i * sides + j2)
                let c = a + UInt32(sides), d = b + UInt32(sides)
                tri(a, c, b)
                tri(b, c, d)
            }
        }

        let top = centers[segs]
        let fronds = 9
        for k in 0..<fronds {
            let ang = Float(k) / Float(fronds) * 2 * Float.pi + seed
            let dir = V3(cos(ang), 0, sin(ang))
            let side = V3(-dir.z, 0, dir.x)
            let len: Float = 3.8 + 0.6 * sin(seed * 7 + Float(k) * 2.1)
            let pieces = 6
            var prevL: UInt32 = 0, prevR: UInt32 = 0
            for s in 0...pieces {
                let u = Float(s) / Float(pieces)
                let p = top + dir * (u * len) + V3(0, 1.2 * u - 2.0 * u * u + 0.25, 0)
                let w = 0.85 * sqrt(max(0, 1 - u)) * min(1, 0.4 + u * 5)
                let tangent = dir * (len / Float(pieces)) + V3(0, (1.2 - 4.0 * u) / Float(pieces), 0)
                var n = normalize(cross(side, tangent))
                if n.y < 0 { n = -n }
                let col = lerp(V3(0.13, 0.5, 0.14), V3(0.4, 0.78, 0.2), u)
                let l = add(p + side * w, n, col, translucency: 1)
                let r = add(p - side * w, n, col, translucency: 1)
                if s > 0 {
                    tri(prevL, prevR, r)
                    tri(prevL, r, l)
                }
                prevL = l
                prevR = r
            }
        }
        let nut = V3(0.4, 0.26, 0.14)
        for k in 0..<3 {
            let a = Float(k) / 3 * 2 * Float.pi + seed
            sphere(center: top + V3(cos(a) * 0.3, -0.3, sin(a) * 0.3), radii: V3(repeating: 0.2), color: nut, rings: 5, segs: 8)
        }
    }
}
