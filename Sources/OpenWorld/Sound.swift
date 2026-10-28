import AVFoundation

/// Every sound in the game, synthesised into buffers at launch. There are no
/// asset files in the repository, so the surf is filtered noise, the chime is a
/// handful of decaying partials and the birds are frequency sweeps. Generation is
/// deterministic, which is what lets `--audio-scan` check it by number instead of
/// by ear.
enum Sound {
    static let rate: Double = 48_000
    static let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!

    /// xorshift, so a sound is the same on every launch and every machine.
    struct Noise {
        private var s: UInt32
        init(_ seed: UInt32) { s = seed | 1 }
        mutating func next() -> Float {
            s ^= s << 13
            s ^= s >> 17
            s ^= s << 5
            return Float(Int32(bitPattern: s)) / Float(Int32.max)
        }
    }

    /// One-pole filter. `cut` is in Hz and may move per sample: sweeping it is
    /// how a splash loses its brightness.
    struct Pole {
        var z: Float = 0
        mutating func low(_ x: Float, _ cut: Float) -> Float {
            let a = 1 - exp(-2 * Float.pi * max(cut, 1) / Float(Sound.rate))
            z += a * (x - z)
            return z
        }
        mutating func high(_ x: Float, _ cut: Float) -> Float { x - low(x, cut) }
    }

    // MARK: - buffers

    static func buffer(_ seconds: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount((seconds * rate).rounded())
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        return b
    }

    /// Scales the buffer so its loudest sample sits at `peak`. Each sound is
    /// balanced once, here, rather than by guesswork at the mixer.
    @discardableResult
    static func normalise(_ b: AVAudioPCMBuffer, to peak: Float) -> AVAudioPCMBuffer {
        let ch = b.floatChannelData!
        var m: Float = 0
        for c in 0..<Int(b.format.channelCount) {
            for i in 0..<Int(b.frameLength) { m = max(m, abs(ch[c][i])) }
        }
        guard m > 1e-9 else { return b }
        let g = peak / m
        for c in 0..<Int(b.format.channelCount) {
            for i in 0..<Int(b.frameLength) { ch[c][i] *= g }
        }
        return b
    }

    /// High pass in place. Below 40 Hz there is no information, only headroom.
    /// The filter runs over the tail of the buffer first, without writing, because
    /// starting from a zero state leaves the first few milliseconds quiet — which
    /// for a loop is a step at the wrap point.
    static func highPass(_ b: AVAudioPCMBuffer, _ cut: Float) {
        let ch = b.floatChannelData!
        let n = Int(b.frameLength)
        let warm = min(n, Int(0.25 * rate))
        for c in 0..<Int(b.format.channelCount) {
            var p = Pole()
            for i in (n - warm)..<n { _ = p.high(ch[c][i], cut) }
            for i in 0..<n { ch[c][i] = p.high(ch[c][i], cut) }
        }
    }

    /// Folds the tail of a longer buffer over its head so the loop repeats
    /// without a step. Noise has no period, so a crossfade is the only way a
    /// noise loop can be clickless; `src` must hold `seconds + fade`.
    static func seamless(_ src: AVAudioPCMBuffer, seconds: Double, fade: Double) -> AVAudioPCMBuffer {
        let out = buffer(seconds)
        let s = src.floatChannelData!, d = out.floatChannelData!
        let n = Int(out.frameLength)
        let f = max(1, Int(fade * rate))
        for c in 0..<Int(out.format.channelCount) {
            for i in 0..<n {
                if i < f {
                    let w = Float(i) / Float(f)
                    d[c][i] = s[c][i] * w + s[c][n + i] * (1 - w)
                } else {
                    d[c][i] = s[c][i]
                }
            }
        }
        return out
    }

    /// Peak, RMS and, for a loop, the wrap step divided by the 99th percentile of
    /// the steps either side of it. Noise jumps a lot between neighbours, so an
    /// absolute difference says nothing; below 1 the seam is indistinguishable
    /// from the material, and a click is far above it.
    static func stats(_ b: AVAudioPCMBuffer, loop: Bool) -> (peak: Float, rms: Float, seam: Float) {
        let ch = b.floatChannelData!
        var peak: Float = 0
        var sum: Double = 0
        for c in 0..<Int(b.format.channelCount) {
            for i in 0..<Int(b.frameLength) {
                let v = ch[c][i]
                peak = max(peak, abs(v))
                sum += Double(v * v)
            }
        }
        var seam: Float = 0
        if loop, b.frameLength > 4 {
            let n = Int(b.frameLength)
            let w = min(n / 2, Int(0.02 * rate))
            var steps: [Float] = []
            steps.reserveCapacity(2 * w)
            for i in 1..<w { steps.append(abs(ch[0][i] - ch[0][i - 1])) }
            for i in (n - w + 1)..<n { steps.append(abs(ch[0][i] - ch[0][i - 1])) }
            steps.sort()
            let wrap = abs(ch[0][n - 1] - ch[0][0])
            let p99 = steps.isEmpty ? 0 : steps[min(steps.count - 1, Int(0.99 * Float(steps.count)))]
            seam = p99 > 1e-9 ? wrap / p99 : 0
        }
        return (peak, Float((sum / (Double(b.frameLength) * Double(b.format.channelCount))).squareRoot()), seam)
    }

    /// Writes a buffer as a file the system can play. The file is interleaved and
    /// the processing format is not, which is the combination that needs no
    /// conversion and logs no warning: asking for a non-interleaved *file* only
    /// gets the writer to ignore the request.
    @discardableResult
    static func write(_ b: AVAudioPCMBuffer, to url: URL) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: Int(b.format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
        else { return false }
        do { try file.write(from: b) } catch { return false }
        return true
    }

    /// A buffer built from per-channel samples, for the capture path.
    static func buffer(_ samples: [[Float]]) -> AVAudioPCMBuffer {
        let b = buffer(Double(samples.map(\.count).max() ?? 0) / rate)
        let ch = b.floatChannelData!
        for c in 0..<min(2, samples.count) {
            for i in 0..<samples[c].count { ch[c][i] = samples[c][i] }
        }
        return b
    }

    // MARK: - the bed

    /// Surf: two bands of filtered noise under a swell that repeats with the
    /// loop, so the crossfade blends identical modulation. The bright band is
    /// the same envelope delayed a fifth of a second, which is the difference
    /// between a wave arriving and a hiss fading in.
    static func surf(seconds: Double = 12) -> AVAudioPCMBuffer {
        let fade = 0.8
        let src = buffer(seconds + fade)
        let ch = src.floatChannelData!
        let n = Int(src.frameLength)
        let fs = Float(rate)
        let loop = Float(seconds)
        func swell(_ t: Float) -> Float {
            // A floor well above zero: the bed has to breathe, not stop. The
            // exponent does the rest, and the bright band uses a steeper one so
            // the crash still arrives after the body of the wave.
            let s = 0.68 + 0.20 * sin(2 * .pi * t / loop + 0.6)
                + 0.12 * sin(4 * .pi * t / loop + 2.1)
            return max(s, 0)
        }
        for c in 0..<2 {
            var nz = Noise(0x51a1 &+ UInt32(c) &* 977)
            var nz2 = Noise(0x2b7e &+ UInt32(c) &* 613)
            var body1 = Pole(), body2 = Pole(), rumble = Pole()
            var hiss = Pole(), bright = Pole()
            for i in 0..<n {
                let t = Float(i) / fs
                let body = powf(swell(t), 1.5)
                let spray = powf(swell(t - 0.18), 2.6)
                let w = nz.next()
                let low = body2.low(body1.low(w, 900), 340)
                let deep = rumble.low(nz2.next(), 105)
                let foam = bright.high(hiss.low(nz2.next(), 5200), 1700)
                ch[c][i] = (low * 1.3 + deep * 0.8) * body + foam * 0.85 * spray
            }
        }
        let out = seamless(src, seconds: seconds, fade: fade)
        highPass(out, 40)
        return normalise(out, to: 0.72)
    }

    /// Wind: a band around 700 Hz for the body and a thin band near 2 kHz for the
    /// whistle over a ridge.
    static func wind(seconds: Double = 9) -> AVAudioPCMBuffer {
        let fade = 0.7
        let src = buffer(seconds + fade)
        let ch = src.floatChannelData!
        let n = Int(src.frameLength)
        let fs = Float(rate)
        let loop = Float(seconds)
        for c in 0..<2 {
            var nz = Noise(0x77c3 &+ UInt32(c) &* 431)
            var bandLo = Pole(), bandHi = Pole(), whistle = Pole(), toneHi = Pole()
            for i in 0..<n {
                let t = Float(i) / fs
                let env = max(0.42 + 0.34 * sin(2 * .pi * 2 * t / loop + 0.3)
                              + 0.24 * sin(2 * .pi * 5 * t / loop + 1.7), 0)
                let w = nz.next()
                let band = bandHi.low(w, 1100) - bandLo.low(w, 380)
                let air = toneHi.high(whistle.low(nz.next(), 2600), 1900)
                ch[c][i] = band * env * 0.9 + air * env * 0.26
            }
        }
        let out = seamless(src, seconds: seconds, fade: fade)
        highPass(out, 60)
        return normalise(out, to: 0.55)
    }

    /// The jet: pressurised hiss with a tone through it, fluttering at 7 and
    /// 11 Hz — both whole numbers of cycles in the two-second loop.
    static func jet(seconds: Double = 2) -> AVAudioPCMBuffer {
        let fade = 0.2
        let src = buffer(seconds + fade)
        let ch = src.floatChannelData!
        let n = Int(src.frameLength)
        let fs = Float(rate)
        for c in 0..<2 {
            var nz = Noise(0x3c19 &+ UInt32(c) &* 811)
            var body = Pole(), bright = Pole()
            for i in 0..<n {
                let t = Float(i) / fs
                let flutter = 0.60 + 0.25 * sin(2 * .pi * 7 * t) + 0.15 * sin(2 * .pi * 11 * t)
                let hiss = bright.high(body.low(nz.next(), 7000), 1500)
                let tone = sin(2 * .pi * 3050 * t) * 0.10 + sin(2 * .pi * 1760 * t) * 0.05
                ch[c][i] = (hiss * 1.4 + tone) * flutter
            }
        }
        let out = seamless(src, seconds: seconds, fade: fade)
        highPass(out, 120)
        return normalise(out, to: 0.5)
    }

    /// The outboard: a 42 Hz sawtooth (harmonics summed, not a raw ramp) with a
    /// noise chug on top. Pitch is not baked in — the player node's varispeed
    /// unit does that, so one buffer covers idle to flat out.
    static func motor(seconds: Double = 1) -> AVAudioPCMBuffer {
        let fade = 0.1
        let src = buffer(seconds + fade)
        let ch = src.floatChannelData!
        let n = Int(src.frameLength)
        let fs = Float(rate)
        for c in 0..<2 {
            var nz = Noise(0x11a7 &+ UInt32(c) &* 353)
            var body = Pole()
            for i in 0..<n {
                let t = Float(i) / fs
                var s: Float = 0
                for h in 1...14 { s += sin(2 * .pi * 42 * Float(h) * t) / Float(h) }
                let chug = 0.72 + 0.28 * sin(2 * .pi * 21 * t)
                let wash = body.low(nz.next(), 900)
                ch[c][i] = (s * 0.30 + wash * 0.55) * chug
            }
        }
        let out = seamless(src, seconds: seconds, fade: fade)
        highPass(out, 35)
        return normalise(out, to: 0.6)
    }

    // MARK: - one-shots

    /// A footfall: a thump of air, a small thud under it, and a grain of grit
    /// where the boot meets the ground. Three variants so a walk is not a loop.
    static func step(variant: Int) -> AVAudioPCMBuffer {
        let b = buffer(0.20)
        let ch = b.floatChannelData!
        let fs = Float(rate)
        let cut: Float = [980, 1250, 760][variant % 3]
        let thump: Float = [104, 92, 118][variant % 3]
        for c in 0..<2 {
            var nz = Noise(0x9001 &+ UInt32(variant) &* 71 &+ UInt32(c))
            var nz2 = Noise(0x4407 &+ UInt32(variant) &* 53 &+ UInt32(c))
            var body = Pole(), grit = Pole()
            for i in 0..<Int(b.frameLength) {
                let t = Float(i) / fs
                let air = body.low(nz.next(), cut) * expf(-t * 46)
                let thud = sin(2 * .pi * thump * t) * expf(-t * 32) * 0.75
                let grain = grit.high(nz2.next(), 3400) * expf(-t * 110) * 0.3
                ch[c][i] = air * 1.2 + thud + grain
            }
        }
        return normalise(b, to: 0.55)
    }

    /// Entering the water: a broadband slap whose brightness falls away as the
    /// bubbles come up behind it.
    static func splash() -> AVAudioPCMBuffer {
        let b = buffer(0.9)
        let ch = b.floatChannelData!
        let fs = Float(rate)
        let bubbles: [(Float, Float)] = [(0.09, 640), (0.19, 760), (0.31, 900), (0.44, 1080), (0.58, 1260)]
        for c in 0..<2 {
            var nz = Noise(0x2f11 &+ UInt32(c) &* 97)
            var lp = Pole(), hp = Pole()
            for i in 0..<Int(b.frameLength) {
                let t = Float(i) / fs
                let attack = 1 - expf(-t * 400)
                let decay = expf(-t * 3.0)
                let cut = 350 + 5200 * expf(-t * 6.5)
                let w = nz.next()
                let body = lp.low(w, cut) * attack * decay
                let fizz = hp.high(w, 2200) * expf(-t * 12) * 0.35
                var bubble: Float = 0
                for (at, f) in bubbles {
                    let dt2 = t - at
                    if dt2 > 0 && dt2 < 0.18 {
                        bubble += sin(2 * .pi * (f + dt2 * 900) * dt2) * expf(-dt2 * 34) * 0.22
                    }
                }
                ch[c][i] = body * 1.3 + fizz + bubble
            }
        }
        return normalise(b, to: 0.7)
    }

    /// A pickup: three bell notes up the A major triad, each four partials with
    /// its own decay. The partial ratios are a struck bar's, not a harmonic
    /// series, which is what makes it read as a chime rather than a tone.
    static func chime() -> AVAudioPCMBuffer {
        let b = buffer(1.9)
        let ch = b.floatChannelData!
        let fs = Float(rate)
        let notes: [(f: Float, at: Float, gain: Float, pan: Float)] = [
            (880.0, 0.00, 1.00, -0.25),
            (1108.73, 0.085, 0.85, 0.05),
            (1318.51, 0.17, 0.70, 0.3),
        ]
        let partials: [(ratio: Float, gain: Float, decay: Float)] = [
            (1.0, 1.00, 1.30), (2.0, 0.42, 0.75), (2.76, 0.26, 0.45), (5.4, 0.12, 0.26),
        ]
        for c in 0..<2 {
            let side: Float = c == 0 ? -1 : 1
            for i in 0..<Int(b.frameLength) {
                let t = Float(i) / fs
                var s: Float = 0
                for note in notes where t >= note.at {
                    let dt = t - note.at
                    let pan = 0.5 + 0.5 * side * note.pan
                    for p in partials {
                        s += sin(2 * .pi * note.f * p.ratio * dt) * p.gain * expf(-dt / p.decay)
                            * note.gain * pan
                    }
                }
                ch[c][i] = s
            }
        }
        return normalise(b, to: 0.6)
    }

    /// A swimming stroke: one hand pulling through the water, so a band that
    /// sweeps up as the hand catches and down as it releases, with a low gulp
    /// behind it. Deep water is the only place `steps` stops advancing, so without
    /// this the sea is all you hear while swimming.
    static func stroke(variant: Int) -> AVAudioPCMBuffer {
        let b = buffer(0.62)
        let ch = b.floatChannelData!
        let fs = Float(rate)
        let v = variant % 2
        let len: Float = v == 0 ? 0.55 : 0.62
        let top: Float = v == 0 ? 1150 : 980
        let gulpF: Float = v == 0 ? 190 : 230
        for c in 0..<2 {
            var nz = Noise(0xa31f &+ UInt32(v) &* 137 &+ UInt32(c) &* 13)
            var body = Pole(), skirt = Pole()
            for i in 0..<Int(b.frameLength) {
                let t = Float(i) / fs
                let u = min(t / len, 1)
                // Zero at both ends, so a stroke can start on any frame.
                let env = sin(powf(u, 0.75) * .pi)
                let cut = 300 + top * sin(u * .pi)
                let w = nz.next()
                let band = body.low(w, cut) - skirt.low(w, cut * 0.32)
                let boom = sin(2 * .pi * gulpF * t) * expf(-powf((u - 0.62) * 6, 2)) * 0.22
                ch[c][i] = band * env * 1.6 + boom
            }
        }
        highPass(b, 90)
        return normalise(b, to: 0.5)
    }

    /// Landing: the weight of a fall, which is mostly a short low thud.
    static func thud() -> AVAudioPCMBuffer {
        let b = buffer(0.32)
        let ch = b.floatChannelData!
        let fs = Float(rate)
        for c in 0..<2 {
            var nz = Noise(0x6f2b &+ UInt32(c) &* 89)
            var body = Pole()
            for i in 0..<Int(b.frameLength) {
                let t = Float(i) / fs
                let f = 72 - min(t, 0.12) * 220
                let boom = sin(2 * .pi * f * t) * expf(-t * 16)
                let dirt = body.low(nz.next(), 260) * expf(-t * 30) * 0.7
                ch[c][i] = boom + dirt
            }
        }
        return normalise(b, to: 0.5)
    }

    /// A bird: three short sweeps with vibrato, the second variant answering
    /// from the other side of the player.
    static func bird(variant: Int) -> AVAudioPCMBuffer {
        let b = buffer(0.75)
        let ch = b.floatChannelData!
        let fs = Float(rate)
        let v = variant % 2
        let chirps: [(start: Float, len: Float, f0: Float, f1: Float)] = v == 0
            ? [(0.00, 0.09, 2500, 3450), (0.15, 0.08, 2700, 3300), (0.30, 0.12, 2400, 3100)]
            : [(0.02, 0.11, 3200, 2400), (0.20, 0.10, 3000, 2200)]
        let pan: Float = v == 0 ? -0.35 : 0.4
        for c in 0..<2 {
            let g = 0.5 + 0.5 * (c == 0 ? -1 : 1) * pan
            for i in 0..<Int(b.frameLength) {
                let t = Float(i) / fs
                var s: Float = 0
                for chirp in chirps {
                    let u = (t - chirp.start) / chirp.len
                    if u > 0 && u < 1 {
                        // Integrate the sweep so the phase stays continuous.
                        let phase = 2 * .pi * (chirp.f0 * t + (chirp.f1 - chirp.f0) * u * u * chirp.len * 0.5)
                        s += sin(phase + 1.7 * sin(2 * .pi * 48 * t)) * powf(sin(.pi * u), 1.6)
                    }
                }
                ch[c][i] = s * g
            }
        }
        return normalise(b, to: 0.28)
    }

    /// Every buffer, for `--audio-scan` and `--audio-dump`.
    static func all() -> [(name: String, buffer: AVAudioPCMBuffer, loop: Bool)] {
        var out: [(String, AVAudioPCMBuffer, Bool)] = [
            ("surf", surf(), true), ("wind", wind(), true),
            ("jet", jet(), true), ("motor", motor(), true),
            ("splash", splash(), false), ("chime", chime(), false),
            ("thud", thud(), false),
        ]
        for v in 0..<3 { out.append(("step\(v)", step(variant: v), false)) }
        for v in 0..<2 { out.append(("stroke\(v)", stroke(variant: v), false)) }
        for v in 0..<2 { out.append(("bird\(v)", bird(variant: v), false)) }
        return out
    }
}
