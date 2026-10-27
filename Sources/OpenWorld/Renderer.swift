import Foundation
import ImageIO
import MetalKit
import UniformTypeIdentifiers
import simd

/// Layouts must match `Frame` and `Obj` in the shader source.
struct FrameUniforms {
    var viewProj: M4
    var invViewProj: M4
    var cam: V4
    var sun: V4
    var sunCol: V4
    var lightViewProj: M4
}

struct ObjUniforms {
    var model: M4
    var normalMat: M4
    var tint: V4
}

struct GPUMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    init(device: MTLDevice, builder: MeshBuilder) {
        vertexBuffer = device.makeBuffer(bytes: builder.vertices, length: MemoryLayout<Vertex>.stride * builder.vertices.count, options: .storageModeShared)!
        indexBuffer = device.makeBuffer(bytes: builder.indices, length: MemoryLayout<UInt32>.stride * builder.indices.count, options: .storageModeShared)!
        indexCount = builder.indices.count
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    static let sampleCount = 4
    static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let depthFormat = MTLPixelFormat.depth32Float
    static let shadowMapSize = 4096
    static let hdrFormat = MTLPixelFormat.rgba16Float
    static let bloomDownsample = 2

    let device: MTLDevice
    let queue: MTLCommandQueue
    let input = Input()
    let game: Game

    private let skyPSO: MTLRenderPipelineState
    private let mainPSO: MTLRenderPipelineState
    private let waterPSO: MTLRenderPipelineState
    private let particlePSO: MTLRenderPipelineState
    private let shadowMapPSO: MTLRenderPipelineState
    private let skyDepth: MTLDepthStencilState
    private let opaqueDepth: MTLDepthStencilState
    private let blendDepth: MTLDepthStencilState
    private let particleDepth: MTLDepthStencilState
    private let shadowDepth: MTLDepthStencilState

    // Bloom / post-process
    private let bloomExtractPSO: MTLRenderPipelineState
    private let bloomBlurHPSO: MTLRenderPipelineState
    private let bloomBlurVPSO: MTLRenderPipelineState
    private let bloomCompositePSO: MTLRenderPipelineState
    private let postDepth: MTLDepthStencilState
    private let fullscreenQuad: MTLBuffer
    private var hdrTexture: MTLTexture!
    private var hdrResolve: MTLTexture!
    private var hdrDepth: MTLTexture!
    private var brightTexture: MTLTexture!
    private var blurTextures: [MTLTexture] = []

    private let terrain: GPUMesh
    private let props: GPUMesh
    private let sphere: GPUMesh
    private let waterGrid: MTLBuffer
    private let waterIndices: MTLBuffer
    private let waterIndexCount: Int
    private let heightTexture: MTLTexture
    private let shadowMap: MTLTexture
    private var particleBuffer: MTLBuffer?
    private var particleVerts: [Vertex] = []

    /// Hour 12 reproduces the hand-picked key light; the sun swings from the
    /// horizon at 06:00 to the opposite horizon at 18:00.
    static func sun(hour: Float) -> (dir: V3, color: V3) {
        let h = (hour - 12) / 6
        let azim: Float = 0.838 + h * 1.05
        let elev = max(0.744 * (1 - h * h), 0.05)
        let dir = normalize(V3(cos(elev) * sin(azim), sin(elev), cos(elev) * cos(azim)))
        let warm = sstep(0.10, 0.72, elev)
        return (dir, V3(1.0, lerp(0.52, 0.95, warm), lerp(0.28, 0.80, warm)))
    }

    private let sunDir: V3
    private let sunColor: V3
    private var lastTime = CACurrentMediaTime()
    private var fpsFrames = 0
    private var fpsStart = CACurrentMediaTime()
    private weak var view: MTKView?

    init(device: MTLDevice, hour: Float = 12) {
        self.device = device
        queue = device.makeCommandQueue()!
        (sunDir, sunColor) = Renderer.sun(hour: hour)

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            fatalError("Shader compile failed:\n\(error)")
        }

        let vd = MTLVertexDescriptor()
        for i in 0..<3 {
            vd.attributes[i].format = .float4
            vd.attributes[i].offset = i * 16
            vd.attributes[i].bufferIndex = 0
        }
        vd.layouts[0].stride = MemoryLayout<Vertex>.stride

        func pipeline(_ vs: String, _ fs: String, vertexDescriptor: MTLVertexDescriptor?, blend: Bool) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            d.vertexDescriptor = vertexDescriptor
            d.rasterSampleCount = Renderer.sampleCount
            d.colorAttachments[0].pixelFormat = Renderer.hdrFormat
            d.depthAttachmentPixelFormat = Renderer.depthFormat
            if blend {
                let ca = d.colorAttachments[0]!
                ca.isBlendingEnabled = true
                ca.sourceRGBBlendFactor = .sourceAlpha
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                fatalError("Pipeline \(vs)/\(fs) failed: \(error)")
            }
        }
        func shadowPipeline(_ vs: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = nil
            d.vertexDescriptor = vd
            d.rasterSampleCount = 1
            d.colorAttachments[0].pixelFormat = .invalid
            d.depthAttachmentPixelFormat = Renderer.depthFormat
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                fatalError("Shadow pipeline \(vs) failed: \(error)")
            }
        }
        func postPipeline(_ vs: String, _ fs: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            d.vertexDescriptor = nil
            d.rasterSampleCount = 1
            d.colorAttachments[0].pixelFormat = Renderer.hdrFormat
            d.depthAttachmentPixelFormat = .invalid
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                fatalError("Post pipeline \(vs)/\(fs) failed: \(error)")
            }
        }
        func compositePipeline(_ vs: String, _ fs: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            d.vertexDescriptor = nil
            d.rasterSampleCount = 1
            d.colorAttachments[0].pixelFormat = Renderer.colorFormat
            d.depthAttachmentPixelFormat = .invalid
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                fatalError("Composite pipeline \(vs)/\(fs) failed: \(error)")
            }
        }
        skyPSO = pipeline("vs_sky", "fs_sky", vertexDescriptor: nil, blend: false)
        mainPSO = pipeline("vs_main", "fs_main", vertexDescriptor: vd, blend: false)
        waterPSO = pipeline("vs_water", "fs_water", vertexDescriptor: nil, blend: true)
        particlePSO = pipeline("vs_particle", "fs_particle", vertexDescriptor: vd, blend: true)
        shadowMapPSO = shadowPipeline("vs_shadow")

        // Bloom / post-process pipelines.
        bloomExtractPSO = postPipeline("vs_post", "fs_bloom_extract")
        bloomBlurHPSO = postPipeline("vs_post", "fs_bloom_blur_h")
        bloomBlurVPSO = postPipeline("vs_post", "fs_bloom_blur_v")
        bloomCompositePSO = compositePipeline("vs_post", "fs_bloom_composite")

        func depthState(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        skyDepth = depthState(.always, write: false)
        opaqueDepth = depthState(.less, write: true)
        blendDepth = depthState(.lessEqual, write: false)
        particleDepth = depthState(.lessEqual, write: false)
        shadowDepth = depthState(.less, write: true)
        postDepth = depthState(.always, write: false)

        // World geometry.
        let props = World.buildProps()
        terrain = GPUMesh(device: device, builder: World.buildTerrain())
        self.props = GPUMesh(device: device, builder: props.mesh)
        let unit = MeshBuilder()
        unit.sphere(center: .zero, radii: V3(repeating: 1), color: V3(repeating: 1), rings: 14, segs: 24)
        sphere = GPUMesh(device: device, builder: unit)
        game = Game(obstacles: props.obstacles)

        // Spawn override for play-testing: running to a corner of the map to
        // try one thing is the slow part of testing, so the live window honours
        // the same `--pos`/`--yaw` the headless modes use. The shot path sets
        // these itself after the renderer is built, so it is excluded here.
        if !CommandLine.arguments.contains("--shot"),
           let p = argValues("--pos", 2), p.count == 2 {
            game.pos = V3(p[0], World.height(p[0], p[1]), p[1])
            if let v = argValues("--yaw", 1) { game.camYaw = v[0] }
        }

        // Height map for shoreline depth in the water shader.
        let size = 512
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: size, height: size, mipmapped: false)
        td.usage = .shaderRead
        heightTexture = device.makeTexture(descriptor: td)!
        let heights = World.heightTexture(size: size)
        heightTexture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: heights, bytesPerRow: size * 4)

        // Water grid: dense near the origin, quadratically sparser outwards.
        let n = 150, radius: Float = 1500
        var grid: [V2] = []
        for j in -n...n {
            for i in -n...n {
                let u = Float(i) / Float(n), v = Float(j) / Float(n)
                grid.append(V2(u * abs(u), v * abs(v)) * radius)
            }
        }
        var idx: [UInt32] = []
        let w = UInt32(2 * n + 1)
        for j in 0..<UInt32(2 * n) {
            for i in 0..<UInt32(2 * n) {
                let a = j * w + i, b = a + 1, c = a + w, d = c + 1
                idx += [a, c, b, b, c, d]
            }
        }
        waterGrid = device.makeBuffer(bytes: grid, length: MemoryLayout<V2>.stride * grid.count, options: .storageModeShared)!
        waterIndices = device.makeBuffer(bytes: idx, length: MemoryLayout<UInt32>.stride * idx.count, options: .storageModeShared)!
        waterIndexCount = idx.count

        // Shadow map: depth-only target sampled with hardware PCF.
        let smDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.depthFormat, width: Renderer.shadowMapSize, height: Renderer.shadowMapSize, mipmapped: false)
        smDesc.usage = [.shaderRead, .renderTarget]
        smDesc.storageMode = .private
        shadowMap = device.makeTexture(descriptor: smDesc)!

        // Fullscreen quad for post-processing.
        let quadVertices: [V2] = [
            V2(-1, -1), V2(1, -1), V2(-1, 1),
            V2(-1, 1), V2(1, -1), V2(1, 1)
        ]
        fullscreenQuad = device.makeBuffer(bytes: quadVertices, length: MemoryLayout<V2>.stride * quadVertices.count, options: .storageModeShared)!

        super.init()
    }

    private func createBloomTextures(width: Int, height: Int) {
        let w = max(width / Renderer.bloomDownsample, 1)
        let h = max(height / Renderer.bloomDownsample, 1)

        // MSAA HDR target; resolved to a single-sample texture for post-process.
        let hdrDesc = MTLTextureDescriptor()
        hdrDesc.textureType = .type2DMultisample
        hdrDesc.sampleCount = Renderer.sampleCount
        hdrDesc.pixelFormat = Renderer.hdrFormat
        hdrDesc.width = width
        hdrDesc.height = height
        hdrDesc.usage = .renderTarget
        hdrDesc.storageMode = .private
        hdrTexture = device.makeTexture(descriptor: hdrDesc)!

        let resolveDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.hdrFormat, width: width, height: height, mipmapped: false)
        resolveDesc.usage = [.shaderRead, .renderTarget]
        resolveDesc.storageMode = .private
        hdrResolve = device.makeTexture(descriptor: resolveDesc)!

        // MSAA depth matching the HDR target.
        let depthDesc = MTLTextureDescriptor()
        depthDesc.textureType = .type2DMultisample
        depthDesc.sampleCount = Renderer.sampleCount
        depthDesc.pixelFormat = Renderer.depthFormat
        depthDesc.width = width
        depthDesc.height = height
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        hdrDepth = device.makeTexture(descriptor: depthDesc)!

        // Bright extraction texture.
        let brightDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.hdrFormat, width: w, height: h, mipmapped: false)
        brightDesc.usage = [.shaderRead, .renderTarget]
        brightDesc.storageMode = .private
        brightTexture = device.makeTexture(descriptor: brightDesc)!

        // Ping-pong blur textures (2 for horizontal/vertical passes).
        blurTextures.removeAll()
        for _ in 0..<2 {
            let blurDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.hdrFormat, width: w, height: h, mipmapped: false)
            blurDesc.usage = [.shaderRead, .renderTarget]
            blurDesc.storageMode = .private
            blurTextures.append(device.makeTexture(descriptor: blurDesc)!)
        }
    }

    func configure(_ view: MTKView) {
        self.view = view
        view.device = device
        view.delegate = self
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.sampleCount = Renderer.sampleCount
        view.clearColor = MTLClearColor(red: 0.8, green: 0.94, blue: 1, alpha: 1)
        view.preferredFramesPerSecond = 120

        createBloomTextures(width: Int(view.drawableSize.width), height: Int(view.drawableSize.height))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        createBloomTextures(width: Int(size.width), height: Int(size.height))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTime, 0.05))
        lastTime = now
        game.update(dt: dt, input: input)

        // Render shadow map first.
        encodeShadowMap(cb)

        // 1. Render scene to MSAA HDR target, resolving into hdrResolve.
        let hdrRPD = MTLRenderPassDescriptor()
        hdrRPD.colorAttachments[0].texture = hdrTexture
        hdrRPD.colorAttachments[0].resolveTexture = hdrResolve
        hdrRPD.colorAttachments[0].loadAction = .clear
        hdrRPD.colorAttachments[0].storeAction = .multisampleResolve
        hdrRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0.8, green: 0.94, blue: 1, alpha: 1)
        hdrRPD.depthAttachment.texture = hdrDepth
        hdrRPD.depthAttachment.loadAction = .clear
        hdrRPD.depthAttachment.clearDepth = 1
        hdrRPD.depthAttachment.storeAction = .dontCare

        if let enc = cb.makeRenderCommandEncoder(descriptor: hdrRPD) {
            let size = view.drawableSize
            enc.setFragmentTexture(shadowMap, index: 1)
            encodeScene(enc, aspect: Float(size.width / max(size.height, 1)))
            enc.endEncoding()
        }

        // 2. Bloom extract: threshold bright areas to brightTexture.
        let extractRPD = MTLRenderPassDescriptor()
        extractRPD.colorAttachments[0].texture = brightTexture
        extractRPD.colorAttachments[0].loadAction = .clear
        extractRPD.colorAttachments[0].storeAction = .store
        extractRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let enc = cb.makeRenderCommandEncoder(descriptor: extractRPD) {
            enc.setRenderPipelineState(bloomExtractPSO)
            enc.setDepthStencilState(postDepth)
            enc.setVertexBuffer(fullscreenQuad, offset: 0, index: 0)
            enc.setFragmentTexture(hdrResolve, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }

        // 3. Blur ping-pong (horizontal + vertical, 2 passes each for larger radius).
        let blurPasses = 2
        for i in 0..<blurPasses {
            // Horizontal blur.
            let blurHRPD = MTLRenderPassDescriptor()
            blurHRPD.colorAttachments[0].texture = blurTextures[0]
            blurHRPD.colorAttachments[0].loadAction = .clear
            blurHRPD.colorAttachments[0].storeAction = .store
            blurHRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            if let enc = cb.makeRenderCommandEncoder(descriptor: blurHRPD) {
                enc.setRenderPipelineState(bloomBlurHPSO)
                enc.setDepthStencilState(postDepth)
                enc.setVertexBuffer(fullscreenQuad, offset: 0, index: 0)
                enc.setFragmentTexture(i == 0 ? brightTexture : blurTextures[1], index: 0)
                var texelSize = V2(1.0 / Float(brightTexture.width), 1.0 / Float(brightTexture.height))
                enc.setFragmentBytes(&texelSize, length: MemoryLayout<V2>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc.endEncoding()
            }

            // Vertical blur.
            let blurVRPD = MTLRenderPassDescriptor()
            blurVRPD.colorAttachments[0].texture = blurTextures[1]
            blurVRPD.colorAttachments[0].loadAction = .clear
            blurVRPD.colorAttachments[0].storeAction = .store
            blurVRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            if let enc = cb.makeRenderCommandEncoder(descriptor: blurVRPD) {
                enc.setRenderPipelineState(bloomBlurVPSO)
                enc.setDepthStencilState(postDepth)
                enc.setVertexBuffer(fullscreenQuad, offset: 0, index: 0)
                enc.setFragmentTexture(blurTextures[0], index: 0)
                var texelSize = V2(1.0 / Float(brightTexture.width), 1.0 / Float(brightTexture.height))
                enc.setFragmentBytes(&texelSize, length: MemoryLayout<V2>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc.endEncoding()
            }
        }

        // 4. Composite: HDR + bloom + tone map to drawable.
        let finalRPD = MTLRenderPassDescriptor()
        finalRPD.colorAttachments[0].texture = drawable.texture
        finalRPD.colorAttachments[0].loadAction = .clear
        finalRPD.colorAttachments[0].storeAction = .store
        finalRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0.8, green: 0.94, blue: 1, alpha: 1)

        if let enc = cb.makeRenderCommandEncoder(descriptor: finalRPD) {
            enc.setRenderPipelineState(bloomCompositePSO)
            enc.setDepthStencilState(postDepth)
            enc.setVertexBuffer(fullscreenQuad, offset: 0, index: 0)
            enc.setFragmentTexture(hdrResolve, index: 0)
            enc.setFragmentTexture(blurTextures[1], index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()

        fpsFrames += 1
        if now - fpsStart >= 1 {
            let fps = Double(fpsFrames) / (now - fpsStart)
            view.window?.title = String(format: "OpenWorld — %.0f fps — WASD move · mouse look (click) · Space jump · Shift run · R respawn · Esc release mouse", fps)
            fpsFrames = 0
            fpsStart = now
        }
    }

    // MARK: Scene

    private func encodeScene(_ enc: MTLRenderCommandEncoder, aspect: Float) {
        let proj = M4.perspective(fovY: (60 + game.fovBoost) * Float.pi / 180, aspect: aspect, near: 0.2, far: 4000)
        let viewM = M4.lookAt(eye: game.camPos, center: game.camTarget, up: V3(0, 1, 0))
        let vp = proj * viewM

        // Light view-projection for shadow mapping (orthographic covering the island).
        let lightView = M4.lookAt(eye: sunDir * 300, center: V3(0, 0, 0), up: V3(0, 1, 0))
        let lightProj = M4.orthographic(left: -160, right: 160, bottom: -160, top: 160, near: 10, far: 500)
        let lightVP = lightProj * lightView

        var frame = FrameUniforms(
            viewProj: vp,
            invViewProj: vp.inverse,
            cam: V4(game.camPos, game.time),
            sun: V4(sunDir, 0),
            sunCol: V4(sunColor, 0),
            lightViewProj: lightVP
        )
        enc.setCullMode(.none)
        enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)

        // Sky.
        enc.setRenderPipelineState(skyPSO)
        enc.setDepthStencilState(skyDepth)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Opaque geometry.
        enc.setRenderPipelineState(mainPSO)
        enc.setDepthStencilState(opaqueDepth)
        drawMesh(enc, terrain, model: matrix_identity_float4x4, tint: V4(1, 1, 1, 1))
        drawMesh(enc, props, model: matrix_identity_float4x4, tint: V4(1, 1, 1, 1))
        drawPlayer(enc)

        // Water last, blended over everything.
        enc.setRenderPipelineState(waterPSO)
        enc.setDepthStencilState(blendDepth)
        var obj = ObjUniforms(model: matrix_identity_float4x4, normalMat: matrix_identity_float4x4, tint: V4(game.camPos.x, game.camPos.z, 0, 0))
        enc.setVertexBytes(&obj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
        enc.setVertexBuffer(waterGrid, offset: 0, index: 0)
        enc.setFragmentTexture(heightTexture, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: waterIndexCount, indexType: .uint32, indexBuffer: waterIndices, indexBufferOffset: 0)

        // Spray and foam last: it has to sit over the water surface.
        encodeParticles(enc, view: viewM)
    }

    private func encodeParticles(_ enc: MTLRenderCommandEncoder, view: M4) {
        let parts = game.particles.parts
        // Below the surface the water plane is opaque and would hide the spray,
        // but it writes no depth, so the pass has to be skipped instead.
        guard !parts.isEmpty, game.camPos.y > 0 else { return }
        let right = normalize(V3(view.columns.0.x, view.columns.1.x, view.columns.2.x))
        let up = normalize(V3(view.columns.0.y, view.columns.1.y, view.columns.2.y))

        if particleVerts.count < parts.count * 6 {
            particleVerts = [Vertex](repeating: Vertex(pos: .zero, nrm: .zero, col: .zero),
                                     count: max(parts.count * 6, 6144))
        }
        var n = 0
        for p in parts {
            // Fade out over the lifetime; foam spreads as it goes, droplets shrink.
            let k = p.life / p.maxLife
            var fade = clampf(k * 5, 0, 1) * (0.30 + 0.70 * k)
            // Foam lies on the water, so it is squashed into an ellipse and
            // faded out at grazing angles. Flat quads were truer in plan view
            // but collapsed into white scratches from eye level.
            let foam = p.gravity == 0
            if foam { fade *= sstep(0.10, 0.42, abs(dot(normalize(game.camPos - p.pos), V3(0, 1, 0)))) }
            let r = p.size * (foam ? 1.7 - 0.6 * k : 0.55 + 0.7 * k)
            let ax = right * r
            let ay = up * r * (foam ? 0.60 : 1.0)
            let c = V4(p.tint * (0.9 + 0.12 * k), fade)
            let quad = [V2(-1, -1), V2(1, -1), V2(1, 1), V2(-1, -1), V2(1, 1), V2(-1, 1)]
            for uv in quad {
                let off = ax * uv.x + ay * uv.y
                particleVerts[n] = Vertex(pos: V4(p.pos + off, 1), nrm: V4(uv.x, uv.y, foam ? 1 : 0, 0), col: c)
                n += 1
            }
        }
        let bytes = n * MemoryLayout<Vertex>.stride
        if particleBuffer == nil || particleBuffer!.length < bytes {
            particleBuffer = device.makeBuffer(length: max(bytes, 6144 * MemoryLayout<Vertex>.stride),
                                               options: .storageModeShared)!
        }
        let buf = particleBuffer!
        particleVerts.withUnsafeBytes { raw in
            buf.contents().copyMemory(from: raw.baseAddress!, byteCount: bytes)
        }

        enc.setRenderPipelineState(particlePSO)
        enc.setDepthStencilState(particleDepth)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: n)
    }

    private func encodeShadowMap(_ cb: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.depthAttachment.texture = shadowMap
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1
        rpd.depthAttachment.storeAction = .store

        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(shadowMapPSO)
        enc.setDepthStencilState(shadowDepth)
        enc.setCullMode(.none)

        // Light view-projection for shadow mapping.
        let lightView = M4.lookAt(eye: sunDir * 300, center: V3(0, 0, 0), up: V3(0, 1, 0))
        let lightProj = M4.orthographic(left: -160, right: 160, bottom: -160, top: 160, near: 10, far: 500)
        let lightVP = lightProj * lightView

        // We only need the lightVP for the shadow vertex shader.
        var frame = FrameUniforms(
            viewProj: lightVP,
            invViewProj: lightVP.inverse,
            cam: V4(0, 0, 0, 0),
            sun: V4(sunDir, 0),
            sunCol: V4(sunColor, 0),
            lightViewProj: lightVP
        )
        enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)

        drawMesh(enc, terrain, model: matrix_identity_float4x4, tint: V4(1, 1, 1, 1))
        drawMesh(enc, props, model: matrix_identity_float4x4, tint: V4(1, 1, 1, 1))
        drawPlayer(enc)

        enc.endEncoding()
    }

    private func drawMesh(_ enc: MTLRenderCommandEncoder, _ mesh: GPUMesh, model: M4, tint: V4) {
        var obj = ObjUniforms(model: model, normalMat: model.inverse.transpose, tint: tint)
        enc.setVertexBytes(&obj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
        enc.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indexBuffer, indexBufferOffset: 0)
    }

    private func drawPlayer(_ enc: MTLRenderCommandEncoder) {
        for (model, color) in Player.parts(game.pose, pos: game.pos, facing: game.facing) {
            drawMesh(enc, sphere, model: model, tint: V4(color, 1))
        }
    }

    // MARK: Headless screenshot

    func renderPNG(path: String, width: Int, height: Int) {
        // Recreate bloom textures for this resolution.
        createBloomTextures(width: width, height: height)

        let hdrRPD = MTLRenderPassDescriptor()
        hdrRPD.colorAttachments[0].texture = hdrTexture
        hdrRPD.colorAttachments[0].resolveTexture = hdrResolve
        hdrRPD.colorAttachments[0].loadAction = .clear
        hdrRPD.colorAttachments[0].storeAction = .multisampleResolve
        hdrRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0.8, green: 0.94, blue: 1, alpha: 1)
        hdrRPD.depthAttachment.texture = hdrDepth
        hdrRPD.depthAttachment.loadAction = .clear
        hdrRPD.depthAttachment.clearDepth = 1
        hdrRPD.depthAttachment.storeAction = .dontCare

        let resolveDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.colorFormat, width: width, height: height, mipmapped: false)
        resolveDesc.usage = [.renderTarget, .shaderRead]
        resolveDesc.storageMode = .shared
        let resolve = device.makeTexture(descriptor: resolveDesc)!

        let cb = queue.makeCommandBuffer()!
        // Render shadow map first.
        encodeShadowMap(cb)

        // 1. Render scene to HDR texture.
        if let enc = cb.makeRenderCommandEncoder(descriptor: hdrRPD) {
            enc.setFragmentTexture(shadowMap, index: 1)
            encodeScene(enc, aspect: Float(width) / Float(height))
            enc.endEncoding()
        }

        // 2. Bloom extract.
        let extractRPD = MTLRenderPassDescriptor()
        extractRPD.colorAttachments[0].texture = brightTexture
        extractRPD.colorAttachments[0].loadAction = .clear
        extractRPD.colorAttachments[0].storeAction = .store
        extractRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let enc = cb.makeRenderCommandEncoder(descriptor: extractRPD) {
            enc.setRenderPipelineState(bloomExtractPSO)
            enc.setDepthStencilState(postDepth)
            enc.setVertexBuffer(fullscreenQuad, offset: 0, index: 0)
            enc.setFragmentTexture(hdrResolve, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }

        // 3. Blur ping-pong.
        let blurPasses = 2
        for i in 0..<blurPasses {
            // Horizontal blur.
            let blurHRPD = MTLRenderPassDescriptor()
            blurHRPD.colorAttachments[0].texture = blurTextures[0]
            blurHRPD.colorAttachments[0].loadAction = .clear
            blurHRPD.colorAttachments[0].storeAction = .store
            blurHRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            if let enc = cb.makeRenderCommandEncoder(descriptor: blurHRPD) {
                enc.setRenderPipelineState(bloomBlurHPSO)
                enc.setDepthStencilState(postDepth)
                enc.setVertexBuffer(fullscreenQuad, offset: 0, index: 0)
                enc.setFragmentTexture(i == 0 ? brightTexture : blurTextures[1], index: 0)
                var texelSize = V2(1.0 / Float(brightTexture.width), 1.0 / Float(brightTexture.height))
                enc.setFragmentBytes(&texelSize, length: MemoryLayout<V2>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc.endEncoding()
            }

            // Vertical blur.
            let blurVRPD = MTLRenderPassDescriptor()
            blurVRPD.colorAttachments[0].texture = blurTextures[1]
            blurVRPD.colorAttachments[0].loadAction = .clear
            blurVRPD.colorAttachments[0].storeAction = .store
            blurVRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            if let enc = cb.makeRenderCommandEncoder(descriptor: blurVRPD) {
                enc.setRenderPipelineState(bloomBlurVPSO)
                enc.setDepthStencilState(postDepth)
                enc.setVertexBuffer(fullscreenQuad, offset: 0, index: 0)
                enc.setFragmentTexture(blurTextures[0], index: 0)
                var texelSize = V2(1.0 / Float(brightTexture.width), 1.0 / Float(brightTexture.height))
                enc.setFragmentBytes(&texelSize, length: MemoryLayout<V2>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc.endEncoding()
            }
        }

        // 4. Composite to resolve texture.
        let finalRPD = MTLRenderPassDescriptor()
        finalRPD.colorAttachments[0].texture = resolve
        finalRPD.colorAttachments[0].loadAction = .clear
        finalRPD.colorAttachments[0].storeAction = .store
        finalRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0.8, green: 0.94, blue: 1, alpha: 1)

        if let enc = cb.makeRenderCommandEncoder(descriptor: finalRPD) {
            enc.setRenderPipelineState(bloomCompositePSO)
            enc.setDepthStencilState(postDepth)
            enc.setVertexBuffer(fullscreenQuad, offset: 0, index: 0)
            enc.setFragmentTexture(hdrResolve, index: 0)
            enc.setFragmentTexture(blurTextures[1], index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }

        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        resolve.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info),
              let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("Failed to write \(path)")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("Wrote \(path)")
    }
}
