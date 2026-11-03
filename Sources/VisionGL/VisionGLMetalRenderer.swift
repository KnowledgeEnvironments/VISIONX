// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Metal)
import Metal

public final class VisionGLMetalFrame: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let texture: MTLTexture
    public let serial: UInt64
    public let context: GLXContextID
    public let drawable: GLXDrawableID
    public let swapSerial: UInt64
    public let drawCallCount: Int
    public let clearCount: Int
    public let transformSignature: Float

    public init(
        width: Int,
        height: Int,
        texture: MTLTexture,
        serial: UInt64,
        context: GLXContextID = 0,
        drawable: GLXDrawableID = 0,
        swapSerial: UInt64 = 0,
        drawCallCount: Int = 0,
        clearCount: Int = 0,
        transformSignature: Float = 0
    ) {
        self.width = width
        self.height = height
        self.texture = texture
        self.serial = serial
        self.context = context
        self.drawable = drawable
        self.swapSerial = swapSerial
        self.drawCallCount = drawCallCount
        self.clearCount = clearCount
        self.transformSignature = transformSignature
    }
}

public enum VisionGLMetalRendererError: Error, Equatable {
    case metalUnavailable
    case shaderLibraryUnavailable
    case pipelineUnavailable
    case commandQueueUnavailable
    case commandBufferUnavailable
    case textureUnavailable
}

public final class VisionGLMetalRenderer: @unchecked Sendable {
    private struct MetalVertex {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
        var normal: SIMD4<Float>
    }

    private struct MetalLightUniform {
        var position: SIMD4<Float>
        var ambient: SIMD4<Float>
        var diffuse: SIMD4<Float>
    }

    private struct MetalUniforms {
        var modelView0: SIMD4<Float>
        var modelView1: SIMD4<Float>
        var modelView2: SIMD4<Float>
        var modelView3: SIMD4<Float>
        var projection0: SIMD4<Float>
        var projection1: SIMD4<Float>
        var projection2: SIMD4<Float>
        var projection3: SIMD4<Float>
        var materialAmbient: SIMD4<Float>
        var materialDiffuse: SIMD4<Float>
        var materialEmission: SIMD4<Float>
        var light0: MetalLightUniform
        var light1: MetalLightUniform
        var light2: MetalLightUniform
        var light3: MetalLightUniform
        var light4: MetalLightUniform
        var light5: MetalLightUniform
        var light6: MetalLightUniform
        var light7: MetalLightUniform
        var lightingEnabled: UInt32
        var lightCount: UInt32
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
    }

    private struct DrawableRenderTargets {
        var width: Int
        var height: Int
        var colorTextures: [MTLTexture]
        var presentationTextures: [MTLTexture]
        var depthTexture: MTLTexture
        var nextTextureIndex: Int = 0
    }

    private struct RenderTargetSelection {
        var colorTexture: MTLTexture
        var presentationTexture: MTLTexture
        var depthTexture: MTLTexture
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let trianglePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let colorTextureRingSize = 24
    private let geometryCacheLimit = 512
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private var renderTargetsByDrawable: [GLXDrawableID: DrawableRenderTargets] = [:]
    private var geometryBuffersByKey: [GLGeometryCacheKey: MTLBuffer] = [:]
    private var serial: UInt64 = 0

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .main),
              let vertexFunction = library.makeFunction(name: "visionGLVertex"),
              let fragmentFunction = library.makeFunction(name: "visionGLFragment") else {
            return nil
        }

        func makePipeline(fillMode: MTLTriangleFillMode) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.vertexDescriptor = nil
            descriptor.label = fillMode == .fill ? "VisionGL triangles" : "VisionGL lines"
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true

        guard let trianglePipeline = try? makePipeline(fillMode: .fill),
              let linePipeline = try? makePipeline(fillMode: .lines),
              let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.trianglePipeline = trianglePipeline
        self.linePipeline = linePipeline
        self.depthState = depthState
    }

    public func render(context: VisionGLContext, drawable: GLXDrawableRecord) throws -> VisionGLMetalFrame {
        let frame = context.frameCommandsSnapshot()
        let metalFrame = try render(frame: frame, drawable: drawable)
        context.clearFrameCommands()
        return metalFrame
    }

    public func render(
        frame: VisionGLFrameCommands,
        drawable: GLXDrawableRecord,
        context: GLXContextID = 0,
        swapSerial: UInt64 = 0,
        waitUntilCompleted: Bool = true,
        completion: (@Sendable (VisionGLMetalFrame) -> Void)? = nil
    ) throws -> VisionGLMetalFrame {
        let width = max(1, drawable.width)
        let height = max(1, drawable.height)
        let limitsInFlight = !waitUntilCompleted
        var submittedToMetal = false
        if limitsInFlight {
            inFlightSemaphore.wait()
        }
        defer {
            if limitsInFlight, !submittedToMetal {
                inFlightSemaphore.signal()
            }
        }

        let targets = try nextRenderTargets(drawable: drawable.id, width: width, height: height)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw VisionGLMetalRendererError.commandBufferUnavailable
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = targets.colorTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = clearColor(for: frame)
        passDescriptor.depthAttachment.texture = targets.depthTexture
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .dontCare
        passDescriptor.depthAttachment.clearDepth = 1

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            throw VisionGLMetalRendererError.commandBufferUnavailable
        }
        encoder.setDepthStencilState(depthState)

        for drawCall in frame.drawCalls {
            encode(drawCall, width: width, height: height, encoder: encoder)
        }

        encoder.endEncoding()

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw VisionGLMetalRendererError.commandBufferUnavailable
        }
        blitEncoder.copy(
            from: targets.colorTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: targets.presentationTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()

        serial &+= 1
        let metalFrame = VisionGLMetalFrame(
            width: width,
            height: height,
            texture: targets.presentationTexture,
            serial: serial,
            context: context,
            drawable: drawable.id,
            swapSerial: swapSerial,
            drawCallCount: frame.drawCalls.count,
            clearCount: frame.clearRequests.count,
            transformSignature: transformSignature(for: frame)
        )
        if limitsInFlight || completion != nil {
            commandBuffer.addCompletedHandler { _ in
                completion?(metalFrame)
                if limitsInFlight {
                    self.inFlightSemaphore.signal()
                }
            }
        }
        commandBuffer.commit()
        submittedToMetal = true
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
        }
        return metalFrame
    }

    public func discardDrawable(_ drawable: GLXDrawableID) {
        renderTargetsByDrawable.removeValue(forKey: drawable)
    }

    public func discardGeometryCache() {
        geometryBuffersByKey.removeAll()
    }

    private func nextRenderTargets(drawable: GLXDrawableID, width: Int, height: Int) throws -> RenderTargetSelection {
        if var targets = renderTargetsByDrawable[drawable],
           targets.width == width,
           targets.height == height,
           !targets.colorTextures.isEmpty,
           targets.colorTextures.count == targets.presentationTextures.count {
            let textureIndex = targets.nextTextureIndex
            let colorTexture = targets.colorTextures[textureIndex]
            let presentationTexture = targets.presentationTextures[textureIndex]
            targets.nextTextureIndex = (textureIndex + 1) % targets.colorTextures.count
            renderTargetsByDrawable[drawable] = targets
            return RenderTargetSelection(
                colorTexture: colorTexture,
                presentationTexture: presentationTexture,
                depthTexture: targets.depthTexture
            )
        }

        var colorTextures: [MTLTexture] = []
        var presentationTextures: [MTLTexture] = []
        colorTextures.reserveCapacity(colorTextureRingSize)
        presentationTextures.reserveCapacity(colorTextureRingSize)
        for _ in 0..<colorTextureRingSize {
            guard let colorTexture = makeColorTexture(width: width, height: height),
                  let presentationTexture = makePresentationTexture(width: width, height: height) else {
                throw VisionGLMetalRendererError.textureUnavailable
            }
            colorTextures.append(colorTexture)
            presentationTextures.append(presentationTexture)
        }
        guard let depthTexture = makeDepthTexture(width: width, height: height) else {
            throw VisionGLMetalRendererError.textureUnavailable
        }

        let targets = DrawableRenderTargets(
            width: width,
            height: height,
            colorTextures: colorTextures,
            presentationTextures: presentationTextures,
            depthTexture: depthTexture,
            nextTextureIndex: 1
        )
        renderTargetsByDrawable[drawable] = targets
        return RenderTargetSelection(
            colorTexture: targets.colorTextures[0],
            presentationTexture: targets.presentationTextures[0],
            depthTexture: depthTexture
        )
    }

    private func makeColorTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func makePresentationTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func makeDepthTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func clearColor(for frame: VisionGLFrameCommands) -> MTLClearColor {
        let color: GLColor = frame.clearRequests.last(where: { ($0.mask & 0x00004000) != 0 })?.color
            ?? GLColor(r: 0, g: 0, b: 0, a: 1)
        return MTLClearColor(
            red: Double(color.r),
            green: Double(color.g),
            blue: Double(color.b),
            alpha: Double(color.a)
        )
    }

    private func transformSignature(for frame: VisionGLFrameCommands) -> Float {
        var signature: Float = 0
        var drawWeight: Float = 1
        for drawCall in frame.drawCalls.prefix(4) {
            signature += matrixSignature(drawCall.modelViewMatrix, weight: drawWeight)
            signature += matrixSignature(drawCall.projectionMatrix, weight: drawWeight * 0.25)
            drawWeight += 1
        }
        return signature
    }

    private func matrixSignature(_ matrix: Matrix4, weight: Float) -> Float {
        var signature: Float = 0
        for (index, value) in matrix.storage.enumerated() {
            signature += value * Float((index % 7) + 1)
        }
        return signature * weight
    }

    private func encode(_ drawCall: ImmediateDrawCall, width: Int, height: Int, encoder: MTLRenderCommandEncoder) {
        switch drawCall.primitive {
        case .points:
            encodePoints(drawCall, width: width, height: height, encoder: encoder)
        case .lines:
            encodeLines(pairVertices(drawCall.vertices), drawCall: drawCall, width: width, height: height, encoder: encoder)
        case .lineLoop:
            encodeLines(lineLoopVertices(drawCall.vertices), drawCall: drawCall, width: width, height: height, encoder: encoder)
        case .lineStrip:
            encodeLines(lineStripVertices(drawCall.vertices), drawCall: drawCall, width: width, height: height, encoder: encoder)
        case .triangles:
            encodeTriangles(drawCall.vertices, drawCall: drawCall, width: width, height: height, geometryCacheKey: drawCall.geometryCacheKey, encoder: encoder)
        case .triangleStrip:
            encodeTriangleStrip(drawCall.vertices, drawCall: drawCall, geometryCacheKey: drawCall.geometryCacheKey, encoder: encoder)
        case .triangleFan:
            encodeTriangles(triangleFanVertices(drawCall.vertices), drawCall: drawCall, width: width, height: height, encoder: encoder)
        case .quads:
            encodeTriangles(quadVertices(drawCall.vertices), drawCall: drawCall, width: width, height: height, encoder: encoder)
        case .quadStrip:
            encodeTriangleStrip(drawCall.vertices, drawCall: drawCall, geometryCacheKey: drawCall.geometryCacheKey, encoder: encoder)
        case .polygon:
            encodeTriangles(triangleFanVertices(drawCall.vertices), drawCall: drawCall, width: width, height: height, encoder: encoder)
        }
    }

    private func encodePoints(_ drawCall: ImmediateDrawCall, width: Int, height: Int, encoder: MTLRenderCommandEncoder) {
        encodeTriangles(pointQuadVertices(drawCall.vertices, size: 2), drawCall: drawCall, width: width, height: height, encoder: encoder)
    }

    private func encodeLines(_ vertices: [GLVertex], drawCall: ImmediateDrawCall, width: Int, height: Int, encoder: MTLRenderCommandEncoder) {
        guard !vertices.isEmpty else {
            return
        }
        var uniforms = metalUniforms(for: drawCall)
        encoder.setRenderPipelineState(linePipeline)
        if let vertexBuffer = cachedVertexBuffer(for: vertices) {
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
        } else {
            let metalVertices = vertices.map(metalVertex)
            metalVertices.withUnsafeBytes { buffer in
                encoder.setVertexBytes(buffer.baseAddress!, length: buffer.count, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: metalVertices.count)
            }
        }
    }

    private func encodeTriangles(
        _ vertices: [GLVertex],
        drawCall: ImmediateDrawCall,
        width: Int,
        height: Int,
        geometryCacheKey: GLGeometryCacheKey? = nil,
        encoder: MTLRenderCommandEncoder
    ) {
        guard !vertices.isEmpty else {
            return
        }
        var uniforms = metalUniforms(for: drawCall)
        encoder.setRenderPipelineState(trianglePipeline)
        if let vertexBuffer = cachedVertexBuffer(for: vertices, geometryCacheKey: geometryCacheKey) {
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        } else {
            let metalVertices = vertices.map(metalVertex)
            metalVertices.withUnsafeBytes { buffer in
                encoder.setVertexBytes(buffer.baseAddress!, length: buffer.count, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: metalVertices.count)
            }
        }
    }

    private func encodeTriangleStrip(
        _ vertices: [GLVertex],
        drawCall: ImmediateDrawCall,
        geometryCacheKey: GLGeometryCacheKey?,
        encoder: MTLRenderCommandEncoder
    ) {
        guard vertices.count >= 3 else {
            return
        }
        var uniforms = metalUniforms(for: drawCall)
        encoder.setRenderPipelineState(trianglePipeline)
        if let vertexBuffer = cachedVertexBuffer(for: vertices, geometryCacheKey: geometryCacheKey) {
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        } else {
            let metalVertices = vertices.map(metalVertex)
            metalVertices.withUnsafeBytes { buffer in
                encoder.setVertexBytes(buffer.baseAddress!, length: buffer.count, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: metalVertices.count)
            }
        }
    }

    private func cachedVertexBuffer(for vertices: [GLVertex], geometryCacheKey: GLGeometryCacheKey? = nil) -> MTLBuffer? {
        let byteCount = vertices.count * MemoryLayout<MetalVertex>.stride
        guard byteCount > 0 else {
            return nil
        }

        let key = geometryCacheKey ?? GLGeometryCacheKey(vertices: vertices)
        if let buffer = geometryBuffersByKey[key] {
            return buffer
        }

        if geometryBuffersByKey.count >= geometryCacheLimit {
            geometryBuffersByKey.removeAll(keepingCapacity: true)
        }

        let metalVertices = vertices.map(metalVertex)
        let buffer = metalVertices.withUnsafeBytes { rawBuffer in
            device.makeBuffer(bytes: rawBuffer.baseAddress!, length: rawBuffer.count)
        }
        if let buffer {
            geometryBuffersByKey[key] = buffer
        }
        return buffer
    }

    private func metalVertex(_ vertex: GLVertex) -> MetalVertex {
        MetalVertex(
            position: vertex.position,
            color: SIMD4<Float>(vertex.color.r, vertex.color.g, vertex.color.b, vertex.color.a),
            normal: SIMD4<Float>(vertex.normal.x, vertex.normal.y, vertex.normal.z, 0)
        )
    }

    private func metalUniforms(for drawCall: ImmediateDrawCall) -> MetalUniforms {
        let state = drawCall.stateSnapshot
        let ambient = materialColor(state: state, parameter: 0x1200, fallback: SIMD4<Float>(0.2, 0.2, 0.2, 1))
        let diffuse = materialColor(state: state, parameter: 0x1201, fallback: SIMD4<Float>(0.8, 0.8, 0.8, 1))
        let emission = materialColor(state: state, parameter: 0x1600, fallback: SIMD4<Float>(0, 0, 0, 1))

        let enabledLights = state.enabledCapabilities.compactMap { capability -> UInt32? in
            if case .light(let index) = capability {
                return index
            }
            return nil
        }.sorted()

        let lightIndices = state.enabledCapabilities.contains(.lighting)
            ? Array((enabledLights.isEmpty ? [UInt32(0)] : enabledLights).prefix(8))
            : []
        let lights = lightIndices.map { metalLight(state: state, lightIndex: $0) }
        let emptyLight = MetalLightUniform(
            position: SIMD4<Float>(0, 0, 1, 0),
            ambient: SIMD4<Float>(0, 0, 0, 1),
            diffuse: SIMD4<Float>(0, 0, 0, 1)
        )
        let modelView = matrixColumns(drawCall.modelViewMatrix)
        let projection = matrixColumns(drawCall.projectionMatrix)
        return MetalUniforms(
            modelView0: modelView.0,
            modelView1: modelView.1,
            modelView2: modelView.2,
            modelView3: modelView.3,
            projection0: projection.0,
            projection1: projection.1,
            projection2: projection.2,
            projection3: projection.3,
            materialAmbient: ambient,
            materialDiffuse: diffuse,
            materialEmission: emission,
            light0: lights.indices.contains(0) ? lights[0] : emptyLight,
            light1: lights.indices.contains(1) ? lights[1] : emptyLight,
            light2: lights.indices.contains(2) ? lights[2] : emptyLight,
            light3: lights.indices.contains(3) ? lights[3] : emptyLight,
            light4: lights.indices.contains(4) ? lights[4] : emptyLight,
            light5: lights.indices.contains(5) ? lights[5] : emptyLight,
            light6: lights.indices.contains(6) ? lights[6] : emptyLight,
            light7: lights.indices.contains(7) ? lights[7] : emptyLight,
            lightingEnabled: state.enabledCapabilities.contains(.lighting) ? 1 : 0,
            lightCount: UInt32(lights.count)
        )
    }

    private func metalLight(state: FixedFunctionState, lightIndex: UInt32) -> MetalLightUniform {
        let lightEnum = 0x4000 + lightIndex
        let values = state.lightParameters[GLLightStateKey(light: lightEnum, parameter: 0x1203)] ?? [0, 0, 1, 0]
        let position = SIMD4<Float>(
            values.indices.contains(0) ? values[0] : 0,
            values.indices.contains(1) ? values[1] : 0,
            values.indices.contains(2) ? values[2] : 1,
            values.indices.contains(3) ? values[3] : 0
        )
        return MetalLightUniform(
            position: position,
            ambient: lightColor(
                state: state,
                light: lightEnum,
                parameter: 0x1200,
                fallback: SIMD4<Float>(0, 0, 0, 1)
            ),
            diffuse: lightColor(
                state: state,
                light: lightEnum,
                parameter: 0x1201,
                fallback: lightIndex == 0 ? SIMD4<Float>(1, 1, 1, 1) : SIMD4<Float>(0, 0, 0, 1)
            )
        )
    }

    private func matrixColumns(_ matrix: Matrix4) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        (
            SIMD4<Float>(matrix[0, 0], matrix[1, 0], matrix[2, 0], matrix[3, 0]),
            SIMD4<Float>(matrix[0, 1], matrix[1, 1], matrix[2, 1], matrix[3, 1]),
            SIMD4<Float>(matrix[0, 2], matrix[1, 2], matrix[2, 2], matrix[3, 2]),
            SIMD4<Float>(matrix[0, 3], matrix[1, 3], matrix[2, 3], matrix[3, 3])
        )
    }

    private func materialColor(state: FixedFunctionState, parameter: UInt32, fallback: SIMD4<Float>) -> SIMD4<Float> {
        if let values = state.materialParameters[GLMaterialStateKey(face: 0x0404, parameter: parameter)] {
            return color(values, fallback: fallback)
        }
        if let values = state.materialParameters[GLMaterialStateKey(face: 0x0408, parameter: parameter)] {
            return color(values, fallback: fallback)
        }
        if parameter == 0x1200 || parameter == 0x1201 {
            if let values = state.materialParameters[GLMaterialStateKey(face: 0x0404, parameter: 0x1602)] {
                return color(values, fallback: fallback)
            }
            if let values = state.materialParameters[GLMaterialStateKey(face: 0x0408, parameter: 0x1602)] {
                return color(values, fallback: fallback)
            }
        }
        if state.enabledCapabilities.contains(.colorMaterial), parameter == 0x1201 {
            return SIMD4<Float>(state.currentColor.r, state.currentColor.g, state.currentColor.b, state.currentColor.a)
        }
        return fallback
    }

    private func lightColor(state: FixedFunctionState, light: UInt32, parameter: UInt32, fallback: SIMD4<Float>) -> SIMD4<Float> {
        guard let values = state.lightParameters[GLLightStateKey(light: light, parameter: parameter)] else {
            return fallback
        }
        return color(values, fallback: fallback)
    }

    private func vectorToLight(state: FixedFunctionState, light: UInt32, position: SIMD4<Float>) -> SIMD3<Float> {
        let values = state.lightParameters[GLLightStateKey(light: light, parameter: 0x1203)] ?? [0, 0, 1, 0]
        let lightPosition = SIMD4<Float>(
            values.indices.contains(0) ? values[0] : 0,
            values.indices.contains(1) ? values[1] : 0,
            values.indices.contains(2) ? values[2] : 1,
            values.indices.contains(3) ? values[3] : 0
        )
        if lightPosition.w == 0 {
            return normalize(SIMD3<Float>(lightPosition.x, lightPosition.y, lightPosition.z), fallback: SIMD3<Float>(0, 0, 1))
        }
        return normalize(
            SIMD3<Float>(lightPosition.x - position.x, lightPosition.y - position.y, lightPosition.z - position.z),
            fallback: SIMD3<Float>(0, 0, 1)
        )
    }

    private func transformedNormal(_ normal: SIMD3<Float>, modelView: Matrix4) -> SIMD3<Float> {
        normalize(
            SIMD3<Float>(
                modelView[0, 0] * normal.x + modelView[0, 1] * normal.y + modelView[0, 2] * normal.z,
                modelView[1, 0] * normal.x + modelView[1, 1] * normal.y + modelView[1, 2] * normal.z,
                modelView[2, 0] * normal.x + modelView[2, 1] * normal.y + modelView[2, 2] * normal.z
            ),
            fallback: SIMD3<Float>(0, 0, 1)
        )
    }

    private func color(_ values: [Float], fallback: SIMD4<Float>) -> SIMD4<Float> {
        guard !values.isEmpty else {
            return fallback
        }
        return SIMD4<Float>(
            values.indices.contains(0) ? values[0] : fallback.x,
            values.indices.contains(1) ? values[1] : fallback.y,
            values.indices.contains(2) ? values[2] : fallback.z,
            values.indices.contains(3) ? values[3] : fallback.w
        )
    }

    private func normalize(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
        guard length > 0, length.isFinite else {
            return fallback
        }
        return vector / length
    }

    private func dot(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private func clamp(_ value: Float) -> Float {
        min(1, max(0, value))
    }

    private func pairVertices(_ vertices: [GLVertex]) -> [GLVertex] {
        Array(vertices.prefix(vertices.count - vertices.count % 2))
    }

    private func lineStripVertices(_ vertices: [GLVertex]) -> [GLVertex] {
        guard vertices.count >= 2 else {
            return []
        }
        var result: [GLVertex] = []
        for index in 0..<(vertices.count - 1) {
            result.append(vertices[index])
            result.append(vertices[index + 1])
        }
        return result
    }

    private func lineLoopVertices(_ vertices: [GLVertex]) -> [GLVertex] {
        guard vertices.count >= 2 else {
            return []
        }
        var result = lineStripVertices(vertices)
        result.append(vertices[vertices.count - 1])
        result.append(vertices[0])
        return result
    }

    private func triangleFanVertices(_ vertices: [GLVertex]) -> [GLVertex] {
        guard vertices.count >= 3 else {
            return []
        }
        var result: [GLVertex] = []
        for index in 1..<(vertices.count - 1) {
            result += [vertices[0], vertices[index], vertices[index + 1]]
        }
        return result
    }

    private func quadVertices(_ vertices: [GLVertex]) -> [GLVertex] {
        var result: [GLVertex] = []
        for index in stride(from: 0, to: vertices.count - vertices.count % 4, by: 4) {
            result += [vertices[index], vertices[index + 1], vertices[index + 2]]
            result += [vertices[index], vertices[index + 2], vertices[index + 3]]
        }
        return result
    }

    private func pointQuadVertices(_ vertices: [GLVertex], size: Float) -> [GLVertex] {
        vertices.flatMap { vertex in
            [
                offset(vertex, x: -size, y: -size),
                offset(vertex, x: size, y: -size),
                offset(vertex, x: size, y: size),
                offset(vertex, x: -size, y: -size),
                offset(vertex, x: size, y: size),
                offset(vertex, x: -size, y: size)
            ]
        }
    }

    private func offset(_ vertex: GLVertex, x: Float, y: Float) -> GLVertex {
        var copy = vertex
        copy.position.x += x
        copy.position.y += y
        return copy
    }
}

#endif
