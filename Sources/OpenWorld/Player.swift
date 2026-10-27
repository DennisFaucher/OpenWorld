import Foundation
import simd

/// Joint angles for the character rig, in radians. Limb angles are positive
/// forward (a rotation about the character's right axis), `out` swings an arm
/// sideways, `lean` pitches the torso, and `rootPitch` tips the whole body —
/// which is how swimming gets it horizontal without a second rig.
struct PlayerPose {
    var lean: Float = 0
    var rootPitch: Float = 0
    var bob: Float = 0
    var headPitch: Float = 0
    var twist: Float = 0

    var hipL: Float = 0
    var kneeL: Float = 0
    var ankleL: Float = 0
    var hipR: Float = 0
    var kneeR: Float = 0
    var ankleR: Float = 0

    var shoulderL: Float = 0
    var elbowL: Float = 0
    var outL: Float = 0
    var shoulderR: Float = 0
    var elbowR: Float = 0
    var outR: Float = 0

    /// Accumulates a weighted pose, so states can be mixed without
    /// filtering the joints themselves.
    mutating func add(_ o: PlayerPose, _ w: Float) {
        lean += o.lean * w
        rootPitch += o.rootPitch * w
        bob += o.bob * w
        headPitch += o.headPitch * w
        twist += o.twist * w
        hipL += o.hipL * w
        kneeL += o.kneeL * w
        ankleL += o.ankleL * w
        hipR += o.hipR * w
        kneeR += o.kneeR * w
        ankleR += o.ankleR * w
        shoulderL += o.shoulderL * w
        elbowL += o.elbowL * w
        outL += o.outL * w
        shoulderR += o.shoulderR * w
        elbowR += o.elbowR * w
        outR += o.outR * w
    }
}

/// The character: an original design, seven primitives per limb, posed by a
/// `PlayerPose` and drawn from overlapping spheres. Joint heights double as the
/// rig's proportions, so the feet sit on y = 0 whatever the pose does.
enum Player {
    static let hipY: Float = 0.86
    static let thigh: Float = 0.42
    static let shin: Float = 0.35
    static let shoulderY: Float = 0.38
    static let shoulderX: Float = 0.29
    static let upperArm: Float = 0.24
    static let foreArm: Float = 0.20

    static let shirt = V3(0.15, 0.55, 0.92)
    static let trousers = V3(0.95, 0.91, 0.82)
    static let skin = V3(0.99, 0.80, 0.64)
    static let shoe = V3(0.45, 0.27, 0.14)
    static let straw = V3(0.97, 0.86, 0.48)
    static let band = V3(0.90, 0.25, 0.25)
    static let dark = V3(0.10, 0.08, 0.09)
    static let tankColour = V3(0.28, 0.60, 0.66)
    static let tankBand = V3(0.15, 0.30, 0.34)

    /// Character states. Blending weights between them rather than the joint
    /// angles matters: a low-pass on a 2 Hz stride flattens the legs.
    enum State: Int, CaseIterable {
        case idle, run, rise, fall, swim, slide
    }

    /// Which states are active this frame. Airborne weights cross-fade on
    /// vertical speed so the apex does not pop.
    static func weights(_ g: Game) -> [Float] {
        var w = [Float](repeating: 0, count: State.allCases.count)
        if g.swimming {
            w[State.swim.rawValue] = 1
        } else if g.sliding {
            w[State.slide.rawValue] = 1
        } else if !g.onGround {
            let rise = clampf((g.vel.y + 3) / 6, 0, 1)
            w[State.rise.rawValue] = rise
            w[State.fall.rawValue] = 1 - rise
        } else if g.speedNorm > 0.12 {
            w[State.run.rawValue] = 1
        } else {
            w[State.idle.rawValue] = 1
        }
        return w
    }

    static func pose(weights: [Float], _ g: Game) -> PlayerPose {
        var out = PlayerPose()
        for (i, st) in State.allCases.enumerated() where weights[i] > 0.001 {
            out.add(pose(st, g), weights[i])
        }
        return out
    }

    static func pose(_ st: State, _ g: Game) -> PlayerPose {
        switch st {
        case .idle: return idlePose(g)
        case .run: return runPose(g)
        case .rise: return risePose()
        case .fall: return fallPose()
        case .swim: return swimPose(g)
        case .slide: return slidePose()
        }
    }

    /// Horizontal at the surface: the pitch alone would leave the head under
    /// water, so the body is also lifted.
    static func swimPose(_ g: Game) -> PlayerPose {
        var p = PlayerPose()
        let ph = g.walkPhase
        p.rootPitch = 1.15
        p.bob = 0.62
        p.headPitch = -0.65
        let kick = sin(ph * 2.4)
        p.hipL = 0.16 * kick
        p.kneeL = 0.30 + 0.22 * kick
        p.hipR = -0.16 * kick
        p.kneeR = 0.30 - 0.22 * kick
        let stroke = ph * 1.5
        p.shoulderL = stroke
        p.elbowL = 0.55 + 0.30 * sin(stroke)
        p.outL = 0.30
        p.shoulderR = stroke + Float.pi
        p.elbowR = 0.55 + 0.30 * sin(stroke + Float.pi)
        p.outR = 0.30
        return p
    }

    /// Braced and leaning back, arms out for balance.
    static func slidePose() -> PlayerPose {
        var p = PlayerPose()
        p.rootPitch = -0.22
        p.lean = -0.10
        p.headPitch = 0.22
        p.hipL = 0.50
        p.kneeL = 0.55
        p.ankleL = -0.25
        p.hipR = 0.16
        p.kneeR = 0.40
        p.ankleR = -0.15
        p.outL = 1.15
        p.outR = 1.15
        p.shoulderL = -0.35
        p.shoulderR = -0.35
        p.elbowL = 0.45
        p.elbowR = 0.45
        return p
    }

    static func risePose() -> PlayerPose {
        var p = PlayerPose()
        p.lean = 0.06
        p.headPitch = -0.10
        p.hipL = 0.55
        p.kneeL = 1.05
        p.hipR = 0.30
        p.kneeR = 0.75
        p.ankleL = -0.20
        p.ankleR = -0.20
        p.shoulderL = 2.20
        p.shoulderR = 2.20
        // `out` is a Z rotation in the torso frame, so once an arm points above
        // horizontal the same sign pulls it inward. Negative spreads it.
        p.outL = -1.15
        p.outR = -1.15
        p.elbowL = 0.30
        p.elbowR = 0.30
        return p
    }

    static func fallPose() -> PlayerPose {
        var p = PlayerPose()
        p.lean = 0.12
        p.headPitch = 0.10
        p.hipL = 0.48
        p.kneeL = 0.42
        p.hipR = -0.28
        p.kneeR = 0.55
        p.ankleL = -0.25
        p.ankleR = -0.30
        p.outL = 1.30
        p.outR = 1.30
        p.shoulderL = 0.20
        p.shoulderR = 0.20
        p.elbowL = 0.25
        p.elbowR = 0.25
        return p
    }

    static func runPose(_ g: Game) -> PlayerPose {
        var p = PlayerPose()
        let ph = g.walkPhase
        let s = clampf(g.speedNorm, 0, 1.5)
        let sw = sin(ph)
        p.lean = 0.10 + 0.04 * s
        p.headPitch = -0.12
        p.twist = 0.12 * sw * s
        p.hipL = 0.80 * sw * s
        p.hipR = -0.80 * sw * s
        p.kneeL = 0.20 + 0.95 * max(0, sin(ph - 3.03)) * s
        p.kneeR = 0.20 + 0.95 * max(0, sin(ph + Float.pi - 3.03)) * s
        p.ankleL = -0.15 * s
        p.ankleR = -0.15 * s
        p.shoulderL = -0.85 * sw * s
        p.shoulderR = 0.85 * sw * s
        p.elbowL = 0.75 + 0.30 * s
        p.elbowR = 0.75 + 0.30 * s
        p.outL = 0.20
        p.outR = 0.20
        p.bob = 0.035 * abs(cos(ph)) * s
        return p
    }

    /// Weight shifting and a slow breath, arms just clear of the body.
    static func idlePose(_ g: Game) -> PlayerPose {
        var p = PlayerPose()
        let breath = sin(g.time * 1.7)
        p.bob = 0.012 * breath
        p.lean = 0.03 + 0.012 * breath
        p.headPitch = -0.02 - 0.015 * breath
        p.twist = 0.05 * sin(g.time * 0.7)
        p.kneeL = 0.06
        p.kneeR = 0.06
        p.outL = 0.16
        p.outR = 0.16
        p.shoulderL = 0.05
        p.shoulderR = 0.05
        p.elbowL = 0.14
        p.elbowR = 0.14
        return p
    }

    static func parts(_ p: PlayerPose, pos: V3, facing: Float, tank: Float = 1) -> [(M4, V3)] {
        var out: [(M4, V3)] = []
        func add(_ m: M4, _ c: V3) { out.append((m, c)) }

        let root = M4.translation(pos + V3(0, p.bob, 0)) * M4.rotationY(facing) * M4.rotationX(p.rootPitch)
        let pelvis = root * M4.translation(V3(0, hipY, 0))
        let torso = pelvis * M4.rotationX(p.lean) * M4.rotationY(p.twist)

        // Two overlapping spheres read as a waist; one reads as a barrel.
        add(pelvis * M4.translation(V3(0, 0.02, 0)) * M4.scale(V3(0.285, 0.19, 0.255)), shirt)
        add(torso * M4.translation(V3(0, 0.23, 0)) * M4.scale(V3(0.315, 0.255, 0.275)), shirt)

        let head = torso * M4.translation(V3(0, 0.46, 0)) * M4.rotationX(p.headPitch)
        add(head * M4.translation(V3(0, 0.17, 0)) * M4.scale(V3(0.28, 0.29, 0.27)), skin)
        for sx: Float in [-1, 1] {
            add(head * M4.translation(V3(sx * 0.10, 0.18, 0.225)) * M4.scale(V3(0.044, 0.054, 0.04)), dark)
        }

        let hat = head * M4.translation(V3(0, 0.32, 0)) * M4.rotationX(0.10)
        add(hat * M4.scale(V3(0.44, 0.042, 0.44)), straw)
        add(hat * M4.translation(V3(0, 0.08, 0)) * M4.scale(V3(0.25, 0.11, 0.25)), straw)
        add(hat * M4.translation(V3(0, 0.035, 0)) * M4.scale(V3(0.255, 0.030, 0.255)), band)

        for sx: Float in [-1, 1] {
            let shoulder = sx < 0 ? p.shoulderL : p.shoulderR
            let elbow = sx < 0 ? p.elbowL : p.elbowR
            let out = sx < 0 ? p.outL : p.outR
            let arm = torso * M4.translation(V3(sx * shoulderX, shoulderY, 0))
                * M4.rotationZ(sx * out) * M4.rotationX(-shoulder)
            add(arm * M4.translation(V3(0, -upperArm * 0.5, 0)) * M4.scale(V3(0.10, upperArm * 0.58, 0.10)), shirt)
            let fore = arm * M4.translation(V3(0, -upperArm, 0)) * M4.rotationX(-elbow)
            add(fore * M4.translation(V3(0, -foreArm * 0.5, 0)) * M4.scale(V3(0.088, foreArm * 0.60, 0.088)), skin)
            add(fore * M4.translation(V3(0, -foreArm - 0.02, 0)) * M4.scale(V3(0.092, 0.080, 0.094)), skin)
        }

        // The spray pack: a tank on the back and a nozzle in the right hand,
        // built from the same spheres as the body so it needs no new pass.
        // The tank empties from the bottom, so its level doubles as the only
        // readout the player gets without a HUD.
        let level = 0.55 + 0.45 * clampf(tank, 0, 1)
        let pack = torso * M4.translation(V3(0, 0.24 - 0.27 * (1 - level) * 0.5, -0.31))
        add(pack * M4.scale(V3(0.20, 0.27 * level, 0.135)), tankColour)
        add(pack * M4.translation(V3(0, -0.07, -0.02)) * M4.scale(V3(0.205, 0.045, 0.14)), tankBand)
        let armR = torso * M4.translation(V3(shoulderX, shoulderY, 0))
            * M4.rotationZ(p.outR) * M4.rotationX(-p.shoulderR)
        let foreR = armR * M4.translation(V3(0, -upperArm, 0)) * M4.rotationX(-p.elbowR)
        let hand = foreR * M4.translation(V3(0, -foreArm - 0.02, 0))
        add(hand * M4.translation(V3(0, -0.09, 0)) * M4.scale(V3(0.042, 0.14, 0.042)), tankBand)
        add(hand * M4.translation(V3(0, -0.20, 0)) * M4.scale(V3(0.062, 0.055, 0.062)), tankColour)

        for sx: Float in [-1, 1] {
            let hip = sx < 0 ? p.hipL : p.hipR
            let knee = sx < 0 ? p.kneeL : p.kneeR
            let ankle = sx < 0 ? p.ankleL : p.ankleR
            let leg = pelvis * M4.translation(V3(sx * 0.125, 0, 0)) * M4.rotationX(-hip)
            add(leg * M4.translation(V3(0, -thigh * 0.5, 0)) * M4.scale(V3(0.145, thigh * 0.57, 0.15)), trousers)
            let lower = leg * M4.translation(V3(0, -thigh, 0)) * M4.rotationX(-knee)
            add(lower * M4.translation(V3(0, -shin * 0.5, 0)) * M4.scale(V3(0.125, shin * 0.57, 0.13)), trousers)
            let foot = lower * M4.translation(V3(0, -shin, 0)) * M4.rotationX(-ankle)
            add(foot * M4.translation(V3(0, -0.03, 0.05)) * M4.scale(V3(0.125, 0.08, 0.185)), shoe)
        }

        return out
    }
}
