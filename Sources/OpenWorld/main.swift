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

/// `--shot out.png [--pos x z] [--yaw a] [--pitch p] [--dist d] [--time t] [--hour h] [--size w h]`
/// renders one frame without opening a window, for quick visual checks.
if let i = args.firstIndex(of: "--shot"), i + 1 < args.count {
    func values(_ name: String, _ count: Int) -> [Float]? {
        guard let j = args.firstIndex(of: name), j + count < args.count else { return nil }
        return (1...count).compactMap { Float(args[j + $0]) }
    }
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
