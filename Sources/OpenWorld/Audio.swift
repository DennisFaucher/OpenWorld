import AVFoundation

/// The island's sound. Every buffer is synthesised once at launch (`Sound`) and
/// played back by player nodes, so the audio thread never runs Swift: pre-rendering
/// costs a few million multiply-adds at startup and buys a mix that cannot glitch.
///
/// Nothing in `Game` knows this exists. Events are inferred by comparing frames —
/// the step counter advancing is a footfall, `found` growing is a pickup — which
/// keeps the gameplay code free of callbacks and means audio can be dropped, or
/// fail to start, without changing how the game runs.
final class Audio {
    private let engine = AVAudioEngine()
    private let bus = AVAudioMixerNode()
    private let muffle = AVAudioUnitEQ(numberOfBands: 1)
    private let motorPitch = AVAudioUnitVarispeed()

    private let surfPlayer = AVAudioPlayerNode()
    private let windPlayer = AVAudioPlayerNode()
    private let jetPlayer = AVAudioPlayerNode()
    private let motorPlayer = AVAudioPlayerNode()
    private let splashPlayer = AVAudioPlayerNode()
    private let chimePlayers: [AVAudioPlayerNode]
    private let thudPlayer = AVAudioPlayerNode()
    private let stepPlayers: [AVAudioPlayerNode]
    private let birdPlayers: [AVAudioPlayerNode]
    private let strokePlayers: [AVAudioPlayerNode]

    private let splashBuffer: AVAudioPCMBuffer
    private let chimeBuffers: [AVAudioPCMBuffer]
    private let thudBuffer: AVAudioPCMBuffer
    private let stepBuffers: [AVAudioPCMBuffer]
    private let birdBuffers: [AVAudioPCMBuffer]
    private let strokeBuffers: [AVAudioPCMBuffer]

    /// Smoothed levels: a target that steps would be a click every time the
    /// player crossed the waterline.
    private var surfLevel: Float = 0
    private var windLevel: Float = 0
    private var jetLevel: Float = 0
    private var motorLevel: Float = 0
    private var muffleAmount: Float = 0
    private var wetness: Float = 0

    private var lastSteps = 0
    private var lastStride = 0
    private var lastFound = 0
    private var lastBanked = 0
    private var chimeCursor = 0
    private var wasSwimming = false
    private var wasGrounded = true
    private var lastFallSpeed: Float = 0
    private var nextBird: Float = 5
    private var stepCursor = 0
    private var birdCursor = 0
    private var strokeCursor = 0
    private var primed = false
    /// Counted for `--audio-test`: a one-shot that never fires would otherwise be
    /// invisible.
    private(set) var strokesPlayed = 0

    private var captureURL: URL?
    private var captureSamples: [[Float]] = [[], []]
    private let captureLock = NSLock()
    private var capturePeak: Float = 0
    private var captureSum: Double = 0
    private var captureCount: Double = 0
    private var captureHigh: Double = 0

    private(set) var isRunning = false

    static let masterVolume: Float = 0.85

    var muted = false {
        didSet {
            guard isRunning else { return }
            engine.mainMixerNode.outputVolume = muted ? 0 : Audio.masterVolume
        }
    }

    /// Test hook: pins the underwater amount so the low-pass can be measured on a
    /// fixed scene. `--audio-test` is the only caller.
    var muffleOverride: Float?

    /// The smoothed levels, for the headless test: a graph connection that is
    /// broken silences one source and nothing else notices.
    var levels: (surf: Float, wind: Float, jet: Float, motor: Float) {
        (surfLevel, windLevel, jetLevel, motorLevel)
    }

    /// What the mix is doing, for the same test.
    var debugLine: String {
        String(format: "surf %.2f wind %.2f jet %.2f motor %.2f  band %.0f Hz%@",
               surfLevel, windLevel, jetLevel, motorLevel,
               muffle.bands[0].frequency, muffle.bands[0].bypass ? " bypassed" : "")
    }

    init?() {
        stepBuffers = (0..<3).map { Sound.step(variant: $0) }
        birdBuffers = (0..<2).map { Sound.bird(variant: $0) }
        strokeBuffers = (0..<2).map { Sound.stroke(variant: $0) }
        splashBuffer = Sound.splash()
        chimeBuffers = [0, 5, 12].map { Sound.chime(transpose: $0) }
        thudBuffer = Sound.thud()
        chimePlayers = (0..<3).map { _ in AVAudioPlayerNode() }
        stepPlayers = (0..<3).map { _ in AVAudioPlayerNode() }
        birdPlayers = (0..<2).map { _ in AVAudioPlayerNode() }
        strokePlayers = (0..<2).map { _ in AVAudioPlayerNode() }

        let fmt = Sound.format
        engine.attach(bus)
        let throughBus: [AVAudioNode] = [surfPlayer, windPlayer, jetPlayer,
                                         splashPlayer, thudPlayer]
            + chimePlayers + stepPlayers + birdPlayers + strokePlayers
        for node in throughBus + [motorPlayer, motorPitch, muffle] {
            engine.attach(node)
        }
        for node in throughBus { engine.connect(node, to: bus, format: fmt) }
        // The outboard runs through a varispeed unit: one buffer covers idle and
        // flat out, and the pitch follows the hull instead of the mix being four
        // separate engine loops.
        engine.connect(motorPlayer, to: motorPitch, format: fmt)
        engine.connect(motorPitch, to: bus, format: fmt)

        // One low-pass across the whole mix is the underwater state, the same
        // way the shader does it: everything decays into one dull colour, so
        // everything decays into one dull sound. It sits between the bus and the
        // engine's own mixer, whose connection to the output the engine owns.
        let band = muffle.bands[0]
        band.filterType = .lowPass
        band.frequency = 19000
        band.bypass = true
        engine.connect(bus, to: muffle, format: fmt)
        engine.connect(muffle, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = Audio.masterVolume

        engine.prepare()
        do { try engine.start() } catch {
            print("audio: engine failed to start: \(error.localizedDescription)")
            return nil
        }

        surfPlayer.scheduleBuffer(Sound.surf(), at: nil, options: .loops)
        windPlayer.scheduleBuffer(Sound.wind(), at: nil, options: .loops)
        jetPlayer.scheduleBuffer(Sound.jet(), at: nil, options: .loops)
        motorPlayer.scheduleBuffer(Sound.motor(), at: nil, options: .loops)
        for p in [surfPlayer, windPlayer, jetPlayer, motorPlayer] {
            p.volume = 0
            p.play()
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
    }

    // MARK: - per frame

    func update(_ g: Game, dt: Float) {
        guard isRunning, dt > 0 else { return }

        if !primed {
            // The first frame is a snapshot, not a burst of events: launching
            // into a saved game must not chime for every crystal already found.
            lastSteps = g.steps
            lastStride = Int(g.walkPhase / Float.pi)
            lastFound = g.found.count
            lastBanked = g.banked
            wasSwimming = g.swimming
            wasGrounded = g.onGround
            lastFallSpeed = g.vel.y
            primed = true
        }

        // Footfalls. `steps` only advances on foot, so a boat ride is silent
        // without anyone having to say so.
        if g.steps > lastSteps {
            for _ in 0..<min(3, g.steps - lastSteps) {
                let p = stepPlayers[stepCursor % stepPlayers.count]
                if g.swimming {
                    play(p, splashBuffer, volume: Float.random(in: 0.22...0.3))
                } else {
                    play(p, stepBuffers[stepCursor % stepBuffers.count],
                         volume: Float.random(in: 0.45...0.62))
                }
                stepCursor += 1
            }
            lastSteps = g.steps
        }

        // Deep water is the one place the step counter stops, so a stroke comes
        // off the walk phase itself — the same phase the legs kick on.
        let stride = Int(g.walkPhase / Float.pi)
        if g.swimming && stride != lastStride && g.speedNorm > 0.06 {
            play(strokePlayers[strokeCursor % strokePlayers.count],
                 strokeBuffers[strokeCursor % strokeBuffers.count],
                 volume: 0.38 + 0.22 * min(1, g.speedNorm))
            strokeCursor += 1
            strokesPlayed += 1
        }
        lastStride = stride

        if g.found.count > lastFound {
            play(chimePlayers[chimeCursor % chimePlayers.count],
                 chimeBuffers[0], volume: 0.65)
            chimeCursor += 1
            lastFound = g.found.count
        }

        // Offering at the shrine. A bell per lamp lit, climbing a fifth and then
        // an octave as the count goes up, and a chord when the last one lands —
        // otherwise forty crystals arriving is a long run of the same note.
        if g.banked != lastBanked {
            if g.banked / 4 != lastBanked / 4 {
                let k = max(0, g.banked / 4 - 1) % 3
                play(chimePlayers[chimeCursor % chimePlayers.count],
                     chimeBuffers[k], volume: 0.45)
                chimeCursor += 1
            }
            if g.shrineLit && lastBanked < g.shards.count {
                play(chimePlayers[0], chimeBuffers[2], volume: 0.6)
                play(chimePlayers[1], chimeBuffers[0], volume: 0.5)
                play(thudPlayer, thudBuffer, volume: 0.5)
            }
            lastBanked = g.banked
        }

        if g.swimming && !wasSwimming {
            play(splashPlayer, splashBuffer, volume: 0.7)
        }

        // Landing is weighted by the speed the frame before contact, so a hop
        // onto a plank and a drop off the mountain are the same sound at two
        // volumes.
        if g.onGround && !wasGrounded, lastFallSpeed < -3 {
            play(thudPlayer, thudBuffer, volume: 0.3 + 0.45 * clampf(-lastFallSpeed / 20, 0, 1))
        }

        // The jet hisses while the stream is live and dies with the tank. Aiming
        // at the sky still makes noise: `spraying` is already the gate, and the
        // stream itself does not care whether it hit anything.
        jetLevel = ease(jetLevel, g.spraying ? 0.45 : 0, 14, dt)
        jetPlayer.volume = jetLevel

        // The outboard.
        if let i = g.riding, g.boats.indices.contains(i) {
            let s = abs(g.boats[i].speed)
            motorLevel = ease(motorLevel, 0.28 + 0.22 * min(1, s / 12), 3, dt)
            motorPitch.rate = 0.8 + 0.7 * min(1, s / 12)
        } else {
            motorLevel = ease(motorLevel, 0, 4, dt)
        }
        motorPlayer.volume = motorLevel

        // The sea is loudest from the shore and the wind from the ridge, so the
        // bed tracks the terrain the player is standing on.
        let ground = World.height(g.pos.x, g.pos.z)
        // The bed sits *under* the foley, not over it: at the first pass the
        // surf masked the footsteps and the wading splashes completely, because a
        // continuous noise bed only has to be half as loud as a transient to bury
        // it.
        surfLevel = ease(surfLevel, 0.10 + 0.32 * (1 - sstep(1.5, 26, ground)), 1.6, dt)
        windLevel = ease(windLevel, 0.04 + 0.18 * sstep(2, 26, ground), 1.0, dt)
        surfPlayer.volume = surfLevel
        windPlayer.volume = windLevel

        // Birds, on land only, and not on a metronome.
        nextBird -= dt
        if nextBird <= 0 {
            if !g.swimming && g.pos.y > 0.8 {
                play(birdPlayers[birdCursor % birdPlayers.count],
                     birdBuffers[birdCursor % birdBuffers.count],
                     volume: Float.random(in: 0.1...0.2))
            }
            birdCursor += 1
            nextBird = Float.random(in: 4...11)
        }

        // Underwater. The same crossfade as the shader's `uwAmount(camY)`, so the
        // ear and the eye agree about where the surface is.
        wetness = ease(wetness, muffleOverride ?? clampf((0.30 - g.camPos.y) / 0.40, 0, 1), 8, dt)
        muffleAmount = wetness
        muffle.bands[0].bypass = wetness < 0.02
        muffle.bands[0].frequency = lerp(19000, 420, wetness)
        // A 420 Hz low-pass removes most of the energy in the world, so without
        // this the surface is a wall of sound and below it there is almost
        // nothing. Muffled, not silenced.
        muffle.globalGain = lerp(0, 9, wetness)

        wasSwimming = g.swimming
        wasGrounded = g.onGround
        lastFallSpeed = g.vel.y
    }

    private func ease(_ v: Float, _ target: Float, _ rate: Float, _ dt: Float) -> Float {
        v + (target - v) * min(1, rate * dt)
    }

    private func play(_ node: AVAudioPlayerNode, _ buf: AVAudioPCMBuffer, volume: Float) {
        node.volume = volume
        node.scheduleBuffer(buf, at: nil, options: .interrupts)
        if !node.isPlaying { node.play() }
    }

    // MARK: - verification

    /// Records the mix to a CAF file, which is the only way to prove the graph is
    /// connected, playing and mixing: each buffer can be checked on its own, but a
    /// graph with a broken connection still scans clean. The high band is tracked
    /// too, because a working low-pass is otherwise only audible.
    func startCapture(to url: URL) -> Bool {
        let fmt = engine.mainMixerNode.outputFormat(forBus: 0)
        guard fmt.channelCount >= 2 else { return false }
        captureURL = url
        captureSamples = [[Float](), [Float]()]
        captureSamples[0].reserveCapacity(Int(fmt.sampleRate) * 20)
        captureSamples[1].reserveCapacity(Int(fmt.sampleRate) * 20)
        capturePeak = 0
        captureSum = 0
        captureCount = 0
        captureHigh = 0
        let a = 1 - exp(-2 * Float.pi * 2000 / Float(fmt.sampleRate))
        var hi: [Float] = [0, 0]
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self, let d = buf.floatChannelData else { return }
            self.captureLock.lock()
            for c in 0..<min(2, Int(buf.format.channelCount)) {
                let span = UnsafeBufferPointer(start: d[c], count: Int(buf.frameLength))
                self.captureSamples[c].append(contentsOf: span)
                for v in span {
                    hi[c] += a * (v - hi[c])
                    self.capturePeak = max(self.capturePeak, abs(v))
                    self.captureSum += Double(v * v)
                    self.captureHigh += Double(hi[c] * hi[c])
                    self.captureCount += 1
                }
            }
            self.captureLock.unlock()
        }
        return true
    }

    func stopCapture() -> (peak: Float, rms: Float, bright: Float) {
        engine.mainMixerNode.removeTap(onBus: 0)
        captureLock.lock()
        defer { captureLock.unlock() }
        if let url = captureURL {
            let ok = Sound.write(Sound.buffer(captureSamples), to: url)
            print("audio: capture \(captureSamples[0].count) frames -> \(url.lastPathComponent) \(ok ? "ok" : "FAILED")")
        }
        captureURL = nil
        let rms = captureCount > 0 ? Float((captureSum / captureCount).squareRoot()) : 0
        // Fraction of the energy above 2 kHz: a low-pass makes this fall, so it is
        // the number the underwater test asserts on.
        let bright = captureSum > 1e-12 ? Float(1 - captureHigh / captureSum) : 0
        return (capturePeak, rms, bright)
    }
}
