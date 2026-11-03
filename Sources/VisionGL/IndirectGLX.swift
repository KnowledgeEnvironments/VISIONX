// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation

public typealias GLXContextID = UInt32
public typealias GLXDrawableID = UInt32
public typealias GLXVisualID = UInt32
public typealias X11ResourceID = UInt32

public struct GLXVisual: Equatable, Sendable {
    public var id: GLXVisualID
    public var rgba: Bool
    public var doubleBuffered: Bool
    public var redBits: Int
    public var greenBits: Int
    public var blueBits: Int
    public var alphaBits: Int
    public var depthBits: Int
    public var stencilBits: Int

    public init(
        id: GLXVisualID,
        rgba: Bool = true,
        doubleBuffered: Bool = true,
        redBits: Int = 8,
        greenBits: Int = 8,
        blueBits: Int = 8,
        alphaBits: Int = 8,
        depthBits: Int = 24,
        stencilBits: Int = 8
    ) {
        self.id = id
        self.rgba = rgba
        self.doubleBuffered = doubleBuffered
        self.redBits = redBits
        self.greenBits = greenBits
        self.blueBits = blueBits
        self.alphaBits = alphaBits
        self.depthBits = depthBits
        self.stencilBits = stencilBits
    }
}

public struct IndirectGLXCapabilities: Equatable, Sendable {
    public var serverVersionMajor: Int
    public var serverVersionMinor: Int
    public var clientOpenGLVersion: String
    public var visuals: [GLXVisual]
    public var extensions: [String]

    public init(
        serverVersionMajor: Int = 1,
        serverVersionMinor: Int = 2,
        clientOpenGLVersion: String = "1.1",
        visuals: [GLXVisual] = [GLXVisual(id: 0x21)],
        extensions: [String] = []
    ) {
        self.serverVersionMajor = serverVersionMajor
        self.serverVersionMinor = serverVersionMinor
        self.clientOpenGLVersion = clientOpenGLVersion
        self.visuals = visuals
        self.extensions = extensions
    }

    public static let irixOpenGL11 = IndirectGLXCapabilities()
}

public struct GLXContextRecord: Sendable {
    public var id: GLXContextID
    public var visual: GLXVisual
    public var shareGroup: GLXContextID?
    public var context: VisionGLContext

    public init(id: GLXContextID, visual: GLXVisual, shareGroup: GLXContextID?, context: VisionGLContext) {
        self.id = id
        self.visual = visual
        self.shareGroup = shareGroup
        self.context = context
    }
}

public enum GLXDrawableKind: Equatable, Sendable {
    case window(X11ResourceID)
    case pixmap(X11ResourceID)
}

public enum GLXColorBufferFormat: Equatable, Sendable {
    case bgra8Unorm

    public var bytesPerPixel: Int {
        switch self {
        case .bgra8Unorm:
            return 4
        }
    }
}

public struct GLXBackBufferDescriptor: Equatable, Sendable {
    public var colorFormat: GLXColorBufferFormat
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var byteCount: Int
    public var depthBits: Int
    public var stencilBits: Int
    public var doubleBuffered: Bool

    public init(
        colorFormat: GLXColorBufferFormat = .bgra8Unorm,
        width: Int,
        height: Int,
        depthBits: Int,
        stencilBits: Int,
        doubleBuffered: Bool
    ) {
        self.colorFormat = colorFormat
        self.width = width
        self.height = height
        self.bytesPerRow = width * colorFormat.bytesPerPixel
        self.byteCount = self.bytesPerRow * height
        self.depthBits = depthBits
        self.stencilBits = stencilBits
        self.doubleBuffered = doubleBuffered
    }
}

public struct GLXDrawableRecord: Equatable, Sendable {
    public var id: GLXDrawableID
    public var kind: GLXDrawableKind
    public var visual: GLXVisual
    public var width: Int
    public var height: Int
    public var backBuffer: GLXBackBufferDescriptor

    public init(id: GLXDrawableID, kind: GLXDrawableKind, visual: GLXVisual, width: Int, height: Int) {
        self.id = id
        self.kind = kind
        self.visual = visual
        self.width = width
        self.height = height
        self.backBuffer = GLXBackBufferDescriptor(
            width: width,
            height: height,
            depthBits: visual.depthBits,
            stencilBits: visual.stencilBits,
            doubleBuffered: visual.doubleBuffered
        )
    }

    public mutating func resize(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.backBuffer = GLXBackBufferDescriptor(
            width: width,
            height: height,
            depthBits: visual.depthBits,
            stencilBits: visual.stencilBits,
            doubleBuffered: visual.doubleBuffered
        )
    }
}

public enum GLXRegistryError: Error, Equatable {
    case unknownVisual(GLXVisualID)
    case duplicateContext(GLXContextID)
    case unknownContext(GLXContextID)
    case duplicateDrawable(GLXDrawableID)
    case unknownDrawable(GLXDrawableID)
    case invalidDrawableSize(width: Int, height: Int)
    case incompatibleDrawableVisual(context: GLXContextID, drawable: GLXDrawableID)
}

public enum GLXRegistryEvent: Equatable, Sendable {
    case contextCreated(GLXContextID)
    case contextDestroyed(GLXContextID)
    case drawableCreated(GLXDrawableID)
    case drawableDestroyed(GLXDrawableID)
    case drawableResized(drawable: GLXDrawableID, width: Int, height: Int)
    case madeCurrent(context: GLXContextID, drawable: GLXDrawableID)
    case swapBuffers(drawable: GLXDrawableID)
}

public enum GLXRenderByteOrder: Equatable, Sendable {
    case littleEndian
    case bigEndian
}

public struct GLXRenderExecutionSummary: Equatable, Sendable {
    public var commandCount: Int
    public var drawCallCount: Int
    public var clearCount: Int
    public var rotationCount: Int
    public var rotationSignature: Float
    public var rotationTrace: String
    public var skippedDisplayListCount: Int
    public var templatedDrawCallCount: Int
    public var templateFallbackCount: Int
    public var templateFallbackCurrentColorCount: Int
    public var templateFallbackCurrentNormalCount: Int

    public init(
        commandCount: Int = 0,
        drawCallCount: Int = 0,
        clearCount: Int = 0,
        rotationCount: Int = 0,
        rotationSignature: Float = 0,
        rotationTrace: String = "",
        skippedDisplayListCount: Int = 0,
        templatedDrawCallCount: Int = 0,
        templateFallbackCount: Int = 0,
        templateFallbackCurrentColorCount: Int = 0,
        templateFallbackCurrentNormalCount: Int = 0
    ) {
        self.commandCount = commandCount
        self.drawCallCount = drawCallCount
        self.clearCount = clearCount
        self.rotationCount = rotationCount
        self.rotationSignature = rotationSignature
        self.rotationTrace = rotationTrace
        self.skippedDisplayListCount = skippedDisplayListCount
        self.templatedDrawCallCount = templatedDrawCallCount
        self.templateFallbackCount = templateFallbackCount
        self.templateFallbackCurrentColorCount = templateFallbackCurrentColorCount
        self.templateFallbackCurrentNormalCount = templateFallbackCurrentNormalCount
    }
}

public enum GLXRenderError: Error, Equatable {
    case unknownContext(GLXContextID)
    case malformedCommand
    case unsupportedOpcode(UInt16)
    case unsupportedEnum(UInt32)
    case contextError(VisionGLError)
}

public final class VisionGLXRegistry: @unchecked Sendable {
    public private(set) var capabilities: IndirectGLXCapabilities
    public private(set) var contexts: [GLXContextID: GLXContextRecord] = [:]
    public private(set) var drawables: [GLXDrawableID: GLXDrawableRecord] = [:]
    public private(set) var currentContext: GLXContextID?
    public private(set) var currentDrawable: GLXDrawableID?

    public var onEvent: @Sendable (GLXRegistryEvent) -> Void = { _ in }

    public init(capabilities: IndirectGLXCapabilities = .irixOpenGL11) {
        self.capabilities = capabilities
    }

    public func createContext(id: GLXContextID, visualID: GLXVisualID, shareGroup: GLXContextID? = nil) throws {
        guard contexts[id] == nil else {
            throw GLXRegistryError.duplicateContext(id)
        }
        guard let visual = capabilities.visuals.first(where: { $0.id == visualID }) else {
            throw GLXRegistryError.unknownVisual(visualID)
        }
        contexts[id] = GLXContextRecord(
            id: id,
            visual: visual,
            shareGroup: shareGroup,
            context: VisionGLContext()
        )
        onEvent(.contextCreated(id))
    }

    public func destroyContext(id: GLXContextID) {
        contexts.removeValue(forKey: id)
        if currentContext == id {
            currentContext = nil
            currentDrawable = nil
        }
        onEvent(.contextDestroyed(id))
    }

    public func createWindowDrawable(
        id: GLXDrawableID,
        windowID: X11ResourceID,
        visualID: GLXVisualID,
        width: Int,
        height: Int
    ) throws {
        try createDrawable(id: id, kind: .window(windowID), visualID: visualID, width: width, height: height)
    }

    public func createPixmapDrawable(
        id: GLXDrawableID,
        pixmapID: X11ResourceID,
        visualID: GLXVisualID,
        width: Int,
        height: Int
    ) throws {
        try createDrawable(id: id, kind: .pixmap(pixmapID), visualID: visualID, width: width, height: height)
    }

    public func destroyDrawable(id: GLXDrawableID) {
        drawables.removeValue(forKey: id)
        if currentDrawable == id {
            currentContext = nil
            currentDrawable = nil
        }
        onEvent(.drawableDestroyed(id))
    }

    public func resizeDrawable(id: GLXDrawableID, width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw GLXRegistryError.invalidDrawableSize(width: width, height: height)
        }
        guard drawables[id] != nil else {
            throw GLXRegistryError.unknownDrawable(id)
        }
        drawables[id]?.resize(width: width, height: height)
        onEvent(.drawableResized(drawable: id, width: width, height: height))
    }

    public func makeCurrent(context id: GLXContextID, drawable: GLXDrawableID) throws {
        guard let context = contexts[id] else {
            throw GLXRegistryError.unknownContext(id)
        }
        guard let drawableRecord = drawables[drawable] else {
            throw GLXRegistryError.unknownDrawable(drawable)
        }
        guard context.visual.id == drawableRecord.visual.id else {
            throw GLXRegistryError.incompatibleDrawableVisual(context: id, drawable: drawable)
        }
        currentContext = id
        currentDrawable = drawable
        onEvent(.madeCurrent(context: id, drawable: drawable))
    }

    public func swapBuffers(context id: GLXContextID, drawable: GLXDrawableID) throws {
        guard let context = contexts[id] else {
            throw GLXRegistryError.unknownContext(id)
        }
        guard let drawableRecord = drawables[drawable] else {
            throw GLXRegistryError.unknownDrawable(drawable)
        }
        guard context.visual.id == drawableRecord.visual.id else {
            throw GLXRegistryError.incompatibleDrawableVisual(context: id, drawable: drawable)
        }
        onEvent(.swapBuffers(drawable: drawable))
    }

    public func beginDisplayList(context id: GLXContextID, list: UInt32, mode: UInt32) throws {
        guard let record = contexts[id] else {
            throw GLXRenderError.unknownContext(id)
        }
        try record.context.beginDisplayList(id: list, modeRawValue: mode)
    }

    public func endDisplayList(context id: GLXContextID) throws {
        guard let record = contexts[id] else {
            throw GLXRenderError.unknownContext(id)
        }
        try record.context.endDisplayList()
    }

    public func deleteDisplayLists(context id: GLXContextID, list: UInt32, range: UInt32) throws {
        guard let record = contexts[id] else {
            throw GLXRenderError.unknownContext(id)
        }
        record.context.deleteDisplayLists(first: list, range: range)
    }

    public func generateDisplayLists(context id: GLXContextID, range: UInt32) throws -> UInt32 {
        guard let record = contexts[id] else {
            throw GLXRenderError.unknownContext(id)
        }
        return record.context.generateDisplayLists(range: range)
    }

    public func executeRenderCommands(
        context id: GLXContextID,
        bytes: UnsafeBufferPointer<UInt8>,
        byteOrder: GLXRenderByteOrder,
        captureDrawCalls: Bool = true
    ) throws -> GLXRenderExecutionSummary {
        guard let record = contexts[id] else {
            throw GLXRenderError.unknownContext(id)
        }

        let previousCaptureMode = record.context.capturesDrawCalls
        record.context.capturesDrawCalls = captureDrawCalls
        defer {
            record.context.capturesDrawCalls = previousCaptureMode
        }

        var decoder = GLXRenderCommandDecoder(bytes: bytes, byteOrder: byteOrder, context: record.context)
        return try decoder.execute()
    }

    private func createDrawable(
        id: GLXDrawableID,
        kind: GLXDrawableKind,
        visualID: GLXVisualID,
        width: Int,
        height: Int
    ) throws {
        guard drawables[id] == nil else {
            throw GLXRegistryError.duplicateDrawable(id)
        }
        guard width > 0, height > 0 else {
            throw GLXRegistryError.invalidDrawableSize(width: width, height: height)
        }
        guard let visual = capabilities.visuals.first(where: { $0.id == visualID }) else {
            throw GLXRegistryError.unknownVisual(visualID)
        }
        drawables[id] = GLXDrawableRecord(id: id, kind: kind, visual: visual, width: width, height: height)
        onEvent(.drawableCreated(id))
    }
}

private struct GLXRenderCommandDecoder {
    private static let collectsRotationTrace = ProcessInfo.processInfo.environment["VISIONX_GLX_ROTATION_TRACE"] == "1"

    private let bytes: UnsafeBufferPointer<UInt8>
    private let byteOrder: GLXRenderByteOrder
    private let context: VisionGLContext
    private var summary = GLXRenderExecutionSummary()

    init(bytes: UnsafeBufferPointer<UInt8>, byteOrder: GLXRenderByteOrder, context: VisionGLContext) {
        self.bytes = bytes
        self.byteOrder = byteOrder
        self.context = context
    }

    mutating func execute() throws -> GLXRenderExecutionSummary {
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 4 else {
                throw GLXRenderError.malformedCommand
            }

            let length = Int(readUInt16(at: offset))
            let opcode = readUInt16(at: offset + 2)
            guard length >= 4, length % 4 == 0, offset + length <= bytes.count else {
                throw GLXRenderError.malformedCommand
            }

            if context.shouldRecordDisplayListCommand {
                let commandBytes = Array(bytes[offset..<(offset + length)])
                guard context.recordDisplayListCommand(bytes: commandBytes, byteOrder: byteOrder) else {
                    summary.commandCount += 1
                    offset += length
                    continue
                }
            }

            try execute(opcode: opcode, payloadOffset: offset + 4, payloadLength: length - 4)
            summary.commandCount += 1
            offset += length
        }
        return summary
    }

    private mutating func execute(opcode: UInt16, payloadOffset: Int, payloadLength: Int) throws {
        switch opcode {
        case 1:
            try executeDisplayList(readUInt32Payload(at: payloadOffset, length: payloadLength))
        case 2:
            try executeDisplayListArray(payloadOffset: payloadOffset, payloadLength: payloadLength)
        case 3:
            context.setListBase(try readUInt32Payload(at: payloadOffset, length: payloadLength))
        case 4:
            try context.begin(try primitive(readUInt32Payload(at: payloadOffset, length: payloadLength)))
        case 8:
            try require(payloadLength, atLeast: 12)
            context.color(
                r: readFloat32(at: payloadOffset),
                g: readFloat32(at: payloadOffset + 4),
                b: readFloat32(at: payloadOffset + 8),
                a: 1
            )
        case 16:
            try require(payloadLength, atLeast: 16)
            context.color(
                r: readFloat32(at: payloadOffset),
                g: readFloat32(at: payloadOffset + 4),
                b: readFloat32(at: payloadOffset + 8),
                a: readFloat32(at: payloadOffset + 12)
            )
        case 19:
            try require(payloadLength, atLeast: 4)
            context.color(
                r: Float(bytes[payloadOffset]) / 255,
                g: Float(bytes[payloadOffset + 1]) / 255,
                b: Float(bytes[payloadOffset + 2]) / 255,
                a: Float(bytes[payloadOffset + 3]) / 255
            )
        case 23:
            let call = try context.end()
            if context.recordDrawCall(call) {
                summary.drawCallCount += 1
            }
        case 30:
            try require(payloadLength, atLeast: 12)
            context.normal(
                x: readFloat32(at: payloadOffset),
                y: readFloat32(at: payloadOffset + 4),
                z: readFloat32(at: payloadOffset + 8)
            )
        case 32:
            try require(payloadLength, atLeast: 6)
            context.normal(
                x: Float(readInt16(at: payloadOffset)),
                y: Float(readInt16(at: payloadOffset + 2)),
                z: Float(readInt16(at: payloadOffset + 4))
            )
        case 65:
            try require(payloadLength, atLeast: 16)
            try context.vertex(
                x: Float(readFloat64(at: payloadOffset)),
                y: Float(readFloat64(at: payloadOffset + 8)),
                z: 0
            )
        case 66:
            try require(payloadLength, atLeast: 8)
            try context.vertex(
                x: readFloat32(at: payloadOffset),
                y: readFloat32(at: payloadOffset + 4),
                z: 0
            )
        case 67:
            try require(payloadLength, atLeast: 8)
            try context.vertex(
                x: Float(readInt32(at: payloadOffset)),
                y: Float(readInt32(at: payloadOffset + 4)),
                z: 0
            )
        case 68:
            try require(payloadLength, atLeast: 4)
            try context.vertex(
                x: Float(readInt16(at: payloadOffset)),
                y: Float(readInt16(at: payloadOffset + 2)),
                z: 0
            )
        case 69:
            try require(payloadLength, atLeast: 24)
            try context.vertex(
                x: Float(readFloat64(at: payloadOffset)),
                y: Float(readFloat64(at: payloadOffset + 8)),
                z: Float(readFloat64(at: payloadOffset + 16))
            )
        case 70:
            try require(payloadLength, atLeast: 12)
            try context.vertex(
                x: readFloat32(at: payloadOffset),
                y: readFloat32(at: payloadOffset + 4),
                z: readFloat32(at: payloadOffset + 8)
            )
        case 71:
            try require(payloadLength, atLeast: 12)
            try context.vertex(
                x: Float(readInt32(at: payloadOffset)),
                y: Float(readInt32(at: payloadOffset + 4)),
                z: Float(readInt32(at: payloadOffset + 8))
            )
        case 72:
            try require(payloadLength, atLeast: 6)
            try context.vertex(
                x: Float(readInt16(at: payloadOffset)),
                y: Float(readInt16(at: payloadOffset + 2)),
                z: Float(readInt16(at: payloadOffset + 4))
            )
        case 73:
            try require(payloadLength, atLeast: 32)
            try context.vertex(
                x: Float(readFloat64(at: payloadOffset)),
                y: Float(readFloat64(at: payloadOffset + 8)),
                z: Float(readFloat64(at: payloadOffset + 16)),
                w: Float(readFloat64(at: payloadOffset + 24))
            )
        case 74:
            try require(payloadLength, atLeast: 16)
            try context.vertex(
                x: readFloat32(at: payloadOffset),
                y: readFloat32(at: payloadOffset + 4),
                z: readFloat32(at: payloadOffset + 8),
                w: readFloat32(at: payloadOffset + 12)
            )
        case 75:
            try require(payloadLength, atLeast: 16)
            try context.vertex(
                x: Float(readInt32(at: payloadOffset)),
                y: Float(readInt32(at: payloadOffset + 4)),
                z: Float(readInt32(at: payloadOffset + 8)),
                w: Float(readInt32(at: payloadOffset + 12))
            )
        case 76:
            try require(payloadLength, atLeast: 8)
            try context.vertex(
                x: Float(readInt16(at: payloadOffset)),
                y: Float(readInt16(at: payloadOffset + 2)),
                z: Float(readInt16(at: payloadOffset + 4)),
                w: Float(readInt16(at: payloadOffset + 6))
            )
        case 86:
            try require(payloadLength, atLeast: 12)
            context.light(
                light: readUInt32(at: payloadOffset),
                parameter: readUInt32(at: payloadOffset + 4),
                values: [readFloat32(at: payloadOffset + 8)]
            )
        case 87:
            try require(payloadLength, atLeast: 12)
            context.light(
                light: readUInt32(at: payloadOffset),
                parameter: readUInt32(at: payloadOffset + 4),
                values: try float32Values(at: payloadOffset + 8, byteCount: payloadLength - 8)
            )
        case 88:
            try require(payloadLength, atLeast: 12)
            context.light(
                light: readUInt32(at: payloadOffset),
                parameter: readUInt32(at: payloadOffset + 4),
                values: [Float(readInt32(at: payloadOffset + 8))]
            )
        case 89:
            try require(payloadLength, atLeast: 12)
            context.light(
                light: readUInt32(at: payloadOffset),
                parameter: readUInt32(at: payloadOffset + 4),
                values: try int32Values(at: payloadOffset + 8, byteCount: payloadLength - 8).map(Float.init)
            )
        case 90:
            try require(payloadLength, atLeast: 8)
            context.light(light: 0, parameter: readUInt32(at: payloadOffset), values: [readFloat32(at: payloadOffset + 4)])
        case 91:
            try require(payloadLength, atLeast: 8)
            context.light(
                light: 0,
                parameter: readUInt32(at: payloadOffset),
                values: try float32Values(at: payloadOffset + 4, byteCount: payloadLength - 4)
            )
        case 92:
            try require(payloadLength, atLeast: 8)
            context.light(light: 0, parameter: readUInt32(at: payloadOffset), values: [Float(readInt32(at: payloadOffset + 4))])
        case 93:
            try require(payloadLength, atLeast: 8)
            context.light(
                light: 0,
                parameter: readUInt32(at: payloadOffset),
                values: try int32Values(at: payloadOffset + 4, byteCount: payloadLength - 4).map(Float.init)
            )
        case 96:
            try require(payloadLength, atLeast: 12)
            context.material(
                face: readUInt32(at: payloadOffset),
                parameter: readUInt32(at: payloadOffset + 4),
                values: [readFloat32(at: payloadOffset + 8)]
            )
        case 97:
            try require(payloadLength, atLeast: 12)
            context.material(
                face: readUInt32(at: payloadOffset),
                parameter: readUInt32(at: payloadOffset + 4),
                values: try float32Values(at: payloadOffset + 8, byteCount: payloadLength - 8)
            )
        case 98:
            try require(payloadLength, atLeast: 12)
            context.material(
                face: readUInt32(at: payloadOffset),
                parameter: readUInt32(at: payloadOffset + 4),
                values: [Float(readInt32(at: payloadOffset + 8))]
            )
        case 99:
            try require(payloadLength, atLeast: 12)
            context.material(
                face: readUInt32(at: payloadOffset),
                parameter: readUInt32(at: payloadOffset + 4),
                values: try int32Values(at: payloadOffset + 8, byteCount: payloadLength - 8).map(Float.init)
            )
        case 104:
            context.shadeModel(try shadeModel(readUInt32Payload(at: payloadOffset, length: payloadLength)))
        case 127:
            let capturesClear = context.capturesDrawCalls
            context.clear(mask: try readUInt32Payload(at: payloadOffset, length: payloadLength))
            if capturesClear {
                summary.clearCount += 1
            }
        case 130:
            try require(payloadLength, atLeast: 16)
            context.clearColor(
                r: readFloat32(at: payloadOffset),
                g: readFloat32(at: payloadOffset + 4),
                b: readFloat32(at: payloadOffset + 8),
                a: readFloat32(at: payloadOffset + 12)
            )
        case 138:
            context.disable(try capability(readUInt32Payload(at: payloadOffset, length: payloadLength)))
        case 139:
            context.enable(try capability(readUInt32Payload(at: payloadOffset, length: payloadLength)))
        case 176:
            context.loadIdentity()
        case 177:
            try require(payloadLength, atLeast: 64)
            context.loadMatrix(readMatrixf(at: payloadOffset))
        case 178:
            try require(payloadLength, atLeast: 128)
            context.loadMatrix(readMatrixd(at: payloadOffset))
        case 179:
            context.setMatrixMode(try matrixMode(readUInt32Payload(at: payloadOffset, length: payloadLength)))
        case 180:
            try require(payloadLength, atLeast: 64)
            context.multiplyMatrix(readMatrixf(at: payloadOffset))
        case 181:
            try require(payloadLength, atLeast: 128)
            context.multiplyMatrix(readMatrixd(at: payloadOffset))
        case 182:
            try require(payloadLength, atLeast: 48)
            context.orthographic(
                left: Float(readFloat64(at: payloadOffset)),
                right: Float(readFloat64(at: payloadOffset + 8)),
                bottom: Float(readFloat64(at: payloadOffset + 16)),
                top: Float(readFloat64(at: payloadOffset + 24)),
                near: Float(readFloat64(at: payloadOffset + 32)),
                far: Float(readFloat64(at: payloadOffset + 40))
            )
        case 183:
            try context.popMatrix()
        case 184:
            try context.pushMatrix()
        case 185:
            try require(payloadLength, atLeast: 32)
            recordRotation(
                angleDegrees: Float(readFloat64(at: payloadOffset)),
                x: Float(readFloat64(at: payloadOffset + 8)),
                y: Float(readFloat64(at: payloadOffset + 16)),
                z: Float(readFloat64(at: payloadOffset + 24))
            )
            context.rotate(
                angleDegrees: Float(readFloat64(at: payloadOffset)),
                x: Float(readFloat64(at: payloadOffset + 8)),
                y: Float(readFloat64(at: payloadOffset + 16)),
                z: Float(readFloat64(at: payloadOffset + 24))
            )
        case 186:
            try require(payloadLength, atLeast: 16)
            recordRotation(
                angleDegrees: readFloat32(at: payloadOffset),
                x: readFloat32(at: payloadOffset + 4),
                y: readFloat32(at: payloadOffset + 8),
                z: readFloat32(at: payloadOffset + 12)
            )
            context.rotate(
                angleDegrees: readFloat32(at: payloadOffset),
                x: readFloat32(at: payloadOffset + 4),
                y: readFloat32(at: payloadOffset + 8),
                z: readFloat32(at: payloadOffset + 12)
            )
        case 187:
            try require(payloadLength, atLeast: 24)
            context.scale(
                x: Float(readFloat64(at: payloadOffset)),
                y: Float(readFloat64(at: payloadOffset + 8)),
                z: Float(readFloat64(at: payloadOffset + 16))
            )
        case 188:
            try require(payloadLength, atLeast: 12)
            context.scale(
                x: readFloat32(at: payloadOffset),
                y: readFloat32(at: payloadOffset + 4),
                z: readFloat32(at: payloadOffset + 8)
            )
        case 189:
            try require(payloadLength, atLeast: 24)
            context.translate(
                x: Float(readFloat64(at: payloadOffset)),
                y: Float(readFloat64(at: payloadOffset + 8)),
                z: Float(readFloat64(at: payloadOffset + 16))
            )
        case 190:
            try require(payloadLength, atLeast: 12)
            context.translate(
                x: readFloat32(at: payloadOffset),
                y: readFloat32(at: payloadOffset + 4),
                z: readFloat32(at: payloadOffset + 8)
            )
        case 191:
            try require(payloadLength, atLeast: 16)
            context.viewport(
                x: readInt32(at: payloadOffset),
                y: readInt32(at: payloadOffset + 4),
                width: readInt32(at: payloadOffset + 8),
                height: readInt32(at: payloadOffset + 12)
            )
        case 175:
            try require(payloadLength, atLeast: 48)
            context.frustum(
                left: Float(readFloat64(at: payloadOffset)),
                right: Float(readFloat64(at: payloadOffset + 8)),
                bottom: Float(readFloat64(at: payloadOffset + 16)),
                top: Float(readFloat64(at: payloadOffset + 24)),
                near: Float(readFloat64(at: payloadOffset + 32)),
                far: Float(readFloat64(at: payloadOffset + 40))
            )
        default:
            throw GLXRenderError.unsupportedOpcode(opcode)
        }
    }

    private mutating func executeDisplayList(_ id: UInt32) throws {
        guard let list = context.displayList(id: id) else {
            return
        }
        guard context.capturesDrawCalls || !list.containsDrawCommands else {
            summary.skippedDisplayListCount += 1
            return
        }

        try context.beginDisplayListReplay()
        defer {
            context.endDisplayListReplay()
        }

        for step in list.executionSteps {
            try executeDisplayListStep(step)
        }
    }

    private mutating func executeDisplayListStep(_ step: GLDisplayListExecutionStep) throws {
        switch step {
        case .command(let command):
            try executeDisplayListCommand(command)
        case .drawTemplate(let template, let fallback):
            let fallbackReasons = context.drawTemplateFallbackReasons(template)
            guard fallbackReasons.isEmpty else {
                summary.templateFallbackCount += 1
                if fallbackReasons.contains(.currentColor) {
                    summary.templateFallbackCurrentColorCount += 1
                }
                if fallbackReasons.contains(.currentNormal) {
                    summary.templateFallbackCurrentNormalCount += 1
                }
                try executeDisplayListCommands(fallback)
                return
            }
            if context.recordDrawTemplate(template) {
                summary.drawCallCount += 1
                summary.templatedDrawCallCount += 1
            }
            summary.commandCount += template.commandCount
        }
    }

    private mutating func executeDisplayListCommands(_ commands: [GLDisplayListCommand]) throws {
        for command in commands {
            try executeDisplayListCommand(command)
        }
    }

    private mutating func executeDisplayListCommand(_ command: GLDisplayListCommand) throws {
        if let compiled = command.compiled {
            try executeCompiledDisplayListCommand(compiled)
            return
        }
        let nestedSummary = try command.bytes.withUnsafeBufferPointer { commandBytes in
            var decoder = GLXRenderCommandDecoder(bytes: commandBytes, byteOrder: command.byteOrder, context: context)
            return try decoder.execute()
        }
        summary.commandCount += nestedSummary.commandCount
        summary.drawCallCount += nestedSummary.drawCallCount
        summary.clearCount += nestedSummary.clearCount
        summary.rotationCount += nestedSummary.rotationCount
        summary.rotationSignature += nestedSummary.rotationSignature
        appendRotationTrace(nestedSummary.rotationTrace)
        summary.skippedDisplayListCount += nestedSummary.skippedDisplayListCount
        summary.templatedDrawCallCount += nestedSummary.templatedDrawCallCount
        summary.templateFallbackCount += nestedSummary.templateFallbackCount
        summary.templateFallbackCurrentColorCount += nestedSummary.templateFallbackCurrentColorCount
        summary.templateFallbackCurrentNormalCount += nestedSummary.templateFallbackCurrentNormalCount
    }

    private mutating func executeCompiledDisplayListCommand(_ command: GLCompiledDisplayListCommand) throws {
        switch command {
        case .begin(let primitive):
            try context.begin(primitive)
        case .end:
            let call = try context.end()
            if context.recordDrawCall(call) {
                summary.drawCallCount += 1
            }
        case .color(let color):
            context.color(r: color.r, g: color.g, b: color.b, a: color.a)
        case .normal(let normal):
            context.normal(x: normal.x, y: normal.y, z: normal.z)
        case .vertex(let vertex):
            try context.vertex(x: vertex.x, y: vertex.y, z: vertex.z, w: vertex.w)
        case .material(let face, let parameter, let values):
            context.material(face: face, parameter: parameter, values: values)
        case .shadeModel(let model):
            context.shadeModel(model)
        }
        summary.commandCount += 1
    }

    private mutating func recordRotation(angleDegrees: Float, x: Float, y: Float, z: Float) {
        summary.rotationCount += 1
        summary.rotationSignature += angleDegrees + (x * 17) + (y * 31) + (z * 47)
        guard Self.collectsRotationTrace else {
            return
        }
        appendRotationTrace(String(format: "%.3f/%.1f,%.1f,%.1f", angleDegrees, x, y, z))
    }

    private mutating func appendRotationTrace(_ fragment: String) {
        guard !fragment.isEmpty else {
            return
        }
        if summary.rotationTrace.count >= 160 {
            return
        }
        if summary.rotationTrace.isEmpty {
            summary.rotationTrace = fragment
        } else {
            summary.rotationTrace += ";"
            summary.rotationTrace += fragment
        }
    }

    private mutating func executeDisplayListArray(payloadOffset: Int, payloadLength: Int) throws {
        try require(payloadLength, atLeast: 8)
        let count = Int(readUInt32(at: payloadOffset))
        let type = readUInt32(at: payloadOffset + 4)
        let valuesOffset = payloadOffset + 8
        let stride = try displayListNameStride(for: type)
        let requiredBytes = count * stride
        try require(payloadLength - 8, atLeast: requiredBytes)

        for index in 0..<count {
            let id = context.listBase &+ (try displayListName(at: valuesOffset, index: index, type: type, stride: stride))
            try executeDisplayList(id)
        }
    }

    private func displayListNameStride(for type: UInt32) throws -> Int {
        switch type {
        case 0x1400, 0x1401:
            return 1
        case 0x1402, 0x1403:
            return 2
        case 0x1404, 0x1405, 0x1406:
            return 4
        default:
            throw GLXRenderError.unsupportedEnum(type)
        }
    }

    private func displayListName(at offset: Int, index: Int, type: UInt32, stride: Int) throws -> UInt32 {
        let valueOffset = offset + index * stride
        switch type {
        case 0x1400:
            return UInt32(bitPattern: Int32(Int8(bitPattern: bytes[valueOffset])))
        case 0x1401:
            return UInt32(bytes[valueOffset])
        case 0x1402:
            return UInt32(bitPattern: Int32(readInt16(at: valueOffset)))
        case 0x1403:
            return UInt32(readUInt16(at: valueOffset))
        case 0x1404:
            return UInt32(bitPattern: readInt32(at: valueOffset))
        case 0x1405:
            return readUInt32(at: valueOffset)
        case 0x1406:
            return UInt32(readFloat32(at: valueOffset))
        default:
            throw GLXRenderError.unsupportedEnum(type)
        }
    }

    private func require(_ payloadLength: Int, atLeast minimum: Int) throws {
        if payloadLength < minimum {
            throw GLXRenderError.malformedCommand
        }
    }

    private func readUInt32Payload(at offset: Int, length: Int) throws -> UInt32 {
        try require(length, atLeast: 4)
        return readUInt32(at: offset)
    }

    private func primitive(_ value: UInt32) throws -> GLPrimitive {
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
        default: throw GLXRenderError.unsupportedEnum(value)
        }
    }

    private func matrixMode(_ value: UInt32) throws -> GLMatrixMode {
        switch value {
        case 0x1700: return .modelView
        case 0x1701: return .projection
        case 0x1702: return .texture
        default: throw GLXRenderError.unsupportedEnum(value)
        }
    }

    private func capability(_ value: UInt32) throws -> GLCapability {
        switch value {
        case 0x0bc0: return .alphaTest
        case 0x0d80: return .autoNormal
        case 0x0be2: return .blend
        case 0x3000...0x3005: return .clipPlane(value - 0x3000)
        case 0x0b57: return .colorMaterial
        case 0x0b44: return .cullFace
        case 0x0b71: return .depthTest
        case 0x0bd0: return .dither
        case 0x0b60: return .fog
        case 0x4000...0x4007: return .light(value - 0x4000)
        case 0x0b50: return .lighting
        case 0x0b20: return .lineSmooth
        case 0x0b24: return .lineStipple
        case 0x0ba1: return .normalize
        case 0x0b10: return .pointSmooth
        case 0x8037: return .polygonOffsetFill
        case 0x0b41: return .polygonSmooth
        case 0x0b42: return .polygonStipple
        case 0x803a: return .rescaleNormal
        case 0x0c11: return .scissorTest
        case 0x0b90: return .stencilTest
        case 0x0de0: return .texture1D
        case 0x0de1: return .texture2D
        default: throw GLXRenderError.unsupportedEnum(value)
        }
    }

    private func shadeModel(_ value: UInt32) throws -> GLShadeModel {
        guard let model = GLShadeModel(rawValue: value) else {
            throw GLXRenderError.unsupportedEnum(value)
        }
        return model
    }

    private func float32Values(at offset: Int, byteCount: Int) throws -> [Float] {
        guard byteCount > 0, byteCount % 4 == 0 else {
            throw GLXRenderError.malformedCommand
        }
        return stride(from: 0, to: byteCount, by: 4).map { readFloat32(at: offset + $0) }
    }

    private func int32Values(at offset: Int, byteCount: Int) throws -> [Int32] {
        guard byteCount > 0, byteCount % 4 == 0 else {
            throw GLXRenderError.malformedCommand
        }
        return stride(from: 0, to: byteCount, by: 4).map { readInt32(at: offset + $0) }
    }

    private func readMatrixf(at offset: Int) -> Matrix4 {
        Matrix4((0..<16).map { readFloat32(at: offset + ($0 * 4)) })
    }

    private func readMatrixd(at offset: Int) -> Matrix4 {
        Matrix4((0..<16).map { Float(readFloat64(at: offset + ($0 * 8))) })
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        let b0 = UInt16(bytes[offset])
        let b1 = UInt16(bytes[offset + 1])
        switch byteOrder {
        case .littleEndian:
            return b0 | (b1 << 8)
        case .bigEndian:
            return (b0 << 8) | b1
        }
    }

    private func readInt16(at offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(at: offset))
    }

    private func readUInt32(at offset: Int) -> UInt32 {
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

    private func readInt32(at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(at: offset))
    }

    private func readUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            let byte = UInt64(bytes[offset + i])
            switch byteOrder {
            case .littleEndian:
                value |= byte << UInt64(i * 8)
            case .bigEndian:
                value |= byte << UInt64((7 - i) * 8)
            }
        }
        return value
    }

    private func readFloat32(at offset: Int) -> Float {
        Float(bitPattern: readUInt32(at: offset))
    }

    private func readFloat64(at offset: Int) -> Double {
        Double(bitPattern: readUInt64(at: offset))
    }
}
