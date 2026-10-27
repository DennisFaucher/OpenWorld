import Foundation
import GameController
import simd

enum Key {
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let d: UInt16 = 2
    static let r: UInt16 = 15
    static let w: UInt16 = 13
    static let space: UInt16 = 49
    static let esc: UInt16 = 53
    static let shift: UInt16 = 56
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

final class Input {
    var keys = Set<UInt16>()
    var mouseDX: Float = 0
    var mouseDY: Float = 0
    var jumpQueued = false

    func down(_ k: UInt16) -> Bool { keys.contains(k) }
}

final class Game {
    static let spawn = V3(-18, World.plazaHeight, 28)
    static let swimY: Float = -0.8
    static let playerRadius: Float = 0.45
    static let jumpVel: Float = 12.5
    /// Grace period after walking off a ledge during which the jump still fires.
    static let coyote: Float = 0.12
    /// A jump pressed this far ahead of landing is remembered.
    static let jumpBufferTime: Float = 0.12
    /// Ground steeper than this (normal.y, i.e. cos 45°) cannot be stood on.
    static let walkSlopeY: Float = 0.7071
    static let slideAccel: Float = 34
    static let slideDrag: Float = 2.0

    let obstacles: [Obstacle]

    var pos = Game.spawn
    var vel = V3.zero
    var facing: Float = 0
    var onGround = false
    var swimming = false
    var walkPhase: Float = 0
    var speedNorm: Float = 0
    var time: Float = 0
    /// Degrees added to the base field of view, so a sprint has a little kick.
    var fovBoost: Float = 0
    let particles = ParticleSystem()

    var camYaw: Float = Float.pi
    var camPitch: Float = 0.25
    var camDist: Float = 9
    var camPos = V3.zero
    var camTarget = V3.zero
    private var curDist: Float = 9
    private var splashCooldown: Float = 0
    private var camInitialised = false
    private var prevPadJump = false
    private var airTime: Float = 0
    private var jumpBuffer: Float = 0
    private var jumpCutArmed = false
    private var camIdle: Float = 0
    /// Raw move input this frame, so the camera can tell a run from a strafe.
    private var wishInput = V2.zero

    init(obstacles: [Obstacle]) {
        self.obstacles = obstacles
    }

    func respawn() {
        pos = Game.spawn
        vel = .zero
        camInitialised = false
    }

    func update(dt: Float, input: Input) {
        time += dt
        let pad = GCController.controllers().first?.extendedGamepad

        // Camera control.
        var camMoved = input.mouseDX != 0 || input.mouseDY != 0
        camYaw -= input.mouseDX * 0.0035
        camPitch += input.mouseDY * 0.0035
        input.mouseDX = 0
        input.mouseDY = 0
        if input.down(Key.left) { camYaw += 2 * dt; camMoved = true }
        if input.down(Key.right) { camYaw -= 2 * dt; camMoved = true }
        if input.down(Key.up) { camPitch -= 1.5 * dt; camMoved = true }
        if input.down(Key.down) { camPitch += 1.5 * dt; camMoved = true }
        if let pad {
            if abs(pad.rightThumbstick.xAxis.value) > 0.05 || abs(pad.rightThumbstick.yAxis.value) > 0.05 {
                camMoved = true
            }
            camYaw -= pad.rightThumbstick.xAxis.value * 2.5 * dt
            camPitch -= pad.rightThumbstick.yAxis.value * 1.8 * dt
        }
        camIdle = camMoved ? 0 : camIdle + dt
        camPitch = clampf(camPitch, -0.55, 1.35)
        if input.down(Key.r) { respawn() }

        // Movement input, relative to the camera.
        var mx: Float = (input.down(Key.d) ? 1 : 0) - (input.down(Key.a) ? 1 : 0)
        var my: Float = (input.down(Key.w) ? 1 : 0) - (input.down(Key.s) ? 1 : 0)
        if let pad {
            mx += pad.leftThumbstick.xAxis.value
            my += pad.leftThumbstick.yAxis.value
        }
        var wish = V2(mx, my)
        let wl = length(wish)
        if wl > 1 { wish /= wl }
        wishInput = wish
        let fwd = V3(-sin(camYaw), 0, -cos(camYaw))
        let right = V3(cos(camYaw), 0, -sin(camYaw))
        let dir = right * wish.x + fwd * wish.y

        var maxSpeed: Float = 9
        if input.down(Key.shift) || (pad?.rightTrigger.value ?? 0) > 0.3 { maxSpeed = 14 }
        let groundHere = World.height(pos.x, pos.z)
        if swimming {
            maxSpeed *= 0.55
        } else if groundHere < -0.2 && onGround {
            maxSpeed *= 0.85
        }
        let accel: Float = (onGround || swimming) ? 14 : 4
        var hv = V2(vel.x, vel.z)
        // Loose footing. On ground steeper than the walk limit there is no
        // traction at all, so the slope wins and the player slides down the fall
        // line whatever the stick says.
        let nHere = World.normal(pos.x, pos.z)
        let sliding = onGround && !swimming && nHere.y < Game.walkSlopeY
        if sliding {
            let dl = max(sqrt(nHere.x * nHere.x + nHere.z * nHere.z), 1e-5)
            hv += V2(nHere.x, nHere.z) / dl * (Game.slideAccel * dt)
            hv *= max(0, 1 - Game.slideDrag * dt)
        } else {
            hv += (V2(dir.x, dir.z) * maxSpeed - hv) * min(1, accel * dt)
        }

        // Jumping. Coyote time keeps a jump alive for a moment after walking off
        // a ledge and the buffer remembers a press made just before landing, so
        // a jump that "definitely happened" is not swallowed by the frame it
        // landed on.
        let padJump = pad?.buttonA.isPressed ?? false
        let jumpPressed = input.jumpQueued || (padJump && !prevPadJump)
        prevPadJump = padJump
        input.jumpQueued = false
        if jumpPressed { jumpBuffer = Game.jumpBufferTime }
        jumpBuffer -= dt

        let canJump = onGround || swimming || airTime < Game.coyote
        if jumpBuffer > 0 && canJump {
            vel.y = swimming ? 9 : Game.jumpVel
            onGround = false
            jumpBuffer = 0
            airTime = Game.coyote          // a jump consumes the coyote window
            jumpCutArmed = !swimming       // rising out of water is not cut short
        }
        // Variable height: releasing during the rise trims the rest of it, so a
        // tap is a hop and a hold is a full jump off the same button.
        let holding = input.down(Key.space) || padJump
        if jumpCutArmed && !holding && vel.y > 0 {
            vel.y *= 0.42
            jumpCutArmed = false
        }

        // Horizontal move, world bounds, then push out of obstacles.
        var np = pos
        np.x += hv.x * dt
        np.z += hv.y * dt
        let fromOrigin = V2(np.x, np.z)
        let dist = length(fromOrigin)
        if dist > World.boundsRadius {
            let c = fromOrigin / dist * World.boundsRadius
            np.x = c.x
            np.z = c.y
        }
        resolveObstacles(&np)

        // The vertical snap below lifts the player onto whatever is under them,
        // so without this any face is climbable, however steep. Strip the uphill
        // part of a step into ground past the walk limit and keep the component
        // that runs along the contour.
        let nDest = World.normal(np.x, np.z)
        if nDest.y < Game.walkSlopeY && World.height(np.x, np.z) > pos.y - 0.05 {
            let ux = -nDest.x, uz = -nDest.z
            let ul = sqrt(ux * ux + uz * uz)
            if ul > 1e-5 {
                let up = ((np.x - pos.x) * ux + (np.z - pos.z) * uz) / ul
                if up > 0 {
                    np.x -= ux / ul * up
                    np.z -= uz / ul * up
                }
            }
        }

        // Vertical: gravity, buoyancy in deep water, terrain snap.
        let g = World.height(np.x, np.z)
        let deep = g < -1.1
        let wasSwimming = swimming
        let fallSpeed = vel.y
        if deep && pos.y < Game.swimY + 0.35 {
            // Spring towards the swim line, but clamp the displacement: landing
            // deep used to fling the player out of the water, and every bob back
            // in re-triggered the splash.
            let lift = clampf(Game.swimY - pos.y, -0.9, 0.9)
            vel.y += (lift * 60 - vel.y * 9) * dt + sin(time * 2) * 0.4 * dt
        } else {
            // Falling is heavier than rising. That asymmetry is most of what
            // separates a jump that feels sharp from one that feels floaty, and
            // the clamp stops a long drop tunnelling through the terrain.
            vel.y -= (vel.y > 0 ? 30 : 42) * dt
            vel.y = max(vel.y, -48)
        }
        np.y += vel.y * dt
        if np.y <= g {
            np.y = g
            vel.y = 0
            onGround = true
        } else if onGround && vel.y <= 0 && np.y - g < (sliding ? 0.9 : 0.35) {
            np.y = g
            vel.y = 0
        } else {
            onGround = false
        }
        airTime = onGround ? 0 : airTime + dt
        swimming = deep && np.y < Game.swimY + 0.35

        vel.x = hv.x
        vel.z = hv.y
        pos = np

        let speed = length(hv)
        speedNorm = speed / 9
        if speed > 0.5 {
            let target = atan2(hv.x, hv.y)
            let d = atan2(sin(target - facing), cos(target - facing))
            facing += d * min(1, 14 * dt)
        }
        walkPhase += speed * dt * 2.6

        // Water spray. Wading off the beach is a walk, not a drop: the terrain
        // snap zeroes `vel.y` every frame, so the horizontal speed is what
        // carries the impact there.
        if swimming && !wasSwimming {
            let power = max(-fallSpeed, speed * 0.6)
            if power > 1.8 && splashCooldown <= 0 {
                splashCooldown = 0.7
                particles.splash(at: V3(pos.x, 0, pos.z), strength: min(2.4, 0.55 + power / 5))
            }
        }
        splashCooldown -= dt
        let wading = !swimming && onGround && g < -0.1
        particles.update(dt: dt, swimming: swimming, speed: speed,
                         feet: V3(pos.x, max(pos.y, 0), pos.z), wading: wading)

        updateCamera(dt: dt)
    }

    private func resolveObstacles(_ p: inout V3) {
        let r = Game.playerRadius
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
                    // Inside the box: leave through the nearest face.
                    let dl = xz.x - lo.x, dr = hi.x - xz.x, db = xz.y - lo.y, dt = hi.y - xz.y
                    let m = min(min(dl, dr), min(db, dt))
                    if m == dl { p.x = lo.x - r } else if m == dr { p.x = hi.x + r } else if m == db { p.z = lo.y - r } else { p.z = hi.y + r }
                }
            }
        }
    }

    private func cameraBlocked(_ p: V3) -> Bool {
        if p.y < World.height(p.x, p.z) + 0.3 { return true }
        for o in obstacles where p.y < o.topY {
            if o.round {
                if length(V2(p.x, p.z) - o.center) < o.half.x + 0.3 { return true }
            } else {
                let lo = o.center - o.half - V2(repeating: 0.3), hi = o.center + o.half + V2(repeating: 0.3)
                if p.x > lo.x && p.x < hi.x && p.z > lo.y && p.z < hi.y { return true }
            }
        }
        return false
    }

    private func updateCamera(dt: Float) {
        let flat = V2(vel.x, vel.z)
        let hs = length(flat)

        // Swing back behind the runner once the player has left the camera alone
        // for a moment. Only while pushing forward: recentring during a strafe
        // would rotate the frame the strafe is measured in and fight the player.
        if camIdle > 1.2 && !swimming && onGround && hs > 4 && wishInput.y > 0.5 {
            let want = facing + Float.pi
            let d = atan2(sin(want - camYaw), cos(want - camYaw))
            camYaw += d * min(1, 0.9 * dt)
        }
        // A little look-ahead along the run, so the frame shows where the player
        // is going rather than centring them dead. It fades out as the camera is
        // pulled in, or a collapsed boom would leave the camera inside the head.
        let leanFade = clampf((curDist - 2.5) / 4, 0, 1)
        let lean = hs > 0.8 ? V3(flat.x, 0, flat.y) / hs * (min(hs, 14) * 0.07 * leanFade) : .zero
        let desired = pos + V3(0, 1.5, 0) + lean
        if !camInitialised {
            camTarget = desired
            curDist = camDist
            camInitialised = true
        } else {
            camTarget += (desired - camTarget) * min(1, 12 * dt)
        }
        // A sprint widens the lens slightly; it reads as speed without moving
        // anything in the world.
        let wantFov = (onGround && hs > 10) ? min(6, (hs - 10) * 0.9) : 0
        fovBoost += (wantFov - fovBoost) * min(1, 6 * dt)

        let dirV = V3(sin(camYaw) * cos(camPitch), sin(camPitch), cos(camYaw) * cos(camPitch))

        // March out from the player and stop short of anything solid.
        var allowed = camDist
        let steps = 16
        for i in 1...steps {
            let t = Float(i) / Float(steps) * camDist
            if cameraBlocked(camTarget + dirV * t) {
                allowed = max(t - camDist / Float(steps) - 0.3, 2.2)
                break
            }
        }
        curDist = allowed < curDist ? allowed : curDist + (allowed - curDist) * min(1, 4 * dt)

        camPos = camTarget + dirV * curDist
        let ground = World.height(camPos.x, camPos.z) + 0.6
        // Swimming, the camera may follow the player under the surface so the
        // underwater look is reachable; on land it always stays above the waterline.
        camPos.y = max(camPos.y, swimming ? max(ground, World.seabed + 0.4) : max(ground, 0.5))
    }
}
