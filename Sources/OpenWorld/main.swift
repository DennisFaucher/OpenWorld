import AppKit
import Metal

let args = CommandLine.arguments

enum Version {
    static let string = "1.0"
}

if args.contains("--version") {
    print("OpenWorld \(Version.string)")
    exit(0)
}

/// Reads `--name a b c` off the command line.
func argValues(_ name: String, _ count: Int) -> [Float]? {
    guard let j = args.firstIndex(of: name), j + count < args.count else { return nil }
    return (1...count).compactMap { Float(args[j + $0]) }
}

/// `--sim N [--walk] [--jump F D]` steps the simulation and prints the player
/// state each frame. Jump timing is the one part of movement feel that a
/// screenshot cannot show, so it is measured here instead.
if let i = args.firstIndex(of: "--sim"), i + 1 < args.count {
    let frames = Int(args[i + 1]) ?? 90
    let input = Input()
    let game = Game(obstacles: World.buildProps().obstacles)
    if let p = argValues("--pos", 2), p.count == 2 {
        game.pos = V3(p[0], World.height(p[0], p[1]), p[1])
    }
    if args.contains("--walk") { input.keys.insert(Key.w) }
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
    print("frame       y      vy  ground swim   fov")
    for f in 0..<frames {
        for s in jumpSpecs where s.at == f {
            input.jumpQueued = true
            input.keys.insert(Key.space)
        }
        for s in jumpSpecs where s.at + s.hold == f { input.keys.remove(Key.space) }
        game.update(dt: 1.0 / 60, input: input)
        print(String(format: "%5d %7.2f %7.2f %6d %4d %5.1f",
                     f, game.pos.y, game.vel.y, game.onGround ? 1 : 0, game.swimming ? 1 : 0,
                     game.fovBoost))
    }
    exit(0)
}

/// `--shot out.png [--pos x z] [--yaw a] [--pitch p] [--dist d] [--time t] [--hour h] [--size w h]`
/// renders one frame without opening a window, for quick visual checks.
if let i = args.firstIndex(of: "--shot"), i + 1 < args.count {
    let values = argValues
    guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device available") }
    let renderer = Renderer(device: device, hour: values("--hour", 1)?.first ?? 12)
    let game = renderer.game
    if let p = values("--pos", 2), p.count == 2 {
        game.pos = V3(p[0], World.height(p[0], p[1]), p[1])
    }
    if let v = values("--yaw", 1) { game.camYaw = v[0] }
    if let v = values("--pitch", 1) { game.camPitch = v[0] }
    if let v = values("--dist", 1) { game.camDist = v[0] }
    // `--walk` holds forward for the simulated frames so movement, wakes and
    // particles can be checked without a keyboard.
    if args.contains("--walk") { renderer.input.keys.insert(Key.w) }
    if args.contains("--walk-fast") {
        renderer.input.keys.insert(Key.w)
        renderer.input.keys.insert(Key.shift)
    }
    let frames = values("--frames", 1).map { Int($0[0]) } ?? 90
    for _ in 0..<frames { game.update(dt: 1.0 / 60, input: renderer.input) }
    if let v = values("--time", 1) { game.time = v[0] }
    let size = values("--size", 2) ?? [1920, 1080]
    renderer.renderPNG(path: args[i + 1], width: Int(size[0]), height: Int(size[1]))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
