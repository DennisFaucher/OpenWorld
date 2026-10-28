import Foundation

/// What survives the process: the crystals already found, and the activity
/// totals the readout quotes. `layout` is a hash of the shard field, so a build
/// that moves the crystals discards the old file rather than marking the wrong
/// ones as taken — the field is generated, not authored, so it can change.
struct SaveState: Codable {
    static let currentVersion = 1

    var version = SaveState.currentVersion
    var layout: Int
    var found: [Int]
    var steps: Int
    var metres: Float
}

/// Progress on disk. Off by default: a headless render or a `--sim` walk must
/// not pick up a crystal or overwrite the player's session, so `enabled` is
/// only turned on by the live app and by an explicit `--save PATH`.
enum Save {
    static var enabled = false

    static var url: URL = defaultURL

    static var defaultURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("OpenWorld/save.json")
    }

    /// Everything a save file needs, taken from a live game.
    static func state(of game: Game) -> SaveState {
        SaveState(layout: layoutHash(game.shards), found: game.found.sorted(),
                  steps: game.steps, metres: game.distance)
    }

    /// Cheap fingerprint of the field: the count plus every position rounded to
    /// a decimetre. Any change to the placement changes it.
    static func layoutHash(_ shards: [Shard]) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for s in shards {
            for v in [s.pos.x, s.pos.y, s.pos.z] {
                h = (h ^ UInt64(bitPattern: Int64((v * 10).rounded()))) &* 0x100_0000_01b3
            }
        }
        return Int(truncatingIfNeeded: h) & 0x7fff_ffff
    }

    static func load() -> SaveState? {
        guard enabled, let data = try? Data(contentsOf: url) else { return nil }
        guard let state = try? JSONDecoder().decode(SaveState.self, from: data),
              state.version == SaveState.currentVersion else { return nil }
        return state
    }

    /// Best effort: a build running from a read-only place should lose its
    /// progress, not crash.
    static func write(_ state: SaveState) {
        guard enabled else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? enc.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
