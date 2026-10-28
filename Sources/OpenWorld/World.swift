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
    /// How far the sea floor and the shore-depth texture reach. It has to be
    /// wider than `boundsRadius`, or the player can swim off the drawn world.
    static let extent: Float = 420
    static let waterLevel: Float = 0
    static let seabed: Float = -4
    static let plazaCenter = V2(-18, 22)
    static let plazaRadius: Float = 13
    static let plazaHeight: Float = 3.2
    /// The bell tower is the shrine the crystals are offered to: its lamps count
    /// what has been delivered, and the last one lights the crown.
    static let towerCenter = plazaCenter + V2(7, -6)
    static let towerBaseY = plazaHeight
    static let towerTopY = plazaHeight + 12
    /// Tip of the spire: the cone above the shaft is five metres.
    static let towerSpireY = towerTopY + 5
    /// Ten lamps spiralling up the shaft, each worth a quarter of the field's
    /// fortieth part. A spiral rather than one column per face: from any side of
    /// the plaza four or five are in view, so the count always reads.
    static let towerLamps: [V3] = (0..<10).map { i in
        let a = 2.2 + Float(i) * 0.72
        let up = 2.6 + Float(i) * 0.85
        let r = 2.40 - (up + 1) * (0.4 / 13)     // the shaft tapers 2.3 -> 1.9
        return V3(towerCenter.x + cos(a) * r, towerBaseY + up, towerCenter.y + sin(a) * r)
    }
    /// Close enough that the offering happens without a key: walking to the
    /// shrine is the intent, so pressing something to confirm it is only a step.
    static let shrineRadius: Float = 4.6

    /// Players can't swim farther than this from the origin. Derived from the
    /// islands, never chosen: a hard-coded 320 was five metres inside the
    /// north-east island's beach, which walled off three of its crystals with
    /// nothing to see or hit — you bounced off the air trying to reach a gem.
    static let boundsRadius: Float =
        min(extent - 8, islands.map { length($0.centre) + $0.radius }.max()! + 40)

    static let islands: [Island] = [
        Island(centre: V2(0, 0), radius: 72, peak: 20, seed: 0, cell: 1, home: true),
        Island(centre: V2(-200, 130), radius: 46, peak: 10, seed: 31),
        Island(centre: V2(180, 214), radius: 54, peak: 15, seed: 57),
        Island(centre: V2(96, -204), radius: 38, peak: 7, seed: 83),
    ]

    /// A jetty from the sand out to the drop-off, with a boat moored at the end.
    struct Pier {
        /// Where the deck meets the sand.
        var root: V2
        /// Unit vector from the beach out to sea.
        var sea: V2
        var length: Float
    }

    static let pierDeckY: Float = 0.62
    static let pierHalfWidth: Float = 1.15
    static let piers: [Pier] = islands.map { pierSpot($0) }

    /// Boats moor alongside the end of the pier rather than dead astern of it,
    /// where the deck would hide them from anyone standing on the shore.
    static let boatMoorings: [(pos: V2, heading: Float)] = piers.map { p in
        let side = V2(-p.sea.y, p.sea.x)
        return (p.root + p.sea * (p.length + 1.0) + side * 3.2, atan2(p.sea.x, p.sea.y))
    }

    /// Picks a pier site by walking out from the island centre: the deck starts
    /// at the waterline and runs until the sea is deep enough to float a boat,
    /// so no hand-placed coordinates and nothing to move when an island moves.
    private static func pierSpot(_ island: Island) -> Pier {
        let angle: Float = island.home ? 2.52 : 0.4 + island.seed * 0.7
        let dir = V2(cos(angle), sin(angle))
        var shore = island.centre + dir * (island.radius * 0.6)
        var r = island.radius * 0.4
        while r < island.radius * 1.9 {
            let p = island.centre + dir * r
            if height(p.x, p.y) < 0.35 { shore = p; break }
            r += 0.5
        }
        var length: Float = 8
        var l: Float = 2
        while l < 34 {
            let p = shore + dir * l
            if height(p.x, p.y) < -2.4 { length = l + 1.5; break }
            l += 0.5
            length = l
        }
        return Pier(root: shore, sea: dir, length: max(length, 6))
    }

    /// Height of a pier deck at a point, or far below the sea floor elsewhere.
    /// The deck is not in the terrain mesh — it is a prop — so the player's
    /// vertical snap asks about it separately.
    static func pierHeight(_ x: Float, _ z: Float) -> Float {
        for p in piers {
            let d = V2(x, z) - p.root
            let along = dot(d, p.sea)
            let across = dot(d, V2(-p.sea.y, p.sea.x))
            if along >= -0.5 && along <= p.length && abs(across) <= pierHalfWidth {
                return pierDeckY
            }
        }
        return -100
    }

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
    /// One chunk carries three index ranges over the same vertices: full 1 m,
    /// every other vertex (2 m) and every fourth (4 m). The coarse ranges
    /// sample a subset of the fine ones, so all three draw the same heights and
    /// the only thing that changes is how many of them get used.
    struct TerrainChunk {
        var firstIndex: Int
        var indexCount: Int
        var coarseFirst: Int
        var coarseCount: Int
        var farFirst: Int
        var farCount: Int
        var lo: V3
        var hi: V3
    }

    /// An island's whole patch. Every chunk in it is drawn at the same level,
    /// because a chunk whose neighbour is at a different level shares an edge
    /// at a different resolution: the coarse side is a straight line where the
    /// fine side has a vertex, and the gap shows as a bright sliver. Level-of-
    /// detail at patch granularity cannot crack, since a patch's only neighbour
    /// is the flat sea floor at exactly `seabed`.
    struct TerrainPatch {
        var lo: V3
        var hi: V3
        var chunks: [TerrainChunk]
    }

    /// Chunks are cut on a fixed grid so a chunk's indices stay contiguous and
    /// a whole chunk can be skipped with one draw-range check.
    static let chunkSize: Float = 16

    static func buildTerrain() -> (mesh: MeshBuilder, patches: [TerrainPatch]) {
        let b = MeshBuilder()
        var patches: [TerrainPatch] = []
        for island in islands {
            patches.append(addPatch(island.centre, radius: island.radius, cell: island.cell, to: b))
        }
        return (b, patches)
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
                                 to b: MeshBuilder) -> TerrainPatch {
        let half = (ceil((radius + 26) / chunkSize)) * chunkSize
        let cells = Int(half * 2 / cell)
        let stride = cells + 1
        let base = b.vertices.count
        let x0 = centre.x - half, z0 = centre.y - half
        var patchLoY = Float.greatestFiniteMagnitude
        var patchHiY = -Float.greatestFiniteMagnitude
        for j in 0...cells {
            let z = z0 + Float(j) * cell
            for i in 0...cells {
                let x = x0 + Float(i) * cell
                let h = height(x, z)
                patchLoY = min(patchLoY, h)
                patchHiY = max(patchHiY, h)
                // Alpha 0.5 flags terrain for the fragment shader's detail.
                b.add(V3(x, h, z), normal(x, z), ground(x, z, h, normal(x, z)), alpha: 0.5)
            }
        }
        let per = max(1, Int(chunkSize / cell))
        var chunks: [TerrainChunk] = []

        /// Appends one chunk's index range sampled every `step` cells.
        func emit(_ step: Int, _ ci: Int, _ cj: Int) -> (Int, Int) {
            let first = b.indices.count
            let n = per / step
            if n < 1 { return (first, 0) }
            for j in 0..<n {
                for i in 0..<n {
                    let a = UInt32(base + (cj * per + j * step) * stride + (ci * per + i * step))
                    let bb = a + UInt32(step)
                    let c = a + UInt32(stride * step)
                    let d = c + UInt32(step)
                    b.tri(a, c, bb)
                    b.tri(bb, c, d)
                }
            }
            return (first, b.indices.count - first)
        }

        for cj in 0..<(cells / per) {
            for ci in 0..<(cells / per) {
                let fine = emit(1, ci, cj)
                let coarse = emit(2, ci, cj)
                let far = emit(4, ci, cj)
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
                chunks.append(TerrainChunk(firstIndex: fine.0, indexCount: fine.1,
                                           coarseFirst: coarse.0, coarseCount: coarse.1,
                                           farFirst: far.0, farCount: far.1,
                                           lo: V3(cx, loY, cz),
                                           hi: V3(cx + chunkSize, hiY, cz + chunkSize)))
            }
        }
        return TerrainPatch(lo: V3(x0, patchLoY, z0),
                            hi: V3(x0 + half * 2, patchHiY, z0 + half * 2),
                            chunks: chunks)
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

    /// Props are drawn instanced: one small base mesh per kind, plus a list of
    /// transforms. Palm, bush and flower counts would otherwise be ~950 copies
    /// of the same geometry baked into one static mesh, drawn in full in both
    /// passes from anywhere in the world.
    enum PropKind {
        case palm(Int)
        case bush
        case flower
    }

    struct PropInstance {
        var model: M4
        var tint: V3
    }

    /// One instanced draw: a base mesh kind, its transforms, and a box for
    /// culling. Batches are grouped per island so an off-screen island costs
    /// nothing.
    struct PropBatch {
        var kind: PropKind
        var instances: [PropInstance]
        var lo: V3
        var hi: V3
    }

    static func buildProps() -> (mesh: MeshBuilder, batches: [PropBatch], obstacles: [Obstacle]) {
        let b = MeshBuilder()
        var obstacles: [Obstacle] = []
        var batches: [PropBatch] = []
        var rng = RNG(seed: 42)

        /// Wraps instances in batches: one per 40 m block, so a batch is small
        /// enough that the frustum test actually throws most of them away.
        /// Keys are world blocks, not island blocks, so a sparse island does not
        /// pay for the water around it.
        func batchList(_ kind: PropKind, _ insts: [PropInstance], reach: Float) -> [PropBatch] {
            let block: Float = 40
            var buckets: [Int: [PropInstance]] = [:]
            for inst in insts {
                let x = inst.model.columns.3.x, z = inst.model.columns.3.z
                let key = Int((x / block).rounded(.down)) &* 4096
                    &+ (Int((z / block).rounded(.down)) &+ 2048)
                buckets[key, default: []].append(inst)
            }
            return buckets.keys.sorted().map { key in
                let group = buckets[key]!
                var lo = V3(repeating: .greatestFiniteMagnitude)
                var hi = V3(repeating: -.greatestFiniteMagnitude)
                for inst in group {
                    let p = V3(inst.model.columns.3.x, inst.model.columns.3.y, inst.model.columns.3.z)
                    lo = V3(min(lo.x, p.x - reach), min(lo.y, p.y - reach), min(lo.z, p.z - reach))
                    hi = V3(max(hi.x, p.x + reach), max(hi.y, p.y + reach), max(hi.z, p.z + reach))
                }
                return PropBatch(kind: kind, instances: group, lo: lo, hi: hi)
            }
        }

        func nearPlaza(_ x: Float, _ z: Float, _ margin: Float) -> Bool {
            length(V2(x, z) - plazaCenter) < plazaRadius + margin
        }

        // Palms along the beaches and low ground, on every island. Counts scale
        // with the island's size so a small cay is not a forest.
        let petals: [V3] = [V3(1, 0.85, 0.15), V3(1, 0.45, 0.7), V3(1, 1, 1), V3(0.95, 0.25, 0.2)]
        for island in islands {
            let reach = island.radius * 1.02
            var palms: [V2] = []
            var palmInst: [[PropInstance]] = [[], [], []]
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
                let wid = rng.range(0.88, 1.12)
                let variant = Int(rng.next() * 3) % 3
                let model = M4.translation(V3(x, h - 0.2, z))
                    * M4.rotationY(rng.range(0, 6.28))
                    * M4.scale(V3(wid, ht / 7, wid))
                palmInst[variant].append(PropInstance(model: model, tint: V3(1, 1, 1)))
                obstacles.append(Obstacle(center: p, half: V2(0.4, 0.4), round: true, topY: h + ht))
            }
            for (v, insts) in palmInst.enumerated() {
                batches.append(contentsOf: batchList(.palm(v), insts, reach: 9.5))
            }

            var bushes = 0
            var bushInst: [PropInstance] = []
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
                let model = M4.translation(V3(x, h + r * 0.3, z)) * M4.scale(V3(r, r * 0.8, r))
                bushInst.append(PropInstance(model: model, tint: g))
                bushes += 1
            }
            batches.append(contentsOf: batchList(.bush, bushInst, reach: 2))

            var flowers = 0
            var flowerInst: [PropInstance] = []
            tries = 0
            let wantFlowers = island.home ? 400 : Int(island.radius * 1.6)
            while flowers < wantFlowers && tries < 8000 {
                tries += 1
                let x = island.centre.x + rng.range(-reach, reach)
                let z = island.centre.y + rng.range(-reach, reach)
                let h = height(x, z)
                if h < 2.3 || normal(x, z).y < 0.9 || nearPlaza(x, z, 3) { continue }
                let col = petals[Int(rng.next() * 4) % 4]
                let model = M4.translation(V3(x, h + 0.12, z)) * M4.scale(V3(0.14, 0.1, 0.14))
                flowerInst.append(PropInstance(model: model, tint: col))
                flowers += 1
            }
            batches.append(contentsOf: batchList(.flower, flowerInst, reach: 0.4))
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
        let tc = towerCenter
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

        // Piers, one per island: plank deck on posts, running from the sand out
        // past the drop-off. Laid out along the pier's own axes, so the boxes
        // that would otherwise be axis-aligned are built as quads.
        for pier in piers {
            let side = V2(-pier.sea.y, pier.sea.x)
            func w(_ along: Float, _ across: Float, _ y: Float) -> V3 {
                let p = pier.root + pier.sea * along + side * across
                return V3(p.x, y, p.y)
            }
            let planks = max(3, Int(pier.length / 0.72))
            for i in 0..<planks {
                let a = Float(i) / Float(planks) * pier.length
                let e = Float(i + 1) / Float(planks) * pier.length
                let tone: Float = i % 2 == 0 ? 1.0 : 0.91
                let col = V3(0.74, 0.55, 0.32) * tone
                b.quad(origin: w(a, -pierHalfWidth, pierDeckY),
                       u: w(e, -pierHalfWidth, pierDeckY) - w(a, -pierHalfWidth, pierDeckY),
                       v: w(a, pierHalfWidth, pierDeckY) - w(a, -pierHalfWidth, pierDeckY),
                       color: col)
                // The open sides of the deck: without them the planks read as a
                // floating ribbon from the water.
                b.quad(origin: w(a, -pierHalfWidth, pierDeckY - 0.12),
                       u: w(e, -pierHalfWidth, pierDeckY - 0.12) - w(a, -pierHalfWidth, pierDeckY - 0.12),
                       v: V3(0, 0.12, 0), color: col * 0.8)
                b.quad(origin: w(a, pierHalfWidth, pierDeckY - 0.12),
                       u: w(e, pierHalfWidth, pierDeckY - 0.12) - w(a, pierHalfWidth, pierDeckY - 0.12),
                       v: V3(0, 0.12, 0), color: col * 0.8)
            }
            // Posts down to the sea floor, and a pair of mooring posts at the end.
            let postCount = max(2, Int(pier.length / 3.2))
            for i in 0...postCount {
                let along = Float(i) / Float(postCount) * pier.length
                for across: Float in [-pierHalfWidth + 0.12, pierHalfWidth - 0.12] {
                    let p = pier.root + pier.sea * along + side * across
                    let bed = height(p.x, p.y) - 0.3
                    b.box(min: V3(p.x - 0.11, bed, p.y - 0.11),
                          max: V3(p.x + 0.11, pierDeckY, p.y + 0.11),
                          color: V3(0.5, 0.38, 0.24))
                }
            }
            for across: Float in [-pierHalfWidth, pierHalfWidth] {
                let p = pier.root + pier.sea * pier.length + side * across
                b.box(min: V3(p.x - 0.13, pierDeckY - 0.1, p.y - 0.13),
                      max: V3(p.x + 0.13, pierDeckY + 0.55, p.y + 0.13),
                      color: V3(0.46, 0.34, 0.2))
            }
        }

        return (b, batches, obstacles)
    }
}
