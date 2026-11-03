// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation

public enum GLMatrixMode: Equatable, Sendable {
    case modelView
    case projection
    case texture
}

public enum GLCapability: Hashable, Sendable {
    case alphaTest
    case autoNormal
    case blend
    case clipPlane(UInt32)
    case colorMaterial
    case cullFace
    case depthTest
    case dither
    case fog
    case light(UInt32)
    case lighting
    case lineSmooth
    case lineStipple
    case normalize
    case pointSmooth
    case polygonOffsetFill
    case polygonSmooth
    case polygonStipple
    case rescaleNormal
    case scissorTest
    case stencilTest
    case texture1D
    case texture2D
}

public enum GLShadeModel: UInt32, Equatable, Sendable {
    case flat = 0x1d00
    case smooth = 0x1d01
}

public enum GLPrimitive: String, Hashable, Sendable {
    case points
    case lines
    case lineLoop
    case lineStrip
    case triangles
    case triangleStrip
    case triangleFan
    case quads
    case quadStrip
    case polygon
}

public struct GLColor: Equatable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

public struct GLViewport: Equatable, Sendable {
    public var x: Int32
    public var y: Int32
    public var width: Int32
    public var height: Int32

    public init(x: Int32 = 0, y: Int32 = 0, width: Int32 = 1, height: Int32 = 1) {
        self.x = x
        self.y = y
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public struct GLVertex: Equatable, Sendable {
    public var position: SIMD4<Float>
    public var color: GLColor
    public var normal: SIMD3<Float>
    public var textureCoordinate: SIMD2<Float>

    public init(
        position: SIMD4<Float>,
        color: GLColor,
        normal: SIMD3<Float>,
        textureCoordinate: SIMD2<Float>
    ) {
        self.position = position
        self.color = color
        self.normal = normal
        self.textureCoordinate = textureCoordinate
    }
}

struct GLGeometryCacheKey: Hashable, Sendable {
    var vertexCount: Int = 0
    var digest: UInt64 = 0xcbf29ce484222325
    var firstPositionX: UInt32 = 0
    var firstPositionY: UInt32 = 0
    var firstPositionZ: UInt32 = 0
    var lastPositionX: UInt32 = 0
    var lastPositionY: UInt32 = 0
    var lastPositionZ: UInt32 = 0

    init() {}

    init(vertices: [GLVertex]) {
        for vertex in vertices {
            append(vertex)
        }
    }

    mutating func append(_ vertex: GLVertex) {
        if vertexCount == 0 {
            firstPositionX = vertex.position.x.bitPattern
            firstPositionY = vertex.position.y.bitPattern
            firstPositionZ = vertex.position.z.bitPattern
        }
        vertexCount += 1
        lastPositionX = vertex.position.x.bitPattern
        lastPositionY = vertex.position.y.bitPattern
        lastPositionZ = vertex.position.z.bitPattern

        mix(vertex.position.x.bitPattern)
        mix(vertex.position.y.bitPattern)
        mix(vertex.position.z.bitPattern)
        mix(vertex.position.w.bitPattern)
        mix(vertex.color.r.bitPattern)
        mix(vertex.color.g.bitPattern)
        mix(vertex.color.b.bitPattern)
        mix(vertex.color.a.bitPattern)
        mix(vertex.normal.x.bitPattern)
        mix(vertex.normal.y.bitPattern)
        mix(vertex.normal.z.bitPattern)
    }

    private mutating func mix(_ value: UInt32) {
        digest ^= UInt64(value)
        digest &*= 0x100000001b3
    }
}

public struct ImmediateDrawCall: Equatable, Sendable {
    public var primitive: GLPrimitive
    public var vertices: [GLVertex]
    public var pipelineKey: VisionGLPipelineKey
    public var modelViewMatrix: Matrix4
    public var projectionMatrix: Matrix4
    public var viewport: GLViewport
    public var stateSnapshot: FixedFunctionState
    var geometryCacheKey: GLGeometryCacheKey?

    public init(
        primitive: GLPrimitive,
        vertices: [GLVertex],
        pipelineKey: VisionGLPipelineKey,
        modelViewMatrix: Matrix4,
        projectionMatrix: Matrix4,
        viewport: GLViewport,
        stateSnapshot: FixedFunctionState
    ) {
        self.init(
            primitive: primitive,
            vertices: vertices,
            pipelineKey: pipelineKey,
            modelViewMatrix: modelViewMatrix,
            projectionMatrix: projectionMatrix,
            viewport: viewport,
            stateSnapshot: stateSnapshot,
            geometryCacheKey: nil
        )
    }

    init(
        primitive: GLPrimitive,
        vertices: [GLVertex],
        pipelineKey: VisionGLPipelineKey,
        modelViewMatrix: Matrix4,
        projectionMatrix: Matrix4,
        viewport: GLViewport,
        stateSnapshot: FixedFunctionState,
        geometryCacheKey: GLGeometryCacheKey?
    ) {
        self.primitive = primitive
        self.vertices = vertices
        self.pipelineKey = pipelineKey
        self.modelViewMatrix = modelViewMatrix
        self.projectionMatrix = projectionMatrix
        self.viewport = viewport
        self.stateSnapshot = stateSnapshot
        self.geometryCacheKey = geometryCacheKey
    }
}

public struct GLClearRequest: Equatable, Sendable {
    public var mask: UInt32
    public var color: GLColor

    public init(mask: UInt32, color: GLColor) {
        self.mask = mask
        self.color = color
    }
}

public struct VisionGLFrameCommands: Equatable, Sendable {
    public var drawCalls: [ImmediateDrawCall]
    public var clearRequests: [GLClearRequest]

    public init(drawCalls: [ImmediateDrawCall], clearRequests: [GLClearRequest]) {
        self.drawCalls = drawCalls
        self.clearRequests = clearRequests
    }
}

public struct GLLightStateKey: Hashable, Sendable {
    public var light: UInt32
    public var parameter: UInt32

    public init(light: UInt32, parameter: UInt32) {
        self.light = light
        self.parameter = parameter
    }
}

public struct GLMaterialStateKey: Hashable, Sendable {
    public var face: UInt32
    public var parameter: UInt32

    public init(face: UInt32, parameter: UInt32) {
        self.face = face
        self.parameter = parameter
    }
}

public enum GLDisplayListMode: UInt32, Equatable, Sendable {
    case compile = 0x1300
    case compileAndExecute = 0x1301
}

public struct GLDisplayListCommand: Equatable, Sendable {
    public var bytes: [UInt8]
    public var byteOrder: GLXRenderByteOrder
    var compiled: GLCompiledDisplayListCommand?

    public init(bytes: [UInt8], byteOrder: GLXRenderByteOrder) {
        self.bytes = bytes
        self.byteOrder = byteOrder
        self.compiled = GLCompiledDisplayListCommand(bytes: bytes, byteOrder: byteOrder)
    }

    public var opcode: UInt16? {
        guard bytes.count >= 4 else {
            return nil
        }
        switch byteOrder {
        case .littleEndian:
            return UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        case .bigEndian:
            return (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        }
    }

    public var isDrawOrNestedListCommand: Bool {
        guard let opcode else {
            return false
        }
        switch opcode {
        case 1, 2, 4, 23, 65...76:
            return true
        default:
            return false
        }
    }
}

struct GLDisplayListDrawTemplate: Equatable, Sendable {
    var primitive: GLPrimitive
    var vertices: [GLVertex]
    var geometryCacheKey: GLGeometryCacheKey
    var finalColor: GLColor
    var finalNormal: SIMD3<Float>
    var finalTextureCoordinate: SIMD2<Float>
    var usesReplayCurrentColor: Bool
    var usesReplayCurrentNormal: Bool
    var setsCurrentColor: Bool
    var setsCurrentNormal: Bool
    var replayCurrentColorVertexIndices: [Int]
    var replayCurrentNormalVertexIndices: [Int]
    var commandCount: Int
}

enum GLDisplayListExecutionStep: Equatable, Sendable {
    case command(GLDisplayListCommand)
    case drawTemplate(GLDisplayListDrawTemplate, fallback: [GLDisplayListCommand])
}

struct GLDisplayListDrawTemplateFallbackReasons: OptionSet, Sendable {
    let rawValue: Int

    static let currentColor = GLDisplayListDrawTemplateFallbackReasons(rawValue: 1 << 0)
    static let currentNormal = GLDisplayListDrawTemplateFallbackReasons(rawValue: 1 << 1)
}

private struct GLDynamicTemplateVertexCacheKey: Hashable {
    var geometryCacheKey: GLGeometryCacheKey
    var colorIndexDigest: UInt64
    var normalIndexDigest: UInt64
    var replayColorR: UInt32
    var replayColorG: UInt32
    var replayColorB: UInt32
    var replayColorA: UInt32
    var replayNormalX: UInt32
    var replayNormalY: UInt32
    var replayNormalZ: UInt32

    init(template: GLDisplayListDrawTemplate, replayColor: GLColor, replayNormal: SIMD3<Float>) {
        self.geometryCacheKey = template.geometryCacheKey
        self.colorIndexDigest = Self.indexDigest(template.replayCurrentColorVertexIndices)
        self.normalIndexDigest = Self.indexDigest(template.replayCurrentNormalVertexIndices)
        if template.replayCurrentColorVertexIndices.isEmpty {
            self.replayColorR = 0
            self.replayColorG = 0
            self.replayColorB = 0
            self.replayColorA = 0
        } else {
            self.replayColorR = replayColor.r.bitPattern
            self.replayColorG = replayColor.g.bitPattern
            self.replayColorB = replayColor.b.bitPattern
            self.replayColorA = replayColor.a.bitPattern
        }
        if template.replayCurrentNormalVertexIndices.isEmpty {
            self.replayNormalX = 0
            self.replayNormalY = 0
            self.replayNormalZ = 0
        } else {
            self.replayNormalX = replayNormal.x.bitPattern
            self.replayNormalY = replayNormal.y.bitPattern
            self.replayNormalZ = replayNormal.z.bitPattern
        }
    }

    private static func indexDigest(_ indices: [Int]) -> UInt64 {
        var digest: UInt64 = 0xcbf29ce484222325
        for index in indices {
            digest ^= UInt64(bitPattern: Int64(index))
            digest &*= 0x100000001b3
        }
        return digest
    }
}

private struct GLDynamicTemplateVertexCacheEntry {
    var vertices: [GLVertex]
    var geometryCacheKey: GLGeometryCacheKey
}

enum GLCompiledDisplayListCommand: Equatable, Sendable {
    case begin(GLPrimitive)
    case end
    case color(GLColor)
    case normal(SIMD3<Float>)
    case vertex(SIMD4<Float>)
    case material(face: UInt32, parameter: UInt32, values: [Float])
    case shadeModel(GLShadeModel)

    init?(bytes: [UInt8], byteOrder: GLXRenderByteOrder) {
        guard bytes.count >= 4 else {
            return nil
        }
        let length = Self.readUInt16(bytes, at: 0, byteOrder: byteOrder)
        let opcode = Self.readUInt16(bytes, at: 2, byteOrder: byteOrder)
        guard length >= 4, length % 4 == 0, Int(length) == bytes.count else {
            return nil
        }

        switch opcode {
        case 4:
            guard bytes.count >= 8,
                  let primitive = Self.primitive(Self.readUInt32(bytes, at: 4, byteOrder: byteOrder)) else {
                return nil
            }
            self = .begin(primitive)
        case 8:
            guard bytes.count >= 16 else {
                return nil
            }
            self = .color(
                GLColor(
                    r: Self.readFloat32(bytes, at: 4, byteOrder: byteOrder),
                    g: Self.readFloat32(bytes, at: 8, byteOrder: byteOrder),
                    b: Self.readFloat32(bytes, at: 12, byteOrder: byteOrder),
                    a: 1
                )
            )
        case 16:
            guard bytes.count >= 20 else {
                return nil
            }
            self = .color(
                GLColor(
                    r: Self.readFloat32(bytes, at: 4, byteOrder: byteOrder),
                    g: Self.readFloat32(bytes, at: 8, byteOrder: byteOrder),
                    b: Self.readFloat32(bytes, at: 12, byteOrder: byteOrder),
                    a: Self.readFloat32(bytes, at: 16, byteOrder: byteOrder)
                )
            )
        case 19:
            guard bytes.count >= 8 else {
                return nil
            }
            self = .color(
                GLColor(
                    r: Float(bytes[4]) / 255,
                    g: Float(bytes[5]) / 255,
                    b: Float(bytes[6]) / 255,
                    a: Float(bytes[7]) / 255
                )
            )
        case 23:
            self = .end
        case 30:
            guard bytes.count >= 16 else {
                return nil
            }
            self = .normal(
                SIMD3<Float>(
                    Self.readFloat32(bytes, at: 4, byteOrder: byteOrder),
                    Self.readFloat32(bytes, at: 8, byteOrder: byteOrder),
                    Self.readFloat32(bytes, at: 12, byteOrder: byteOrder)
                )
            )
        case 32:
            guard bytes.count >= 10 else {
                return nil
            }
            self = .normal(
                SIMD3<Float>(
                    Float(Self.readInt16(bytes, at: 4, byteOrder: byteOrder)),
                    Float(Self.readInt16(bytes, at: 6, byteOrder: byteOrder)),
                    Float(Self.readInt16(bytes, at: 8, byteOrder: byteOrder))
                )
            )
        case 66:
            guard bytes.count >= 12 else {
                return nil
            }
            self = .vertex(
                SIMD4<Float>(
                    Self.readFloat32(bytes, at: 4, byteOrder: byteOrder),
                    Self.readFloat32(bytes, at: 8, byteOrder: byteOrder),
                    0,
                    1
                )
            )
        case 68:
            guard bytes.count >= 8 else {
                return nil
            }
            self = .vertex(
                SIMD4<Float>(
                    Float(Self.readInt16(bytes, at: 4, byteOrder: byteOrder)),
                    Float(Self.readInt16(bytes, at: 6, byteOrder: byteOrder)),
                    0,
                    1
                )
            )
        case 70:
            guard bytes.count >= 16 else {
                return nil
            }
            self = .vertex(
                SIMD4<Float>(
                    Self.readFloat32(bytes, at: 4, byteOrder: byteOrder),
                    Self.readFloat32(bytes, at: 8, byteOrder: byteOrder),
                    Self.readFloat32(bytes, at: 12, byteOrder: byteOrder),
                    1
                )
            )
        case 72:
            guard bytes.count >= 10 else {
                return nil
            }
            self = .vertex(
                SIMD4<Float>(
                    Float(Self.readInt16(bytes, at: 4, byteOrder: byteOrder)),
                    Float(Self.readInt16(bytes, at: 6, byteOrder: byteOrder)),
                    Float(Self.readInt16(bytes, at: 8, byteOrder: byteOrder)),
                    1
                )
            )
        case 74:
            guard bytes.count >= 20 else {
                return nil
            }
            self = .vertex(
                SIMD4<Float>(
                    Self.readFloat32(bytes, at: 4, byteOrder: byteOrder),
                    Self.readFloat32(bytes, at: 8, byteOrder: byteOrder),
                    Self.readFloat32(bytes, at: 12, byteOrder: byteOrder),
                    Self.readFloat32(bytes, at: 16, byteOrder: byteOrder)
                )
            )
        case 76:
            guard bytes.count >= 12 else {
                return nil
            }
            self = .vertex(
                SIMD4<Float>(
                    Float(Self.readInt16(bytes, at: 4, byteOrder: byteOrder)),
                    Float(Self.readInt16(bytes, at: 6, byteOrder: byteOrder)),
                    Float(Self.readInt16(bytes, at: 8, byteOrder: byteOrder)),
                    Float(Self.readInt16(bytes, at: 10, byteOrder: byteOrder))
                )
            )
        case 96:
            guard bytes.count >= 16 else {
                return nil
            }
            self = .material(
                face: Self.readUInt32(bytes, at: 4, byteOrder: byteOrder),
                parameter: Self.readUInt32(bytes, at: 8, byteOrder: byteOrder),
                values: [Self.readFloat32(bytes, at: 12, byteOrder: byteOrder)]
            )
        case 97:
            guard bytes.count >= 16 else {
                return nil
            }
            self = .material(
                face: Self.readUInt32(bytes, at: 4, byteOrder: byteOrder),
                parameter: Self.readUInt32(bytes, at: 8, byteOrder: byteOrder),
                values: Self.float32Values(bytes, offset: 12, byteOrder: byteOrder)
            )
        case 104:
            guard bytes.count >= 8,
                  let model = GLShadeModel(rawValue: Self.readUInt32(bytes, at: 4, byteOrder: byteOrder)) else {
                return nil
            }
            self = .shadeModel(model)
        default:
            return nil
        }
    }

    private static func primitive(_ value: UInt32) -> GLPrimitive? {
        switch value {
        case 0x0000: return .points
        case 0x0001: return .lines
        case 0x0002: return .lineLoop
        case 0x0003: return .lineStrip
        case 0x0004: return .triangles
        case 0x0005: return .triangleStrip
        case 0x0006: return .triangleFan
        case 0x0007: return .quads
        case 0x0008: return .quadStrip
        case 0x0009: return .polygon
        default: return nil
        }
    }

    private static func float32Values(_ bytes: [UInt8], offset: Int, byteOrder: GLXRenderByteOrder) -> [Float] {
        guard offset < bytes.count else {
            return []
        }
        var values: [Float] = []
        values.reserveCapacity((bytes.count - offset) / 4)
        var cursor = offset
        while cursor + 4 <= bytes.count {
            values.append(readFloat32(bytes, at: cursor, byteOrder: byteOrder))
            cursor += 4
        }
        return values
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int, byteOrder: GLXRenderByteOrder) -> UInt16 {
        let b0 = UInt16(bytes[offset])
        let b1 = UInt16(bytes[offset + 1])
        switch byteOrder {
        case .littleEndian:
            return b0 | (b1 << 8)
        case .bigEndian:
            return (b0 << 8) | b1
        }
    }

    private static func readInt16(_ bytes: [UInt8], at offset: Int, byteOrder: GLXRenderByteOrder) -> Int16 {
        Int16(bitPattern: readUInt16(bytes, at: offset, byteOrder: byteOrder))
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int, byteOrder: GLXRenderByteOrder) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            let byte = UInt32(bytes[offset + i])
            switch byteOrder {
            case .littleEndian:
                value |= byte << UInt32(i * 8)
            case .bigEndian:
                value |= byte << UInt32((3 - i) * 8)
            }
        }
        return value
    }

    private static func readFloat32(_ bytes: [UInt8], at offset: Int, byteOrder: GLXRenderByteOrder) -> Float {
        Float(bitPattern: readUInt32(bytes, at: offset, byteOrder: byteOrder))
    }
}

public struct GLDisplayList: Equatable, Sendable {
    public var id: UInt32
    public var commands: [GLDisplayListCommand]
    public var containsDrawCommands: Bool
    var executionSteps: [GLDisplayListExecutionStep]

    public init(id: UInt32, commands: [GLDisplayListCommand], containsDrawCommands: Bool? = nil) {
        self.id = id
        self.commands = commands
        self.executionSteps = GLDisplayListCompiler.executionSteps(for: commands)
        self.containsDrawCommands = containsDrawCommands ?? commands.contains { $0.isDrawOrNestedListCommand }
    }
}

private enum GLDisplayListCompiler {
    static func executionSteps(for commands: [GLDisplayListCommand]) -> [GLDisplayListExecutionStep] {
        var steps: [GLDisplayListExecutionStep] = []
        steps.reserveCapacity(commands.count)

        var index = commands.startIndex
        while index < commands.endIndex {
            guard let block = drawTemplate(startingAt: index, commands: commands) else {
                steps.append(.command(commands[index]))
                index += 1
                continue
            }

            steps.append(.drawTemplate(block.template, fallback: block.commands))
            index = block.endIndex
        }

        return steps
    }

    private static func drawTemplate(
        startingAt startIndex: Int,
        commands: [GLDisplayListCommand]
    ) -> (template: GLDisplayListDrawTemplate, commands: [GLDisplayListCommand], endIndex: Int)? {
        var primitive: GLPrimitive?
        var localColor = GLColor(r: 1, g: 1, b: 1, a: 1)
        var localNormal = SIMD3<Float>(0, 0, 1)
        let localTextureCoordinate = SIMD2<Float>(0, 0)
        var hasLocalColor = false
        var hasLocalNormal = false
        var usesReplayCurrentColor = false
        var usesReplayCurrentNormal = false
        var replayCurrentColorVertexIndices: [Int] = []
        var replayCurrentNormalVertexIndices: [Int] = []
        var vertices: [GLVertex] = []
        var geometryCacheKey = GLGeometryCacheKey()
        var blockCommands: [GLDisplayListCommand] = []
        blockCommands.reserveCapacity(32)

        var index = startIndex
        while index < commands.endIndex {
            let command = commands[index]
            blockCommands.append(command)
            guard let compiled = command.compiled else {
                return nil
            }

            switch compiled {
            case .begin(let nextPrimitive):
                guard primitive == nil else {
                    return nil
                }
                primitive = nextPrimitive
            case .end:
                guard let primitive, !vertices.isEmpty else {
                    return nil
                }
                return (
                    GLDisplayListDrawTemplate(
                        primitive: primitive,
                        vertices: vertices,
                        geometryCacheKey: geometryCacheKey,
                        finalColor: localColor,
                        finalNormal: localNormal,
                        finalTextureCoordinate: localTextureCoordinate,
                        usesReplayCurrentColor: usesReplayCurrentColor,
                        usesReplayCurrentNormal: usesReplayCurrentNormal,
                        setsCurrentColor: hasLocalColor,
                        setsCurrentNormal: hasLocalNormal,
                        replayCurrentColorVertexIndices: replayCurrentColorVertexIndices,
                        replayCurrentNormalVertexIndices: replayCurrentNormalVertexIndices,
                        commandCount: blockCommands.count
                    ),
                    blockCommands,
                    index + 1
                )
            case .color(let color):
                localColor = color
                hasLocalColor = true
            case .normal(let normal):
                localNormal = normal
                hasLocalNormal = true
            case .vertex(let position):
                guard primitive != nil else {
                    return nil
                }
                let vertexIndex = vertices.count
                if !hasLocalColor {
                    usesReplayCurrentColor = true
                    replayCurrentColorVertexIndices.append(vertexIndex)
                }
                if !hasLocalNormal {
                    usesReplayCurrentNormal = true
                    replayCurrentNormalVertexIndices.append(vertexIndex)
                }
                let vertex = GLVertex(
                    position: position,
                    color: localColor,
                    normal: localNormal,
                    textureCoordinate: localTextureCoordinate
                )
                vertices.append(vertex)
                geometryCacheKey.append(vertex)
            case .material, .shadeModel:
                return nil
            }

            index += 1
        }

        return nil
    }
}

public struct FixedFunctionState: Equatable, Sendable {
    public var enabledCapabilities: Set<GLCapability> = []
    public var viewport = GLViewport()
    public var clearColor = GLColor(r: 0, g: 0, b: 0, a: 0)
    public var currentColor = GLColor(r: 1, g: 1, b: 1, a: 1)
    public var currentNormal = SIMD3<Float>(0, 0, 1)
    public var currentTextureCoordinate = SIMD2<Float>(0, 0)
    public var shadeModel: GLShadeModel = .smooth
    public var lightParameters: [GLLightStateKey: [Float]] = [:]
    public var materialParameters: [GLMaterialStateKey: [Float]] = [:]
    public var modelViewStack = MatrixStack(maxDepth: 32)
    public var projectionStack = MatrixStack(maxDepth: 8)
    public var textureStack = MatrixStack(maxDepth: 8)

    public init() {}
}

public struct VisionGLPipelineKey: Hashable, Sendable {
    public var enabledCapabilities: Set<GLCapability>
    public var primitive: GLPrimitive
    public var lightingEnabled: Bool
    public var textureEnabled: Bool
    public var fogEnabled: Bool

    public init(state: FixedFunctionState, primitive: GLPrimitive) {
        self.enabledCapabilities = state.enabledCapabilities
        self.primitive = primitive
        self.lightingEnabled = state.enabledCapabilities.contains(.lighting)
        self.textureEnabled = state.enabledCapabilities.contains(.texture2D)
        self.fogEnabled = state.enabledCapabilities.contains(.fog)
    }
}

public enum VisionGLError: Error, Equatable {
    case alreadyInsideBeginEnd
    case notInsideBeginEnd
    case displayListAlreadyRecording
    case noDisplayListRecording
    case unsupportedDisplayListMode(UInt32)
    case displayListReplayDepthExceeded
}

public final class VisionGLContext: @unchecked Sendable {
    public private(set) var state = FixedFunctionState()
    public private(set) var matrixMode: GLMatrixMode = .modelView
    public private(set) var completedDrawCalls: [ImmediateDrawCall] = []
    public private(set) var clearRequests: [GLClearRequest] = []
    public private(set) var displayLists: [UInt32: GLDisplayList] = [:]
    public private(set) var listBase: UInt32 = 0
    public var capturesDrawCalls = true

    private var activePrimitive: GLPrimitive?
    private var immediateVertices: [GLVertex] = []
    private var immediateGeometryCacheKey = GLGeometryCacheKey()
    private var activeDisplayList: GLDisplayListRecording?
    private var replayDepth = 0
    private var nextGeneratedDisplayListID: UInt32 = 1
    private var dynamicTemplateVertexCache: [GLDynamicTemplateVertexCacheKey: GLDynamicTemplateVertexCacheEntry] = [:]
    private let dynamicTemplateVertexCacheLimit = 256

    public init() {}

    public func enable(_ capability: GLCapability) {
        state.enabledCapabilities.insert(capability)
    }

    public func disable(_ capability: GLCapability) {
        state.enabledCapabilities.remove(capability)
    }

    public func viewport(x: Int32, y: Int32, width: Int32, height: Int32) {
        state.viewport = GLViewport(x: x, y: y, width: width, height: height)
    }

    public func clearColor(r: Float, g: Float, b: Float, a: Float) {
        state.clearColor = GLColor(r: r, g: g, b: b, a: a)
    }

    public func clear(mask: UInt32) {
        guard capturesDrawCalls else {
            return
        }
        clearRequests.append(GLClearRequest(mask: mask, color: state.clearColor))
    }

    public func color(r: Float, g: Float, b: Float, a: Float = 1) {
        state.currentColor = GLColor(r: r, g: g, b: b, a: a)
    }

    public func normal(x: Float, y: Float, z: Float) {
        state.currentNormal = SIMD3<Float>(x, y, z)
    }

    public func textureCoordinate(s: Float, t: Float) {
        state.currentTextureCoordinate = SIMD2<Float>(s, t)
    }

    public func light(light: UInt32, parameter: UInt32, values: [Float]) {
        if parameter == 0x1203, values.count >= 4 {
            let position = state.modelViewStack.current * SIMD4<Float>(values[0], values[1], values[2], values[3])
            var transformed = values
            transformed[0] = position.x
            transformed[1] = position.y
            transformed[2] = position.z
            transformed[3] = position.w
            state.lightParameters[GLLightStateKey(light: light, parameter: parameter)] = transformed
        } else {
            state.lightParameters[GLLightStateKey(light: light, parameter: parameter)] = values
        }
    }

    public func material(face: UInt32, parameter: UInt32, values: [Float]) {
        state.materialParameters[GLMaterialStateKey(face: face, parameter: parameter)] = values
        if parameter == 0x1602 {
            state.materialParameters[GLMaterialStateKey(face: face, parameter: 0x1200)] = values
            state.materialParameters[GLMaterialStateKey(face: face, parameter: 0x1201)] = values
        }
    }

    public func shadeModel(_ model: GLShadeModel) {
        state.shadeModel = model
    }

    public func setMatrixMode(_ mode: GLMatrixMode) {
        matrixMode = mode
    }

    public func loadIdentity() {
        updateCurrentStack { $0.loadIdentity() }
    }

    public func multiplyMatrix(_ matrix: Matrix4) {
        updateCurrentStack { $0.multiply(matrix) }
    }

    public func loadMatrix(_ matrix: Matrix4) {
        updateCurrentStack { $0.load(matrix) }
    }

    public func translate(x: Float, y: Float, z: Float) {
        multiplyMatrix(.translation(x: x, y: y, z: z))
    }

    public func scale(x: Float, y: Float, z: Float) {
        multiplyMatrix(.scale(x: x, y: y, z: z))
    }

    public func rotate(angleDegrees: Float, x: Float, y: Float, z: Float) {
        multiplyMatrix(.rotation(angleDegrees: angleDegrees, x: x, y: y, z: z))
    }

    public func frustum(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) {
        multiplyMatrix(.frustum(left: left, right: right, bottom: bottom, top: top, near: near, far: far))
    }

    public func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) {
        multiplyMatrix(.orthographic(left: left, right: right, bottom: bottom, top: top, near: near, far: far))
    }

    public func pushMatrix() throws {
        try updateCurrentStackThrowing { try $0.push() }
    }

    public func popMatrix() throws {
        try updateCurrentStackThrowing { try $0.pop() }
    }

    public func currentMatrix(for mode: GLMatrixMode) -> Matrix4 {
        switch mode {
        case .modelView:
            return state.modelViewStack.current
        case .projection:
            return state.projectionStack.current
        case .texture:
            return state.textureStack.current
        }
    }

    public func begin(_ primitive: GLPrimitive) throws {
        guard activePrimitive == nil else {
            throw VisionGLError.alreadyInsideBeginEnd
        }
        activePrimitive = primitive
        immediateVertices.removeAll(keepingCapacity: true)
        immediateGeometryCacheKey = GLGeometryCacheKey()
    }

    public func vertex(x: Float, y: Float, z: Float, w: Float = 1) throws {
        guard activePrimitive != nil else {
            throw VisionGLError.notInsideBeginEnd
        }
        guard capturesDrawCalls else {
            return
        }
        let vertex = GLVertex(
            position: SIMD4<Float>(x, y, z, w),
            color: state.currentColor,
            normal: state.currentNormal,
            textureCoordinate: state.currentTextureCoordinate
        )
        immediateVertices.append(vertex)
        immediateGeometryCacheKey.append(vertex)
    }

    public func end() throws -> ImmediateDrawCall {
        guard let primitive = activePrimitive else {
            throw VisionGLError.notInsideBeginEnd
        }
        let call = ImmediateDrawCall(
            primitive: primitive,
            vertices: immediateVertices,
            pipelineKey: VisionGLPipelineKey(state: state, primitive: primitive),
            modelViewMatrix: state.modelViewStack.current,
            projectionMatrix: state.projectionStack.current,
            viewport: state.viewport,
            stateSnapshot: state,
            geometryCacheKey: immediateGeometryCacheKey.vertexCount == immediateVertices.count ? immediateGeometryCacheKey : nil
        )
        activePrimitive = nil
        immediateVertices.removeAll(keepingCapacity: true)
        immediateGeometryCacheKey = GLGeometryCacheKey()
        return call
    }

    @discardableResult
    public func recordDrawCall(_ call: ImmediateDrawCall) -> Bool {
        guard capturesDrawCalls, !call.vertices.isEmpty else {
            return false
        }
        completedDrawCalls.append(call)
        return true
    }

    func canReplayDrawTemplate(_ template: GLDisplayListDrawTemplate) -> Bool {
        drawTemplateFallbackReasons(template).isEmpty
    }

    func drawTemplateFallbackReasons(_ template: GLDisplayListDrawTemplate) -> GLDisplayListDrawTemplateFallbackReasons {
        let lightingEnabled = state.enabledCapabilities.contains(.lighting)
        var reasons: GLDisplayListDrawTemplateFallbackReasons = []
        if template.usesReplayCurrentColor,
           (!lightingEnabled || state.enabledCapabilities.contains(.colorMaterial)) {
            reasons.insert(.currentColor)
        }
        return reasons
    }

    @discardableResult
    func recordDrawTemplate(_ template: GLDisplayListDrawTemplate) -> Bool {
        let replayCurrentColor = state.currentColor
        let replayCurrentNormal = state.currentNormal

        if template.setsCurrentColor {
            state.currentColor = template.finalColor
        }
        if template.setsCurrentNormal {
            state.currentNormal = template.finalNormal
        }

        guard capturesDrawCalls, !template.vertices.isEmpty else {
            return false
        }

        let cachedGeometry = templateVertices(
            for: template,
            replayColor: replayCurrentColor,
            replayNormal: replayCurrentNormal
        )

        let call = ImmediateDrawCall(
            primitive: template.primitive,
            vertices: cachedGeometry.vertices,
            pipelineKey: VisionGLPipelineKey(state: state, primitive: template.primitive),
            modelViewMatrix: state.modelViewStack.current,
            projectionMatrix: state.projectionStack.current,
            viewport: state.viewport,
            stateSnapshot: state,
            geometryCacheKey: cachedGeometry.geometryCacheKey
        )
        completedDrawCalls.append(call)
        return true
    }

    private func templateVertices(
        for template: GLDisplayListDrawTemplate,
        replayColor: GLColor,
        replayNormal: SIMD3<Float>
    ) -> (vertices: [GLVertex], geometryCacheKey: GLGeometryCacheKey) {
        guard !template.replayCurrentColorVertexIndices.isEmpty ||
            !template.replayCurrentNormalVertexIndices.isEmpty else {
            return (template.vertices, template.geometryCacheKey)
        }

        let cacheKey = GLDynamicTemplateVertexCacheKey(
            template: template,
            replayColor: replayColor,
            replayNormal: replayNormal
        )
        if let cached = dynamicTemplateVertexCache[cacheKey] {
            return (cached.vertices, cached.geometryCacheKey)
        }

        var vertices = template.vertices
        for index in template.replayCurrentColorVertexIndices where vertices.indices.contains(index) {
            vertices[index].color = replayColor
        }
        for index in template.replayCurrentNormalVertexIndices where vertices.indices.contains(index) {
            vertices[index].normal = replayNormal
        }
        let geometryCacheKey = GLGeometryCacheKey(vertices: vertices)

        if dynamicTemplateVertexCache.count >= dynamicTemplateVertexCacheLimit {
            dynamicTemplateVertexCache.removeAll(keepingCapacity: true)
        }
        dynamicTemplateVertexCache[cacheKey] = GLDynamicTemplateVertexCacheEntry(
            vertices: vertices,
            geometryCacheKey: geometryCacheKey
        )
        return (vertices, geometryCacheKey)
    }

    public func frameCommandsSnapshot() -> VisionGLFrameCommands {
        VisionGLFrameCommands(drawCalls: completedDrawCalls, clearRequests: clearRequests)
    }

    public func clearFrameCommands() {
        completedDrawCalls.removeAll(keepingCapacity: true)
        clearRequests.removeAll(keepingCapacity: true)
    }

    public func drainFrameCommands() -> VisionGLFrameCommands {
        let frame = frameCommandsSnapshot()
        clearFrameCommands()
        return frame
    }

    public func beginDisplayList(id: UInt32, modeRawValue: UInt32) throws {
        guard activeDisplayList == nil else {
            throw VisionGLError.displayListAlreadyRecording
        }
        guard let mode = GLDisplayListMode(rawValue: modeRawValue) else {
            throw VisionGLError.unsupportedDisplayListMode(modeRawValue)
        }
        activeDisplayList = GLDisplayListRecording(id: id, mode: mode, commands: [])
    }

    public func endDisplayList() throws {
        guard let recording = activeDisplayList else {
            throw VisionGLError.noDisplayListRecording
        }
        displayLists[recording.id] = GLDisplayList(id: recording.id, commands: recording.commands)
        dynamicTemplateVertexCache.removeAll(keepingCapacity: true)
        activeDisplayList = nil
    }

    public func deleteDisplayLists(first: UInt32, range: UInt32) {
        guard range > 0 else {
            return
        }
        for offset in 0..<range {
            displayLists.removeValue(forKey: first &+ offset)
        }
        dynamicTemplateVertexCache.removeAll(keepingCapacity: true)
    }

    public func generateDisplayLists(range: UInt32) -> UInt32 {
        guard range > 0 else {
            return 0
        }

        var candidate = max(1, nextGeneratedDisplayListID)
        let highestCandidate = UInt32.max - range + 1
        while candidate <= highestCandidate {
            let last = candidate + range - 1
            let hasCollision = (candidate...last).contains { displayLists[$0] != nil }
            if !hasCollision {
                nextGeneratedDisplayListID = last == UInt32.max ? 1 : last + 1
                return candidate
            }
            if candidate == UInt32.max {
                break
            }
            candidate += 1
        }
        return 0
    }

    public func setListBase(_ base: UInt32) {
        listBase = base
    }

    public func displayList(id: UInt32) -> GLDisplayList? {
        displayLists[id]
    }

    public var shouldRecordDisplayListCommand: Bool {
        activeDisplayList != nil && replayDepth == 0
    }

    public func recordDisplayListCommand(bytes: [UInt8], byteOrder: GLXRenderByteOrder) -> Bool {
        guard replayDepth == 0, var recording = activeDisplayList else {
            return true
        }
        recording.commands.append(GLDisplayListCommand(bytes: bytes, byteOrder: byteOrder))
        activeDisplayList = recording
        return recording.mode == .compileAndExecute
    }

    public func beginDisplayListReplay() throws {
        guard replayDepth < 32 else {
            throw VisionGLError.displayListReplayDepthExceeded
        }
        replayDepth += 1
    }

    public func endDisplayListReplay() {
        replayDepth = max(0, replayDepth - 1)
    }

    private func updateCurrentStack(_ body: (inout MatrixStack) -> Void) {
        switch matrixMode {
        case .modelView:
            body(&state.modelViewStack)
        case .projection:
            body(&state.projectionStack)
        case .texture:
            body(&state.textureStack)
        }
    }

    private func updateCurrentStackThrowing(_ body: (inout MatrixStack) throws -> Void) throws {
        switch matrixMode {
        case .modelView:
            try body(&state.modelViewStack)
        case .projection:
            try body(&state.projectionStack)
        case .texture:
            try body(&state.textureStack)
        }
    }
}

private struct GLDisplayListRecording {
    var id: UInt32
    var mode: GLDisplayListMode
    var commands: [GLDisplayListCommand]
}

private extension Matrix4 {
    static func * (lhs: Matrix4, rhs: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(
            lhs[0, 0] * rhs.x + lhs[0, 1] * rhs.y + lhs[0, 2] * rhs.z + lhs[0, 3] * rhs.w,
            lhs[1, 0] * rhs.x + lhs[1, 1] * rhs.y + lhs[1, 2] * rhs.z + lhs[1, 3] * rhs.w,
            lhs[2, 0] * rhs.x + lhs[2, 1] * rhs.y + lhs[2, 2] * rhs.z + lhs[2, 3] * rhs.w,
            lhs[3, 0] * rhs.x + lhs[3, 1] * rhs.y + lhs[3, 2] * rhs.z + lhs[3, 3] * rhs.w
        )
    }
}
