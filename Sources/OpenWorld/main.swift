import AppKit
import Metal
import simd

let args = CommandLine.arguments

enum Version {
    static let string = "4.0"
}

if args.contains("--version") {
    print("OpenWorld \(Version.string)")
    exit(0)
}

/// Progress on disk. Headless runs are hermetic by default — a screenshot must
/// not collect a crystal or rewrite the session — so saving is opt-in here, by
/// `--save PATH`, which is also how a test writes to a scratch file instead of
/// the player's real one.
if let i = args.firstIndex(of: "--save"), i + 1 < args.count {
    Save.enabled = true
    Save.url = URL(fileURLWithPath: args[i + 1])
}
if args.contains("--reset-save") { Save.clear() }

/// Reads `--name a b c` off the command line.
func argValues(_ name: String, _ count: Int) -> [Float]? {
    guard let j = args.firstIndex(of: name), j + count < args.count else { return nil }
    return (1...count).compactMap { Float(args[j + $0]) }
}

if args.contains("--dump-shaders") {
    try! Shaders.source.write(toFile: "/Users/faucherd/Downloads/tmp/shaders.metal", atomically: true, encoding: .utf8)
    exit(0)
}

/// `--slope-scan` histograms the terrain gradient, which is how the walk limit
/// was picked: the island tops out around 65 deg, so 45 deg keeps the mountain
/// climbable while leaving the rocky outcrops as slides.
if args.contains("--slope-scan") {
    var hist = [Int](repeating: 0, count: 14)
    var worst: Float = 0
    var worstAt = V2.zero
    var steep = 0
    var cells = 0
    for z in stride(from: -110, through: 110, by: 1) {
        for x in stride(from: -110, through: 110, by: 1) {
            let deg = acos(clampf(World.normal(Float(x), Float(z)).y, -1, 1)) * 180 / Float.pi
            if deg > worst { worst = deg; worstAt = V2(Float(x), Float(z)) }
            if deg > 45 { steep += 1 }
            hist[min(13, Int(deg / 5))] += 1
            cells += 1
        }
    }
    for (i, n) in hist.enumerated() where n > 0 {
        print(String(format: "%3d-%3d deg: %6d", i * 5, i * 5 + 5, n))
    }
    print(String(format: "%6d m2 steeper than 45 deg (%.1f%% of the island)",
                 steep, Float(steep) / Float(cells) * 100))
    print(String(format: "steepest %.1f deg at (%.0f, %.0f)", worst, worstAt.x, worstAt.y))
    exit(0)
}

/// `--shard-scan` prints the generated crystal field, which is how a test
/// position is picked without running around the archipelago.
if args.contains("--shard-scan") {
    let field = Shards.field(obstacles: World.buildProps().obstacles)
    print("shards: \(field.count)  layout \(Save.layoutHash(field))")
    for (i, s) in field.enumerated() {
        let deg = acos(clampf(World.normal(s.pos.x, s.pos.z).y, -1, 1)) * 180 / Float.pi
        print(String(format: "%3d  x %7.2f  z %7.2f  y %5.2f  slope %4.1f", i, s.pos.x, s.pos.z, s.pos.y, deg))
    }
    exit(0)
}

/// `--sim N [--walk] [--jump F D]` steps the simulation and prints the player
/// state each frame. Jump timing is the one part of movement feel that a
/// screenshot cannot show, so it is measured here instead.
if let i = args.firstIndex(of: "--sim"), i + 1 < args.count {
    let frames = Int(args[i + 1]) ?? 90
    let input = Input()
    let game = Game(obstacles: World.buildProps().obstacles,
                    save: Save.enabled ? Save.load() : nil)
    if Save.enabled { game.onShard = { [unowned game] _ in Save.write(Save.state(of: game)) } }
    if let p = argValues("--pos", 2), p.count == 2 {
        game.pos = V3(p[0], max(World.height(p[0], p[1]), World.pierHeight(p[0], p[1])), p[1])
    }
    if let v = argValues("--yaw", 1) { game.camYaw = v[0] }
    if let v = argValues("--pitch", 1) { game.camPitch = v[0] }
    if let v = argValues("--dist", 1) { game.camDist = v[0] }
    if args.contains("--walk") { input.keys.insert(Key.w) }
    if args.contains("--spray") { input.spray = true }
    // `--ride` starts aboard the home island's boat, so steering and the
    // hull's reaction to shallow water can be measured without a keyboard.
    if args.contains("--ride") { game.boardBoat(0) }
    // `--board` holds the boarding key instead, so the proximity test and the
    // on/off toggle are exercised the way a player would.
    if args.contains("--board") { input.keys.insert(Key.e) }
    // `--turn` holds the right-hand steer, so the rudder and the hull's heel
    // can be checked on the same run as the throttle.
    if args.contains("--turn") { input.keys.insert(Key.d) }
    if args.contains("--walk-fast") {
        input.keys.insert(Key.w)
        input.keys.insert(Key.shift)
    }
    var jumpSpecs: [(at: Int, hold: Int)] = []
    var a = 0
    while a < args.count {
        if args[a] == "--jump", a + 2 < args.count,
           let f = Int(args[a + 1]), let d = Int(args[a + 2]) {
            jumpSpecs.append((f, d))
            a += 3
        } else {
            a += 1
        }
    }
    print("frame       x       y       z      vy  ground swim   fov  slope |   hipL   hipR  kneeL  spd")
    var picked = game.found.count
    for f in 0..<frames {
        for s in jumpSpecs where s.at == f {
            input.jumpQueued = true
            input.keys.insert(Key.space)
        }
        for s in jumpSpecs where s.at + s.hold == f { input.keys.remove(Key.space) }
        game.update(dt: 1.0 / 60, input: input)
        let ny = World.normal(game.pos.x, game.pos.z).y
        print(String(format: "%5d %7.2f %7.2f %7.2f %7.2f %6d %4d %5.1f %6.1f | %6.1f %6.1f %6.1f %6.2f",
                     f, game.pos.x, game.pos.y, game.pos.z, game.vel.y,
                     game.onGround ? 1 : 0, game.swimming ? 1 : 0, game.fovBoost,
                     acos(clampf(ny, -1, 1)) * 180 / Float.pi,
                     game.pose.hipL * 180 / Float.pi, game.pose.hipR * 180 / Float.pi,
                     game.pose.kneeL * 180 / Float.pi, game.speedNorm))
        if game.found.count != picked {
            picked = game.found.count
            print("      ** shard taken: \(picked)/\(game.shards.count)")
        }
    }
    print("shards \(game.found.count)/\(game.shards.count), steps \(game.steps)")
    exit(0)
}

/// `--shot out.png [--pos x z] [--yaw a] [--pitch p] [--dist d] [--time t] [--hour h] [--size w h] [--look r] [--look-pitch r]`
/// renders one frame without opening a window, for quick visual checks.
if let i = args.firstIndex(of: "--shot"), i + 1 < args.count {
    let values = argValues
    guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device available") }
    let renderer = Renderer(device: device, hour: values("--hour", 1)?.first ?? 12,
                            save: Save.enabled ? Save.load() : nil)
    let game = renderer.game
    if let p = values("--pos", 2), p.count == 2 {
        game.pos = V3(p[0], max(World.height(p[0], p[1]), World.pierHeight(p[0], p[1])), p[1])
    }
    if let v = values("--yaw", 1) { game.camYaw = v[0] }
    if let v = values("--pitch", 1) { game.camPitch = v[0] }
    if let v = values("--dist", 1) { game.camDist = v[0] }
    // `--walk` holds forward for the simulated frames so movement, wakes and
    // particles can be checked without a keyboard.
    if args.contains("--walk") { renderer.input.keys.insert(Key.w) }
    if args.contains("--ride") { game.boardBoat(0) }
    if args.contains("--board") { renderer.input.keys.insert(Key.e) }
    // `--spray` holds the trigger so the jet and its impact can be rendered;
    // `--spray-frames N` lets go after N frames, so the wet patches can be
    // checked as they dry.
    if args.contains("--spray") { renderer.input.spray = true }
    let sprayFrames = values("--spray-frames", 1).map { Int($0[0]) } ?? -1
    if sprayFrames >= 0 { renderer.input.spray = sprayFrames > 0 }
    if args.contains("--walk-fast") {
        renderer.input.keys.insert(Key.w)
        renderer.input.keys.insert(Key.shift)
    }
    let frames = values("--frames", 1).map { Int($0[0]) } ?? 90
    // `--jump F D` works here too, so an airborne frame can be rendered.
    var jumpSpecs: [(at: Int, hold: Int)] = []
    var a = args.firstIndex(of: "--jump") ?? args.count
    while a + 2 < args.count + 0, args[a] == "--jump",
          let f = Int(args[a + 1]), let d = Int(args[a + 2]) {
        jumpSpecs.append((f, d))
        a += 3
    }
    for f in 0..<frames {
        for s in jumpSpecs where s.at == f {
            renderer.input.jumpQueued = true
            renderer.input.keys.insert(Key.space)
        }
        for s in jumpSpecs where s.at + s.hold == f { renderer.input.keys.remove(Key.space) }
        if sprayFrames >= 0 { renderer.input.spray = f < sprayFrames }
        game.update(dt: 1.0 / 60, input: renderer.input)
    }
    if let v = values("--time", 1) { game.time = v[0] }
    // `--look RAD` re-orbits the finished frame without re-simulating, so a run
    // cycle can be checked from the side instead of from behind: turning the
    // camera before the frames also turns the player, which is the point of the
    // camera-relative controls.
    if let v = values("--look", 1) {
        let d = length(game.camPos - game.camTarget)
        let y = game.camYaw + v[0]
        let p = game.camPitch + (values("--look-pitch", 1)?.first ?? 0)
        game.camPos = game.camTarget
            + V3(sin(y) * cos(p), sin(p), cos(y) * cos(p)) * d
    }
    let size = values("--size", 2) ?? [1920, 1080]
    renderer.renderPNG(path: args[i + 1], width: Int(size[0]), height: Int(size[1]))
    // `--collect` takes every crystal in reach, so a frame can be rendered after
    // a pickup without steering the player onto one.
    if args.contains("--shards") {
        print("shards: \(game.found.count)/\(game.shards.count)")
    }
    if args.contains("--stats") {
        let chunks = renderer.statsChunks, tris = renderer.statsTriangles
        let levels = renderer.statsLevels
        print("terrain: \(chunks)/\(renderer.terrainChunkTotal) chunks "
              + "(\(levels.0) full, \(levels.1) half, \(levels.2) quarter), "
              + "\(tris)/\(renderer.terrainTriangleTotal) triangles")
        print("props: \(renderer.statsPropBatches)/\(renderer.propBatchTotal) batches, "
              + "\(renderer.statsPropInstances)/\(renderer.propInstanceTotal) instances")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
