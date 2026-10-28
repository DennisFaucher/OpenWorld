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

/// Must match `Inst` in the shader: a transform and a tint, 80 bytes.
struct GPUInstance {
    var model: M4
    var tint: V4
}

/// A prop batch uploaded and ready to draw: the shared base mesh, the instance
/// buffer, and the box that decides whether the batch is worth submitting.
struct InstancedBatch {
    let mesh: GPUMesh
    let buffer: MTLBuffer
    let count: Int
    let lo: V3
    let hi: V3
    /// Past this distance the batch is not worth drawing at all. A flower is
    /// 0.28 m across, so beyond ~150 m it is a sub-pixel speck that still costs
    /// its full 48 triangles.
    let maxDistance: Float
}

extension InstancedBatch {
    /// Distance to the batch box, not its centre: a batch the camera is inside
    /// is always close.
    func visibleFrom(_ cam: V3) -> Bool {
        let dx = cam.x - min(max(cam.x, lo.x), hi.x)
        let dy = cam.y - min(max(cam.y, lo.y), hi.y)
        let dz = cam.z - min(max(cam.z, lo.z), hi.z)
        return dx * dx + dy * dy + dz * dz <= maxDistance * maxDistance
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
    private let mainInstPSO: MTLRenderPipelineState
    private let shadowInstPSO: MTLRenderPipelineState
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
    private let seaFloor: GPUMesh
    private let terrainPatches: [World.TerrainPatch]
    /// Terrain submitted in the last scene pass, for `--stats`.
    private(set) var statsChunks = 0
    private(set) var statsTriangles = 0
    /// Chunks drawn at each level: full, half and quarter resolution.
    private(set) var statsLevels = (0, 0, 0)
    private(set) var statsPropBatches = 0
    private(set) var statsPropInstances = 0
    var propBatchTotal: Int { propBatches.count }
    var propInstanceTotal: Int { propBatches.reduce(0) { $0 + $1.count } }
    /// Totals across every island, for `--stats`.
    var terrainChunkTotal: Int { terrainPatches.reduce(0) { $0 + $1.chunks.count } }
    var terrainTriangleTotal: Int {
        terrainPatches.reduce(0) { n, p in n + p.chunks.reduce(0) { $0 + $1.indexCount / 3 } }
    }
    private let props: GPUMesh
    private let propBatches: [InstancedBatch]
    private let sphere: GPUMesh
    private let boatMesh: GPUMesh
    static let waterCells = 64
    /// Rings of 64 cells each: 1 m near the camera doubling to 256 m, which is
    /// +-8 km of open water and 57k triangles instead of 180k.
    static let waterLevels = 9

    private let waterGrid: MTLBuffer
    private let waterIndices: MTLBuffer
    private let waterRingIndices: MTLBuffer
    private let waterRingIndexCount: Int
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
        mainInstPSO = pipeline("vs_inst", "fs_main", vertexDescriptor: vd, blend: false)
        waterPSO = pipeline("vs_water", "fs_water", vertexDescriptor: nil, blend: true)
        particlePSO = pipeline("vs_particle", "fs_particle", vertexDescriptor: vd, blend: true)
        shadowMapPSO = shadowPipeline("vs_shadow")
        shadowInstPSO = shadowPipeline("vs_shadow_inst")

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
        let built = World.buildTerrain()
        terrain = GPUMesh(device: device, builder: built.mesh)
        terrainPatches = built.patches
        seaFloor = GPUMesh(device: device, builder: World.buildSeabed())
        self.props = GPUMesh(device: device, builder: props.mesh)
        // One base mesh per prop kind: three palm shapes (the seed only moves
        // the fronds about), and a unit sphere that bushes and flowers scale.
        var palmMeshes: [GPUMesh] = []
        for seed: Float in [0.7, 2.1, 3.6] {
            let pb = MeshBuilder()
            pb.palm(base: .zero, height: 7, leanDir: 0, lean: 1.4, seed: seed)
            palmMeshes.append(GPUMesh(device: device, builder: pb))
        }
        let bushMesh = GPUMesh(device: device, builder: {
            let mb = MeshBuilder()
            mb.sphere(center: .zero, radii: V3(repeating: 1), color: V3(repeating: 1), rings: 6, segs: 10)
            return mb
        }())
        let flowerMesh = GPUMesh(device: device, builder: {
            let mb = MeshBuilder()
            mb.sphere(center: .zero, radii: V3(repeating: 1), color: V3(repeating: 1), rings: 4, segs: 6)
            return mb
        }())
        func baseMesh(_ kind: World.PropKind) -> GPUMesh {
            switch kind {
            case .palm(let v): return palmMeshes[v % palmMeshes.count]
            case .bush: return bushMesh
            case .flower: return flowerMesh
            }
        }
        propBatches = props.batches.map { batch in
            var gpu = batch.instances.map { GPUInstance(model: $0.model, tint: V4($0.tint, 1)) }
            let buffer = device.makeBuffer(bytes: &gpu,
                                           length: MemoryLayout<GPUInstance>.stride * gpu.count,
                                           options: .storageModeShared)!
            let maxDistance: Float
            switch batch.kind {
            case .palm: maxDistance = .greatestFiniteMagnitude
            case .bush: maxDistance = 260
            case .flower: maxDistance = 150
            }
            return InstancedBatch(mesh: baseMesh(batch.kind), buffer: buffer,
                                  count: gpu.count, lo: batch.lo, hi: batch.hi,
                                  maxDistance: maxDistance)
        }
        let unit = MeshBuilder()
        unit.sphere(center: .zero, radii: V3(repeating: 1), color: V3(repeating: 1), rings: 14, segs: 24)
        sphere = GPUMesh(device: device, builder: unit)
        boatMesh = GPUMesh(device: device, builder: Boat.buildMesh())
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

        // Water is a clipmap: `Rings * 2` cells across, one ring per octave, and
        // each ring is snapped to its own cell size in world space. Vertices
        // therefore never move — a ring jumps by a cell when the camera crosses
        // one, but the same world points are covered either way, so the waves no
        // longer swim. The local grid is in whole cells and the shader scales it
        // by the level's cell size.
        let n = Renderer.waterCells
        let block = Float(n / 4)
        var grid: [V2] = []
        for j in -(n / 2)...(n / 2) {
            for i in -(n / 2)...(n / 2) {
                grid.append(V2(Float(i), Float(j)))
            }
        }
        var full: [UInt32] = []
        var ring: [UInt32] = []
        let w = UInt32(n + 1)
        for j in 0..<UInt32(n) {
            for i in 0..<UInt32(n) {
                let a = j * w + i, b = a + 1, c = a + w, d = c + 1
                full += [a, c, b, b, c, d]
                // The inner half of a level is covered by the level below it.
                let x = Float(Int(i)) - Float(n / 2)
                let z = Float(Int(j)) - Float(n / 2)
                if abs(x) >= block || abs(z) >= block { ring += [a, c, b, b, c, d] }
            }
        }
        waterGrid = device.makeBuffer(bytes: grid, length: MemoryLayout<V2>.stride * grid.count, options: .storageModeShared)!
        waterIndices = device.makeBuffer(bytes: full, length: MemoryLayout<UInt32>.stride * full.count, options: .storageModeShared)!
        waterRingIndices = device.makeBuffer(bytes: ring, length: MemoryLayout<UInt32>.stride * ring.count, options: .storageModeShared)!
        waterIndexCount = full.count
        waterRingIndexCount = ring.count

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
            setGauge(enc)
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

        // Light view-projection for shadow mapping (orthographic, following the
        // player: one 4096 map cannot cover 600 m of archipelago at this detail).
        let lightVP = lightViewProj()

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
        drawMesh(enc, seaFloor, model: matrix_identity_float4x4, tint: V4(1, 1, 1, 1))
        drawTerrain(enc, viewProj: vp, cam: game.camPos)
        drawMesh(enc, props, model: matrix_identity_float4x4, tint: V4(1, 1, 1, 1))
        enc.setRenderPipelineState(mainInstPSO)
        drawProps(enc, viewProj: vp, cam: game.camPos)
        enc.setRenderPipelineState(mainPSO)
        drawPlayer(enc)
        drawBoats(enc)

        // Water last, blended over everything.
        enc.setRenderPipelineState(waterPSO)
        enc.setDepthStencilState(blendDepth)
        enc.setVertexBuffer(waterGrid, offset: 0, index: 0)
        enc.setFragmentTexture(heightTexture, index: 0)
        // One origin for every level, snapped to the finest cell. Snapping each
        // level to its own cell size would be tighter, but the levels would then
        // disagree about where the coarse ring's hole is and the fine square
        // covers: a strip up to one cell wide would lose its water on one side
        // and double-blend it on the other, and that strip would follow the
        // camera around. A shared origin makes every hole exactly the size of
        // the level below it. The coarse rings can then slide by a metre when
        // the origin steps, which is invisible: the vertex waves have faded out
        // by 300 m and the far rings are flat.
        let ox = game.camPos.x.rounded()
        let oz = game.camPos.z.rounded()
        for level in 0..<Renderer.waterLevels {
            let cell = Float(1 << level)
            var obj = ObjUniforms(model: matrix_identity_float4x4,
                                  normalMat: matrix_identity_float4x4,
                                  tint: V4(ox, oz, cell, 0))
            enc.setVertexBytes(&obj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: level == 0 ? waterIndexCount : waterRingIndexCount,
                                      indexType: .uint32,
                                      indexBuffer: level == 0 ? waterIndices : waterRingIndices,
                                      indexBufferOffset: 0)
        }

        // Spray and foam last: it has to sit over the water surface.
        encodeParticles(enc, view: viewM)
    }

    /// HUD uniforms: water level 0...1, whether the pack is too dry to fire, and
    /// whether the aim currently reaches anything. The shader draws both the bar
    /// and the reticle, so neither needs a pass or any geometry of its own.
    private func setGauge(_ enc: MTLRenderCommandEncoder) {
        var g = V4(clampf(game.tank, 0, 1), game.tankDry ? 1 : 0, game.aimImpact != nil ? 1 : 0, 0)
        enc.setFragmentBytes(&g, length: MemoryLayout<V4>.stride, index: 0)
        var h = HUDText(steps: game.steps, metres: game.distance, calories: game.calories)
        enc.setFragmentBytes(&h, length: MemoryLayout<HUDText>.stride, index: 1)
    }

    /// The activity readout, formatted on the CPU. The shader's font only has to
    /// draw characters, so the digits, the decimal point and the alignment of a
    /// field as it grows all live here.
    private struct HUDText {
        var steps = SIMD4<Int32>(repeating: 0)
        var miles = SIMD4<Int32>(repeating: 0)
        var calories = SIMD4<Int32>(repeating: 0)

        init(steps: Int, metres: Float, calories: Int) {
            // Four cells is all the font is given; a very long session clips the
            // top digit rather than running into the next column.
            let hundredths = min(999, Int(metres / 1609.344 * 100))
            self.steps = HUDText.field("\(min(steps, 9999))", 4)
            self.miles = HUDText.field("\(hundredths / 100).\(String(format: "%02d", hundredths % 100))", 4)
            self.calories = HUDText.field("\(min(calories, 999))", 3)
        }

        /// Right-aligns in `width` cells, blanks on the left, so the number grows
        /// leftwards instead of shoving the unit out of its column.
        private static func field(_ text: String, _ width: Int) -> SIMD4<Int32> {
            var v = SIMD4<Int32>(repeating: 0)
            let codes = text.unicodeScalars.map { $0 == " " ? Int32(0) : Int32($0.value) }.suffix(width)
            let start = width - codes.count
            for (i, c) in codes.enumerated() { v[start + i] = c }
            return v
        }
    }

    private func encodeParticles(_ enc: MTLRenderCommandEncoder, view: M4) {
        let parts = game.particles.parts
        let decals = game.decals
        let goos = game.goos
        // Below the surface the water plane is opaque and would hide the spray,
        // but it writes no depth, so the pass has to be skipped instead.
        guard !parts.isEmpty || !decals.isEmpty || !goos.isEmpty, game.camPos.y > 0 else { return }
        let right = normalize(V3(view.columns.0.x, view.columns.1.x, view.columns.2.x))
        let up = normalize(V3(view.columns.0.y, view.columns.1.y, view.columns.2.y))

        let need = (parts.count + decals.count + goos.count) * 6
        if particleVerts.count < need {
            particleVerts = [Vertex](repeating: Vertex(pos: .zero, nrm: .zero, col: .zero),
                                     count: max(need, 6144))
        }
        var n = 0
        let quad = [V2(-1, -1), V2(1, -1), V2(1, 1), V2(-1, -1), V2(1, 1), V2(-1, 1)]

        /// Flat quad on the ground, laid along the surface normal so it reads as
        /// part of the terrain rather than as a sprite. `kind` picks the mask.
        func ground(_ pos: V3, radius: Float, kind: Float, colour: V3, alpha: Float) {
            let nrm = World.normal(pos.x, pos.z)
            var t = cross(nrm, V3(0, 1, 0))
            if length(t) < 1e-3 { t = V3(1, 0, 0) }
            t = normalize(t)
            let b = normalize(cross(nrm, t))
            let o = pos + nrm * 0.035
            let c = V4(colour, alpha)
            for uv in quad {
                let off = t * (uv.x * radius) + b * (uv.y * radius)
                particleVerts[n] = Vertex(pos: V4(o + off, 1), nrm: V4(uv.x, uv.y, kind, 0), col: c)
                n += 1
            }
        }

        // Order matters: nothing here writes depth, so whatever is emitted last
        // paints over the rest. Goo is in the ground, wet patches lie over it,
        // and the spray itself is over everything.
        for g in goos {
            ground(g.pos, radius: g.radius * (0.45 + 0.55 * clampf(g.health, 0, 1)),
                   kind: 5, colour: V3(0.30, 0.36, 0.14), alpha: 1)
        }
        for d in decals {
            let fade = 0.32 * min(1, d.age * 20) * clampf((d.life - d.age) / 2.0, 0, 1)
            ground(d.pos, radius: d.radius, kind: 4, colour: V3(0.22, 0.34, 0.42), alpha: fade)
        }
        for p in parts {
            // Fade out over the lifetime; foam spreads as it goes, droplets shrink.
            let k = p.life / p.maxLife
            var fade = clampf(k * 5, 0, 1) * (0.30 + 0.70 * k)
            // Foam lies on the water, so it is squashed into an ellipse and
            // faded out at grazing angles. Flat quads were truer in plan view
            // but collapsed into white scratches from eye level.
            let foam = p.kind == 1
            let dust = p.kind == 2
            let spray = p.kind == 3
            if foam { fade *= sstep(0.10, 0.42, abs(dot(normalize(game.camPos - p.pos), V3(0, 1, 0)))) }
            if dust { fade *= 1.15 }
            if spray { fade = clampf(k * 8, 0, 1) * 0.50 }
            let r = p.size * (foam ? 1.7 - 0.6 * k : (dust ? 0.9 + 1.1 * (1 - k) : (spray ? 1.0 : 0.55 + 0.7 * k)))
            let ax: V3
            let ay: V3
            if spray {
                // A round sprite at 26 m/s reads as a bubble, so the streak is
                // stretched along its own screen-space direction of travel.
                let sx = dot(p.vel, right), sy = dot(p.vel, up)
                let l = max(sqrt(sx * sx + sy * sy), 1e-4)
                ax = (right * sx + up * sy) / l * (r * 4.0)
                ay = (right * (sy / l) - up * (sx / l)) * r
            } else {
                ax = right * r
                ay = up * r * (foam ? 0.60 : (dust ? 0.92 : 1.0))
            }
            let c = V4(p.tint * (0.9 + 0.12 * k), fade)
            let kind: Float = foam ? 1 : (dust ? 2 : (spray ? 3 : 0))
            for uv in quad {
                let off = ax * uv.x + ay * uv.y
                particleVerts[n] = Vertex(pos: V4(p.pos + off, 1), nrm: V4(uv.x, uv.y, kind, 0), col: c)
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

    /// Shadow box, `+-90 m` around the player. The centre is snapped to whole
    /// shadow texels along the light's own axes, so the box moves in steps and
    /// the shadows do not crawl across the ground as the player walks.
    private func lightViewProj() -> M4 {
        let r: Float = 90
        let proj = M4.orthographic(left: -r, right: r, bottom: -r, top: r, near: 10, far: 620)
        // A rotation-only light space, so a texel is a fixed size in world units.
        let base = M4.lookAt(eye: sunDir * 300, center: V3(0, 0, 0), up: V3(0, 1, 0))
        let texel = 2 * r / Float(Renderer.shadowMapSize)
        let ls = base * V4(game.pos, 1)
        let snapped = V4((ls.x / texel).rounded() * texel,
                         (ls.y / texel).rounded() * texel,
                         ls.z, 1)
        let centre = V3((base.inverse * snapped).x, (base.inverse * snapped).y, (base.inverse * snapped).z)
        let view = M4.lookAt(eye: centre + sunDir * 300, center: centre, up: V3(0, 1, 0))
        return proj * view
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

        // We only need the lightVP for the shadow vertex shader.
        let lightVP = lightViewProj()
        var frame = FrameUniforms(
            viewProj: lightVP,
            invViewProj: lightVP.inverse,
            cam: V4(0, 0, 0, 0),
            sun: V4(sunDir, 0),
            sunCol: V4(sunColor, 0),
            lightViewProj: lightVP
        )
        enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)

        drawTerrain(enc, viewProj: lightVP, cam: game.pos)
        drawMesh(enc, props, model: matrix_identity_float4x4, tint: V4(1, 1, 1, 1))
        enc.setRenderPipelineState(shadowInstPSO)
        drawProps(enc, viewProj: lightVP, cam: game.pos)
        enc.setRenderPipelineState(shadowMapPSO)
        drawPlayer(enc)
        drawBoats(enc)

        enc.endEncoding()
    }

    /// Terrain is drawn chunk by chunk: one box test each, and the grid is the
    /// whole island, so most of it is behind the camera or past the far plane.
    /// The shadow pass writes these too, and runs first, so what is left when
    /// the frame ends is the scene pass — the one the camera decides.
    private func drawTerrain(_ enc: MTLRenderCommandEncoder, viewProj: M4, cam: V3) {
        let frustum = Frustum(viewProj)
        statsChunks = 0
        statsTriangles = 0
        statsLevels = (0, 0, 0)
        var obj = ObjUniforms(model: matrix_identity_float4x4,
                              normalMat: matrix_identity_float4x4,
                              tint: V4(1, 1, 1, 1))
        enc.setVertexBytes(&obj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
        enc.setVertexBuffer(terrain.vertexBuffer, offset: 0, index: 0)
        for patch in terrainPatches {
            // One test per island before the per-chunk ones: whole islands fall
            // outside the view often enough to be worth the early out.
            guard frustum.contains(patch.lo, patch.hi) else { continue }
            let level = terrainLevel(patch, cam)
            for c in patch.chunks where frustum.contains(c.lo, c.hi) {
                let first: Int, count: Int
                switch level {
                case 0: first = c.firstIndex; count = c.indexCount
                case 1: first = c.coarseFirst; count = c.coarseCount
                default: first = c.farFirst; count = c.farCount
                }
                guard count > 0 else { continue }
                if level == 0 { statsLevels.0 += 1 } else if level == 1 { statsLevels.1 += 1 } else { statsLevels.2 += 1 }
                statsChunks += 1
                statsTriangles += count / 3
                enc.drawIndexedPrimitives(type: .triangle, indexCount: count,
                                          indexType: .uint32, indexBuffer: terrain.indexBuffer,
                                          indexBufferOffset: first * MemoryLayout<UInt32>.stride)
            }
        }
    }

    /// Which index set an island uses. Measured from the nearest point of the
    /// patch box, so a patch the camera is standing on is always full detail
    /// however far its centre is.
    private func terrainLevel(_ patch: World.TerrainPatch, _ cam: V3) -> Int {
        let nx = min(max(cam.x, patch.lo.x), patch.hi.x)
        let nz = min(max(cam.z, patch.lo.z), patch.hi.z)
        let dx = cam.x - nx, dz = cam.z - nz
        let d = (dx * dx + dz * dz).squareRoot()
        if d < 70 { return 0 }
        if d < 190 { return 1 }
        return 2
    }

    /// Props, one instanced draw per batch. The caller sets the pipeline; the
    /// batch box is tested against the same frustum as the terrain chunks, so an
    /// island off screen costs nothing at all.
    private func drawProps(_ enc: MTLRenderCommandEncoder, viewProj: M4, cam: V3) {
        let frustum = Frustum(viewProj)
        statsPropBatches = 0
        statsPropInstances = 0
        for batch in propBatches where frustum.contains(batch.lo, batch.hi) && batch.visibleFrom(cam) {
            statsPropBatches += 1
            statsPropInstances += batch.count
            enc.setVertexBuffer(batch.mesh.vertexBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(batch.buffer, offset: 0, index: 3)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: batch.mesh.indexCount,
                                      indexType: .uint32, indexBuffer: batch.mesh.indexBuffer,
                                      indexBufferOffset: 0, instanceCount: batch.count)
        }
    }

    private func drawMesh(_ enc: MTLRenderCommandEncoder, _ mesh: GPUMesh, model: M4, tint: V4) {
        var obj = ObjUniforms(model: model, normalMat: model.inverse.transpose, tint: tint)
        enc.setVertexBytes(&obj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
        enc.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indexBuffer, indexBufferOffset: 0)
    }

    /// The hull is modelled with +x forward and its keel on y = 0, so the model
    /// is sunk by the draft and turned to the boat's heading. `rotationY` takes
    /// +x to (cos, 0, -sin), hence the quarter turn.
    private func drawBoats(_ enc: MTLRenderCommandEncoder) {
        for b in game.boats {
            let model = M4.translation(V3(b.pos.x, -Boat.draft + b.bob, b.pos.y))
                * M4.rotationY(b.heading - Float.pi / 2)
                * M4.rotationX(b.roll)
            drawMesh(enc, boatMesh, model: model, tint: V4(1, 1, 1, 1))
        }
    }

    private func drawPlayer(_ enc: MTLRenderCommandEncoder) {
        for (model, color) in Player.parts(game.pose, pos: game.pos, facing: game.facing, tank: game.tank) {
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
            setGauge(enc)
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
