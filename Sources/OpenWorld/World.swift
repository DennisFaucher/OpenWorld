import Foundation
import simd

private func hash2(_ x: Int, _ y: Int) -> Float {
    var h = UInt32(truncatingIfNeeded: x) &* 374761393 &+ UInt32(truncatingIfNeeded: y) &* 668265263
    h = (h ^ (h >> 13)) &* 1274126177
    h ^= h >> 16
    return Float(h & 0xFFFFFF) / Float(0x1000000)
}

private func valueNoise(_ x: Float, _ y: Float) -> Float {
    let fx = floor(x), fy = floor(y)
    let xi = Int(fx), yi = Int(fy)
    let tx = x - fx, ty = y - fy
    let u = tx * tx * (3 - 2 * tx), v = ty * ty * (3 - 2 * ty)
    let a = lerp(hash2(xi, yi), hash2(xi + 1, yi), u)
    let b = lerp(hash2(xi, yi + 1), hash2(xi + 1, yi + 1), u)
    return lerp(a, b, v)
}

private func fbm(_ x: Float, _ y: Float) -> Float {
    var sum: Float = 0, amp: Float = 0.5, f: Float = 1
    for _ in 0..<4 {
        sum += amp * valueNoise(x * f, y * f)
        amp *= 0.5
        f *= 2.03
    }
    return sum / 0.9375
}

/// One island of the archipelago. The home island is the original one: same
/// centre, same radius, so the plaza, the mountain and every existing landmark
/// stay exactly where they were.
struct Island {
    var centre: V2
    /// Nominal land radius. The coastline wobbles roughly +-22 m around it.
    var radius: Float = 72
    /// Height of the summit cone on top of the rolling ground.
    var peak: Float = 20
    var seed: Float = 0
    /// Terrain cell size: the home island is walked on, the others are seen
    /// from 100 m away, so they can be sampled half as finely.
    var cell: Float = 1
    var home: Bool = false
}

enum World {
    /// Half-size of the world, in world units. Covers every island and a little
    /// open water around them.
    static let extent: Float = 340
    static let waterLevel: Float = 0
    static let seabed: Float = -4
    static let plazaCenter = V2(-18, 22)
    static let plazaRadius: Float = 13
    static let plazaHeight: Float = 3.2
    /// Players can't swim farther than this from the origin.
    static let boundsRadius: Float = 320

    static let islands: [Island] = [
        Island(centre: V2(0, 0), radius: 72, peak: 20, seed: 0, cell: 1, home: true),
        Island(centre: V2(-200, 130), radius: 46, peak: 10, seed: 31),
        Island(centre: V2(180, 214), radius: 54, peak: 15, seed: 57),
        Island(centre: V2(96, -204), radius: 38, peak: 7, seed: 83),
    ]

    /// The height of one island at a point, ignoring the others. A point far
    /// enough outside the coastline is always seabed, which is what lets the
    /// caller skip the expensive noise for every island it is nowhere near.
    private static func islandHeight(_ i: Island, _ x: Float, _ z: Float) -> Float {
        let p = V2(x, z) - i.centre
        let d = length(p)
        // The warp can move the coastline by +-22 m and the summit mask reaches
        // 14 m past it; nothing beyond that can be above the water.
        if d > i.radius + 40 { return seabed }
        let warp = (fbm(x * 0.022 + 11.3 + i.seed, z * 0.022 + 4.7 + i.seed * 1.7) - 0.5) * 44
        let t = i.radius - (d + warp)
        let land = sstep(-6, 12, t)
        var h = seabed + land * 5.8
        h += sstep(12, 50, t) * (3 + fbm(x * 0.05 + i.seed, z * 0.05 + 9 + i.seed) * 9)
        let mp = p - (i.home ? V2(34, -28) : V2(-i.radius * 0.35, i.radius * 0.3))
        h += i.peak * exp(-dot(mp, mp) / (2 * 15 * 15)) * sstep(0, 14, t)
        if i.home {
            let pw = 1 - sstep(plazaRadius, plazaRadius + 12, length(p - plazaCenter))
            h = lerp(h, plazaHeight, pw)
        }
        return max(h, seabed)
    }

    static func height(_ x: Float, _ z: Float) -> Float {
        var h = seabed
        for i in islands {
            h = max(h, islandHeight(i, x, z))
        }
        return h
    }

    static func normal(_ x: Float, _ z: Float) -> V3 {
        let e: Float = 0.4
        let dx = height(x + e, z) - height(x - e, z)
        let dz = height(x, z + e) - height(x, z - e)
        return normalize(V3(-dx / (2 * e), 1, -dz / (2 * e)))
    }

    static func heightTexture(size: Int) -> [Float] {
        var out = [Float](repeating: 0, count: size * size)
        for j in 0..<size {
            let z = -extent + (Float(j) + 0.5) / Float(size) * 2 * extent
            for i in 0..<size {
                let x = -extent + (Float(i) + 0.5) / Float(size) * 2 * extent
                out[j * size + i] = height(x, z)
            }
        }
        return out
    }

    /// One drawable slice of the terrain: a range of indices into the shared
    /// vertex buffer, plus the box used to cull it.
    struct TerrainChunk {
        var firstIndex: Int
        var indexCount: Int
        var lo: V3
        var hi: V3
    }

    /// Chunks are cut on a fixed grid so a chunk's indices stay contiguous and
    /// a whole chunk can be skipped with one draw-range check.
    static let chunkSize: Float = 16

    static func buildTerrain() -> (mesh: MeshBuilder, chunks: [TerrainChunk]) {
        let b = MeshBuilder()
        var chunks: [TerrainChunk] = []
        for island in islands {
            addPatch(island.centre, radius: island.radius, cell: island.cell, to: b, chunks: &chunks)
        }
        return (b, chunks)
    }

    /// Ground colour from height and slope. Shared by the island patches so the
    /// beaches and the grass line agree across the archipelago.
    private static func ground(_ x: Float, _ z: Float, _ h: Float, _ n: V3) -> V3 {
        let sand = V3(0.97, 0.87, 0.56)
        let grassA = V3(0.36, 0.78, 0.2)
        let grassB = V3(0.62, 0.86, 0.26)
        let rock = V3(0.60, 0.60, 0.58)
        // Wobble the sand/grass threshold so the beach meets the hill along a
        // ragged line rather than a wide band of half-and-half mud.
        let wob = (fbm(x * 0.07, z * 0.07 + 3) - 0.5) * 0.9
        var c = lerp(grassA, grassB, fbm(x * 0.07, z * 0.07 + 3))
        c = lerp(sand, c, sstep(1.10, 1.95, h + wob))
        return lerp(c, rock, sstep(0.74, 0.52, n.y))
    }

    /// One square of terrain around an island. It has to clear the wobbliest
    /// coastline and end on a chunk boundary, so every chunk is a whole square
    /// and patches never leave a gap.
    private static func addPatch(_ centre: V2, radius: Float, cell: Float,
                                 to b: MeshBuilder, chunks: inout [TerrainChunk]) {
        let half = (ceil((radius + 26) / chunkSize)) * chunkSize
        let cells = Int(half * 2 / cell)
        let stride = cells + 1
        let base = b.vertices.count
        let x0 = centre.x - half, z0 = centre.y - half
        for j in 0...cells {
            let z = z0 + Float(j) * cell
            for i in 0...cells {
                let x = x0 + Float(i) * cell
                let h = height(x, z)
                // Alpha 0.5 flags terrain for the fragment shader's detail.
                b.add(V3(x, h, z), normal(x, z), ground(x, z, h, normal(x, z)), alpha: 0.5)
            }
        }
        let per = max(1, Int(chunkSize / cell))
        for cj in 0..<(cells / per) {
            for ci in 0..<(cells / per) {
                let first = b.indices.count
                for j in (cj * per)..<((cj + 1) * per) {
                    for i in (ci * per)..<((ci + 1) * per) {
                        let a = UInt32(base + j * stride + i)
                        let bb = a + 1, c = a + UInt32(stride), d = c + 1
                        b.tri(a, c, bb)
                        b.tri(bb, c, d)
                    }
                }
                var loY = Float.greatestFiniteMagnitude
                var hiY = -Float.greatestFiniteMagnitude
                for j in (cj * per)...((cj + 1) * per) {
                    for i in (ci * per)...((ci + 1) * per) {
                        let y = b.vertices[base + j * stride + i].pos.y
                        loY = min(loY, y)
                        hiY = max(hiY, y)
                    }
                }
                let cx = x0 + Float(ci) * chunkSize
                let cz = z0 + Float(cj) * chunkSize
                chunks.append(TerrainChunk(firstIndex: first,
                                           indexCount: b.indices.count - first,
                                           lo: V3(cx, loY, cz),
                                           hi: V3(cx + chunkSize, hiY, cz + chunkSize)))
            }
        }
    }

    /// The open sea floor: one flat sheet at seabed height with the island
    /// patches cut out of it, so nothing is coplanar under a patch.
    static func buildSeabed() -> MeshBuilder {
        let b = MeshBuilder()
        let step: Float = 8
        let n = Int(extent * 2 / step)
        let sand = V3(0.94, 0.84, 0.54)
        let patches = islands.map { (centre: $0.centre,
                                     half: (ceil(($0.radius + 26) / chunkSize)) * chunkSize) }
        var index = [Int](repeating: -1, count: (n + 1) * (n + 1))
        func vert(_ i: Int, _ j: Int) -> UInt32 {
            let k = j * (n + 1) + i
            if index[k] < 0 {
                let x = -extent + Float(i) * step
                let z = -extent + Float(j) * step
                index[k] = Int(b.add(V3(x, seabed, z), V3(0, 1, 0), sand, alpha: 0.5))
            }
            return UInt32(index[k])
        }
        for j in 0..<n {
            for i in 0..<n {
                let cx = -extent + (Float(i) + 0.5) * step
                let cz = -extent + (Float(j) + 0.5) * step
                if patches.contains(where: { abs(cx - $0.centre.x) <= $0.half && abs(cz - $0.centre.y) <= $0.half }) {
                    continue
                }
                let a = vert(i, j), bb = vert(i + 1, j), c = vert(i, j + 1), d = vert(i + 1, j + 1)
                b.tri(a, c, bb)
                b.tri(bb, c, d)
            }
        }
        return b
    }

    static func buildProps() -> (mesh: MeshBuilder, obstacles: [Obstacle]) {
        let b = MeshBuilder()
        var obstacles: [Obstacle] = []
        var rng = RNG(seed: 42)

        func nearPlaza(_ x: Float, _ z: Float, _ margin: Float) -> Bool {
            length(V2(x, z) - plazaCenter) < plazaRadius + margin
        }

        // Palms along the beaches and low ground, on every island. Counts scale
        // with the island's size so a small cay is not a forest.
        let petals: [V3] = [V3(1, 0.85, 0.15), V3(1, 0.45, 0.7), V3(1, 1, 1), V3(0.95, 0.25, 0.2)]
        for island in islands {
            let reach = island.radius * 1.02
            var palms: [V2] = []
            var tries = 0
            let wantPalms = island.home ? 80 : Int(island.radius * 0.55)
            while palms.count < wantPalms && tries < 6000 {
                tries += 1
                let x = island.centre.x + rng.range(-reach, reach)
                let z = island.centre.y + rng.range(-reach, reach)
                let h = height(x, z)
                if h < 0.9 || h > 3.0 || normal(x, z).y < 0.9 || nearPlaza(x, z, 10) { continue }
                let p = V2(x, z)
                if palms.contains(where: { length($0 - p) < 5 }) { continue }
                palms.append(p)
                let ht = rng.range(5.5, 8.0)
                b.palm(base: V3(x, h - 0.2, z), height: ht, leanDir: rng.range(0, 6.28), lean: rng.range(0.5, 2.2), seed: rng.range(0, 6.28))
                obstacles.append(Obstacle(center: p, half: V2(0.4, 0.4), round: true, topY: h + ht))
            }

            var bushes = 0
            tries = 0
            let wantBushes = island.home ? 90 : Int(island.radius * 0.6)
            while bushes < wantBushes && tries < 4000 {
                tries += 1
                let x = island.centre.x + rng.range(-reach, reach)
                let z = island.centre.y + rng.range(-reach, reach)
                let h = height(x, z)
                if h < 2.4 || normal(x, z).y < 0.85 || nearPlaza(x, z, 8) { continue }
                let r = rng.range(0.7, 1.3)
                let g = lerp(V3(0.16, 0.55, 0.16), V3(0.3, 0.7, 0.2), rng.next())
                b.sphere(center: V3(x, h + r * 0.3, z), radii: V3(r, r * 0.8, r), color: g, rings: 6, segs: 10)
                bushes += 1
            }

            var flowers = 0
            tries = 0
            let wantFlowers = island.home ? 400 : Int(island.radius * 1.6)
            while flowers < wantFlowers && tries < 8000 {
                tries += 1
                let x = island.centre.x + rng.range(-reach, reach)
                let z = island.centre.y + rng.range(-reach, reach)
                let h = height(x, z)
                if h < 2.3 || normal(x, z).y < 0.9 || nearPlaza(x, z, 3) { continue }
                let col = petals[Int(rng.next() * 4) % 4]
                b.sphere(center: V3(x, h + 0.12, z), radii: V3(0.14, 0.1, 0.14), color: col, rings: 4, segs: 6)
                flowers += 1
            }
        }

        // Plaza buildings, doors facing the plaza centre.
        struct Spec { var dx: Float; var dz: Float; var w: Float; var d: Float; var h: Float; var wall: V3; var roof: V3 }
        let specs: [Spec] = [
            Spec(dx: -21, dz: 2, w: 8, d: 9, h: 6, wall: V3(0.99, 0.93, 0.78), roof: V3(0.9, 0.35, 0.2)),
            Spec(dx: 21, dz: 4, w: 9, d: 8, h: 5.5, wall: V3(1, 0.96, 0.9), roof: V3(0.15, 0.62, 0.72)),
            Spec(dx: -4, dz: 21, w: 10, d: 7, h: 6.5, wall: V3(1, 0.88, 0.6), roof: V3(0.85, 0.25, 0.3)),
            Spec(dx: 8, dz: -21, w: 9, d: 7, h: 5.5, wall: V3(0.98, 0.93, 0.8), roof: V3(0.95, 0.55, 0.15)),
            Spec(dx: -18, dz: -16, w: 7, d: 8, h: 7, wall: V3(1, 0.94, 0.85), roof: V3(0.2, 0.55, 0.8)),
        ]
        for s in specs {
            let cx = plazaCenter.x + s.dx, cz = plazaCenter.y + s.dz
            if height(cx, cz) < 0.5 { continue }
            let x0 = cx - s.w / 2, x1 = cx + s.w / 2, z0 = cz - s.d / 2, z1 = cz + s.d / 2
            let corners = [height(x0, z0), height(x1, z0), height(x0, z1), height(x1, z1)]
            let baseY = corners.max()!
            let lowY = corners.min()! - 4
            let topY = baseY + s.h
            b.groundedBox(min: V3(x0, lowY, z0), max: V3(x1, topY, z1),
                          color: s.wall, groundY: (corners.min()! + baseY) * 0.5)
            b.pyramid(center: V3(cx, topY, cz), hx: s.w / 2 + 0.7, hz: s.d / 2 + 0.7, height: 3.2, color: s.roof)

            func attach(_ onX: Bool, _ sign: Float, _ along: Float, _ y0: Float, _ y1: Float, _ width: Float, _ color: V3) {
                if onX {
                    let fx = sign > 0 ? x1 : x0
                    b.box(min: V3(fx - 0.1, y0, cz + along - width / 2), max: V3(fx + 0.1, y1, cz + along + width / 2), color: color)
                } else {
                    let fz = sign > 0 ? z1 : z0
                    b.box(min: V3(cx + along - width / 2, y0, fz - 0.1), max: V3(cx + along + width / 2, y1, fz + 0.1), color: color)
                }
            }
            let glass = V3(0.35, 0.65, 0.9), wood = V3(0.5, 0.3, 0.16)
            let toPlaza = plazaCenter - V2(cx, cz)
            let doorOnX = abs(toPlaza.x) > abs(toPlaza.y)
            let doorSign: Float = (doorOnX ? toPlaza.x : toPlaza.y) > 0 ? 1 : -1
            attach(doorOnX, doorSign, 0, baseY, baseY + 2.7, 1.7, wood)
            for (onX, sign) in [(true, Float(1)), (true, Float(-1)), (false, Float(1)), (false, Float(-1))] {
                let span = onX ? s.d : s.w
                for along in [-span * 0.25, span * 0.25] {
                    attach(onX, sign, along, baseY + 3.2, baseY + 4.6, 1.2, glass)
                }
            }
            obstacles.append(Obstacle(center: V2(cx, cz), half: V2(s.w / 2, s.d / 2), round: false, topY: topY + 3.2))
        }

        // Bell tower on the plaza.
        let tc = plazaCenter + V2(7, -6)
        let tb = V3(tc.x, plazaHeight, tc.y)
        b.frustum(base: tb - V3(0, 1, 0), r0: 2.3, r1: 1.9, height: 13, sides: 20, color: V3(1, 0.95, 0.82))
        b.frustum(base: tb + V3(0, 10.5, 0), r0: 2.3, r1: 2.3, height: 1.4, sides: 20, color: V3(0.9, 0.5, 0.25))
        b.frustum(base: tb + V3(0, 12, 0), r0: 2.5, r1: 0.05, height: 5, sides: 20, color: V3(0.85, 0.25, 0.25))
        obstacles.append(Obstacle(center: tc, half: V2(2.3, 2.3), round: true, topY: plazaHeight + 17))

        // Stone kerb: gives the tile floor a deliberate edge instead of
        // letting the grass cut it off mid-checker.
        let ky0 = plazaHeight - 0.10, ky1 = plazaHeight + 0.22
        let ki = plazaRadius - 0.42, ko = plazaRadius + 0.06
        let kerbCol = V3(1.0, 0.95, 0.84)
        let segs = 72
        func kpt(_ r: Float, _ a: Float, _ y: Float) -> V3 {
            V3(plazaCenter.x + cos(a) * r, y, plazaCenter.y + sin(a) * r)
        }
        for i in 0..<segs {
            let a0 = Float(i) / Float(segs) * 2 * Float.pi
            let a1 = Float(i + 1) / Float(segs) * 2 * Float.pi
            let ti = kpt(ki, a1, ky0) - kpt(ki, a0, ky0)
            let to = kpt(ko, a1, ky0) - kpt(ko, a0, ky0)
            let up = V3(0, ky1 - ky0, 0)
            let radial = kpt(ko, a0, ky0) - kpt(ki, a0, ky0)
            b.quad(origin: kpt(ki, a0, ky1), u: ti, v: radial, color: kerbCol * 1.10)
            b.quad(origin: kpt(ko, a0, ky0), u: up, v: to, color: kerbCol)
            b.quad(origin: kpt(ki, a0, ky0), u: ti, v: up, color: kerbCol * 0.88)
        }

        return (b, obstacles)
    }
}
