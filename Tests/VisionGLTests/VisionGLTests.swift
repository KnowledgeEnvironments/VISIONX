// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Testing
@testable import VisionGL

@Test
func matrixStackAppliesOpenGLStylePostMultiplication() {
    let context = VisionGLContext()

    context.translate(x: 2, y: 3, z: 4)
    context.scale(x: 10, y: 10, z: 10)

    let matrix = context.currentMatrix(for: .modelView)
    #expect(matrix[0, 3] == 2)
    #expect(matrix[1, 3] == 3)
    #expect(matrix[2, 3] == 4)
    #expect(matrix[0, 0] == 10)
}

@Test
func immediateModeCapturesCurrentFixedFunctionState() throws {
    let context = VisionGLContext()
    context.enable(.depthTest)
    context.enable(.texture2D)
    context.color(r: 1, g: 0, b: 0, a: 1)
    context.textureCoordinate(s: 0.25, t: 0.75)

    try context.begin(.triangles)
    try context.vertex(x: 0, y: 0, z: 0)
    try context.vertex(x: 1, y: 0, z: 0)
    try context.vertex(x: 0, y: 1, z: 0)
    let call = try context.end()

    #expect(call.primitive == .triangles)
    #expect(call.vertices.count == 3)
    #expect(call.vertices[0].color == GLColor(r: 1, g: 0, b: 0, a: 1))
    #expect(call.vertices[0].textureCoordinate.x == 0.25)
    #expect(call.pipelineKey.textureEnabled)
    #expect(call.pipelineKey.enabledCapabilities.contains(.depthTest))
    #expect(call.stateSnapshot.enabledCapabilities.contains(.texture2D))
}

@Test
func glxRegistryTracksMakeCurrentAndSwapBuffers() throws {
    let registry = VisionGLXRegistry()
    let recorder = GLXEventRecorder()
    registry.onEvent = { recorder.events.append($0) }

    try registry.createContext(id: 100, visualID: 0x21)
    try registry.createWindowDrawable(id: 200, windowID: 200, visualID: 0x21, width: 640, height: 480)
    try registry.makeCurrent(context: 100, drawable: 200)
        try registry.swapBuffers(context: 100, drawable: 200)

    #expect(registry.currentContext == 100)
    #expect(registry.currentDrawable == 200)
    #expect(recorder.events == [
        .contextCreated(100),
        .drawableCreated(200),
        .madeCurrent(context: 100, drawable: 200),
        .swapBuffers(drawable: 200)
    ])
}

@Test
func glxRegistryTracksDrawableBackBuffersAndResize() throws {
    let registry = VisionGLXRegistry()
    let recorder = GLXEventRecorder()
    registry.onEvent = { recorder.events.append($0) }

    try registry.createWindowDrawable(id: 300, windowID: 0x4a, visualID: 0x21, width: 320, height: 240)

    let initial = try #require(registry.drawables[300])
    #expect(initial.kind == .window(0x4a))
    #expect(initial.backBuffer.colorFormat == .bgra8Unorm)
    #expect(initial.backBuffer.bytesPerRow == 1_280)
    #expect(initial.backBuffer.byteCount == 307_200)
    #expect(initial.backBuffer.depthBits == 24)
    #expect(initial.backBuffer.stencilBits == 8)

    try registry.resizeDrawable(id: 300, width: 800, height: 600)

    let resized = try #require(registry.drawables[300])
    #expect(resized.width == 800)
    #expect(resized.height == 600)
    #expect(resized.backBuffer.bytesPerRow == 3_200)
    #expect(resized.backBuffer.byteCount == 1_920_000)
    #expect(recorder.events == [
        .drawableCreated(300),
        .drawableResized(drawable: 300, width: 800, height: 600)
    ])
}

@Test
func glxRegistryRejectsMakeCurrentForUnknownDrawable() throws {
    let registry = VisionGLXRegistry()

    try registry.createContext(id: 400, visualID: 0x21)

    do {
        try registry.makeCurrent(context: 400, drawable: 401)
        Issue.record("makeCurrent unexpectedly accepted an unknown drawable")
    } catch let error as GLXRegistryError {
        #expect(error == .unknownDrawable(401))
    }
}

@Test
func glxRenderDecoderCapturesImmediateTriangle() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 500, visualID: 0x21)

    var commands: [UInt8] = []
    commands += renderCommand(130, floats32(0.1, 0.2, 0.3, 1))
    commands += renderCommand(127, uint32s(0x00004000))
    commands += renderCommand(4, uint32s(0x0004))
    commands += renderCommand(16, floats32(1, 0, 0, 1))
    commands += renderCommand(70, floats32(0, 0, 0))
    commands += renderCommand(70, floats32(1, 0, 0))
    commands += renderCommand(70, floats32(0, 1, 0))
    commands += renderCommand(23, [])

    let summary = try commands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 500, bytes: $0, byteOrder: .littleEndian)
    }
    let context = try #require(registry.contexts[500]?.context)
    let drawCall = try #require(context.completedDrawCalls.first)

    #expect(summary == GLXRenderExecutionSummary(commandCount: 8, drawCallCount: 1, clearCount: 1))
    #expect(context.clearRequests == [GLClearRequest(mask: 0x00004000, color: GLColor(r: 0.1, g: 0.2, b: 0.3, a: 1))])
    #expect(drawCall.primitive == .triangles)
    #expect(drawCall.vertices.count == 3)
    #expect(drawCall.vertices[0].color == GLColor(r: 1, g: 0, b: 0, a: 1))
}

@Test
func glxRenderDecoderCaptures2DVertexVariants() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 508, visualID: 0x21)

    var commands: [UInt8] = []
    commands += renderCommand(4, uint32s(0x0000))
    commands += renderCommand(65, floats64(0.5, 1.5))
    commands += renderCommand(66, floats32(2.5, 3.5))
    commands += renderCommand(67, uint32s(4, 5))
    commands += renderCommand(68, uint16s(6, 7))
    commands += renderCommand(23, [])

    let summary = try commands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 508, bytes: $0, byteOrder: .littleEndian)
    }
    let context = try #require(registry.contexts[508]?.context)
    let drawCall = try #require(context.completedDrawCalls.first)

    #expect(summary == GLXRenderExecutionSummary(commandCount: 6, drawCallCount: 1, clearCount: 0))
    #expect(drawCall.primitive == .points)
    #expect(drawCall.vertices.map(\.position) == [
        SIMD4<Float>(0.5, 1.5, 0, 1),
        SIMD4<Float>(2.5, 3.5, 0, 1),
        SIMD4<Float>(4, 5, 0, 1),
        SIMD4<Float>(6, 7, 0, 1)
    ])
}

@Test
func glxRenderDecoderHandlesBigEndianViewport() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 501, visualID: 0x21)

    let commands = renderCommand(191, uint32s(10, 20, 640, 480, byteOrder: .bigEndian), byteOrder: .bigEndian)
    let summary = try commands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 501, bytes: $0, byteOrder: .bigEndian)
    }
    let context = try #require(registry.contexts[501]?.context)

    #expect(summary == GLXRenderExecutionSummary(commandCount: 1, drawCallCount: 0, clearCount: 0))
    #expect(context.state.viewport == GLViewport(x: 10, y: 20, width: 640, height: 480))
}

@Test
func glxRenderDecoderRecordsLightingMaterialAndMatrixState() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 503, visualID: 0x21)

    var commands: [UInt8] = []
    commands += renderCommand(179, uint32s(0x1701))
    commands += renderCommand(184, [])
    commands += renderCommand(175, floats64(-1, 1, -1, 1, 1, 10))
    commands += renderCommand(183, [])
    commands += renderCommand(87, uint32s(0x4000, 0x1200) + floats32(1, 0.5, 0.25, 1))
    commands += renderCommand(97, uint32s(0x0408, 0x1201) + floats32(0.8, 0.7, 0.6, 1))
    commands += renderCommand(97, uint32s(0x0408, 0x1602) + floats32(0.4, 0.3, 0.2, 1))
    commands += renderCommand(104, uint32s(0x1d00))

    let summary = try commands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 503, bytes: $0, byteOrder: .littleEndian)
    }
    let context = try #require(registry.contexts[503]?.context)

    #expect(summary == GLXRenderExecutionSummary(commandCount: 8, drawCallCount: 0, clearCount: 0))
    #expect(context.currentMatrix(for: .projection) == .identity)
    #expect(context.state.lightParameters[GLLightStateKey(light: 0x4000, parameter: 0x1200)] == [1, 0.5, 0.25, 1])
    #expect(context.state.materialParameters[GLMaterialStateKey(face: 0x0408, parameter: 0x1200)] == [0.4, 0.3, 0.2, 1])
    #expect(context.state.materialParameters[GLMaterialStateKey(face: 0x0408, parameter: 0x1201)] == [0.4, 0.3, 0.2, 1])
    #expect(context.state.shadeModel == .flat)
}

@Test
func contextDrainsPerFrameDrawAndClearCommands() throws {
    let context = VisionGLContext()

    context.clearColor(r: 0, g: 0, b: 0, a: 1)
    context.clear(mask: 0x00004000)
    try context.begin(.triangles)
    try context.vertex(x: 0, y: 0, z: 0)
    try context.vertex(x: 1, y: 0, z: 0)
    try context.vertex(x: 0, y: 1, z: 0)
    context.recordDrawCall(try context.end())

    let snapshot = context.frameCommandsSnapshot()
    #expect(snapshot.drawCalls.count == 1)
    #expect(snapshot.clearRequests.count == 1)
    #expect(context.completedDrawCalls.count == 1)

    let drained = context.drainFrameCommands()
    #expect(drained == snapshot)
    #expect(context.completedDrawCalls.isEmpty)
    #expect(context.clearRequests.isEmpty)
}

@Test
func glxRenderDecoderRecordsCommonFixedFunctionCapabilities() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 504, visualID: 0x21)

    var commands: [UInt8] = []
    commands += renderCommand(139, uint32s(0x4000))
    commands += renderCommand(139, uint32s(0x0ba1))
    commands += renderCommand(139, uint32s(0x0b57))
    commands += renderCommand(138, uint32s(0x4000))

    let summary = try commands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 504, bytes: $0, byteOrder: .littleEndian)
    }
    let context = try #require(registry.contexts[504]?.context)

    #expect(summary == GLXRenderExecutionSummary(commandCount: 4, drawCallCount: 0, clearCount: 0))
    #expect(!context.state.enabledCapabilities.contains(.light(0)))
    #expect(context.state.enabledCapabilities.contains(.normalize))
    #expect(context.state.enabledCapabilities.contains(.colorMaterial))
}

@Test
func glxRenderDecoderRecordsAndReplaysDisplayLists() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 505, visualID: 0x21)

    let firstList = try registry.generateDisplayLists(context: 505, range: 1)
    #expect(firstList == 1)

    try registry.beginDisplayList(context: 505, list: firstList, mode: 0x1300)
    var listCommands: [UInt8] = []
    listCommands += renderCommand(130, floats32(0.1, 0.2, 0.3, 1))
    listCommands += renderCommand(127, uint32s(0x00004000))
    listCommands += renderCommand(4, uint32s(0x0004))
    listCommands += renderCommand(16, floats32(1, 0, 0, 1))
    listCommands += renderCommand(70, floats32(0, 0, 0))
    listCommands += renderCommand(70, floats32(1, 0, 0))
    listCommands += renderCommand(70, floats32(0, 1, 0))
    listCommands += renderCommand(23, [])

    let compileSummary = try listCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 505, bytes: $0, byteOrder: .littleEndian)
    }
    try registry.endDisplayList(context: 505)
    let context = try #require(registry.contexts[505]?.context)

    #expect(compileSummary == GLXRenderExecutionSummary(commandCount: 8, drawCallCount: 0, clearCount: 0))
    #expect(context.displayLists[firstList]?.commands.count == 8)
    #expect(context.completedDrawCalls.isEmpty)
    #expect(context.clearRequests.isEmpty)

    let replayCommands = renderCommand(1, uint32s(firstList))
    let replaySummary = try replayCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 505, bytes: $0, byteOrder: .littleEndian)
    }

    #expect(replaySummary == GLXRenderExecutionSummary(
        commandCount: 9,
        drawCallCount: 1,
        clearCount: 1,
        templatedDrawCallCount: 1
    ))
    #expect(context.completedDrawCalls.count == 1)
    #expect(context.clearRequests == [GLClearRequest(mask: 0x00004000, color: GLColor(r: 0.1, g: 0.2, b: 0.3, a: 1))])
}

@Test
func glxRenderDecoderCompilesDisplayListDrawTemplates() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 515, visualID: 0x21)

    let list = try registry.generateDisplayLists(context: 515, range: 1)
    try registry.beginDisplayList(context: 515, list: list, mode: 0x1300)
    var listCommands: [UInt8] = []
    listCommands += renderCommand(4, uint32s(0x0004))
    listCommands += renderCommand(30, floats32(0, 0, 1))
    listCommands += renderCommand(70, floats32(1, 0, 0))
    listCommands += renderCommand(70, floats32(0, 1, 0))
    listCommands += renderCommand(70, floats32(0, 0, 0))
    listCommands += renderCommand(23, [])
    _ = try listCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 515, bytes: $0, byteOrder: .littleEndian)
    }
    try registry.endDisplayList(context: 515)

    let context = try #require(registry.contexts[515]?.context)
    let compiledList = try #require(context.displayList(id: list))
    #expect(compiledList.executionSteps.count == 1)

    guard case .drawTemplate(let template, let fallback) = compiledList.executionSteps[0] else {
        Issue.record("Display list geometry block was not compiled into a draw template")
        return
    }
    #expect(template.primitive == .triangles)
    #expect(template.vertices.count == 3)
    #expect(template.commandCount == 6)
    #expect(fallback.count == 6)
    #expect(template.usesReplayCurrentColor)
    #expect(!template.usesReplayCurrentNormal)
}

@Test
func glxRenderDecoderFallsBackForExternalColorWhenLightingIsDisabled() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 516, visualID: 0x21)

    let list = try registry.generateDisplayLists(context: 516, range: 1)
    try registry.beginDisplayList(context: 516, list: list, mode: 0x1300)
    var listCommands: [UInt8] = []
    listCommands += renderCommand(4, uint32s(0x0004))
    listCommands += renderCommand(70, floats32(1, 0, 0))
    listCommands += renderCommand(70, floats32(0, 1, 0))
    listCommands += renderCommand(70, floats32(0, 0, 0))
    listCommands += renderCommand(23, [])
    _ = try listCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 516, bytes: $0, byteOrder: .littleEndian)
    }
    try registry.endDisplayList(context: 516)

    var replayCommands: [UInt8] = []
    replayCommands += renderCommand(16, floats32(0, 1, 0, 1))
    replayCommands += renderCommand(1, uint32s(list))
    let summary = try replayCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 516, bytes: $0, byteOrder: .littleEndian)
    }
    let context = try #require(registry.contexts[516]?.context)
    let drawCall = try #require(context.completedDrawCalls.last)

    #expect(summary == GLXRenderExecutionSummary(
        commandCount: 7,
        drawCallCount: 1,
        clearCount: 0,
        templateFallbackCount: 1,
        templateFallbackCurrentColorCount: 1
    ))
    #expect(drawCall.vertices.allSatisfy { $0.color == GLColor(r: 0, g: 1, b: 0, a: 1) })
}

@Test
func glxRenderDecoderUsesTemplatesForLitMaterialDisplayListGeometry() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 517, visualID: 0x21)

    let list = try registry.generateDisplayLists(context: 517, range: 1)
    try registry.beginDisplayList(context: 517, list: list, mode: 0x1300)
    var listCommands: [UInt8] = []
    listCommands += renderCommand(30, floats32(0, 0, 1))
    listCommands += renderCommand(4, uint32s(0x0004))
    listCommands += renderCommand(70, floats32(1, 0, 0))
    listCommands += renderCommand(70, floats32(0, 1, 0))
    listCommands += renderCommand(70, floats32(0, 0, 0))
    listCommands += renderCommand(23, [])
    _ = try listCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 517, bytes: $0, byteOrder: .littleEndian)
    }
    try registry.endDisplayList(context: 517)

    var replayCommands: [UInt8] = []
    replayCommands += renderCommand(139, uint32s(0x0b50))
    replayCommands += renderCommand(97, uint32s(0x0408, 0x1602) + floats32(0.8, 0.1, 0.2, 1))
    replayCommands += renderCommand(16, floats32(0, 1, 0, 1))
    replayCommands += renderCommand(1, uint32s(list))
    let summary = try replayCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 517, bytes: $0, byteOrder: .littleEndian)
    }
    let context = try #require(registry.contexts[517]?.context)
    let drawCall = try #require(context.completedDrawCalls.last)

    #expect(summary == GLXRenderExecutionSummary(
        commandCount: 10,
        drawCallCount: 1,
        clearCount: 0,
        templatedDrawCallCount: 1
    ))
    #expect(drawCall.vertices.allSatisfy { $0.color == GLColor(r: 0, g: 1, b: 0, a: 1) })
    #expect(drawCall.stateSnapshot.materialParameters[GLMaterialStateKey(face: 0x0408, parameter: 0x1201)] == [0.8, 0.1, 0.2, 1])
    #expect(drawCall.stateSnapshot.enabledCapabilities.contains(.lighting))
}

@Test
func glxRenderDecoderTemplatesReplayCurrentNormalForLitGeometry() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 518, visualID: 0x21)

    let list = try registry.generateDisplayLists(context: 518, range: 1)
    try registry.beginDisplayList(context: 518, list: list, mode: 0x1300)
    var listCommands: [UInt8] = []
    listCommands += renderCommand(4, uint32s(0x0004))
    listCommands += renderCommand(70, floats32(1, 0, 0))
    listCommands += renderCommand(70, floats32(0, 1, 0))
    listCommands += renderCommand(70, floats32(0, 0, 0))
    listCommands += renderCommand(23, [])
    _ = try listCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 518, bytes: $0, byteOrder: .littleEndian)
    }
    try registry.endDisplayList(context: 518)

    var replayCommands: [UInt8] = []
    replayCommands += renderCommand(139, uint32s(0x0b50))
    replayCommands += renderCommand(30, floats32(0, 1, 0))
    replayCommands += renderCommand(1, uint32s(list))
    let summary = try replayCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 518, bytes: $0, byteOrder: .littleEndian)
    }
    let context = try #require(registry.contexts[518]?.context)
    let drawCall = try #require(context.completedDrawCalls.last)

    #expect(summary == GLXRenderExecutionSummary(
        commandCount: 8,
        drawCallCount: 1,
        clearCount: 0,
        templatedDrawCallCount: 1
    ))
    #expect(drawCall.vertices.allSatisfy { $0.normal == SIMD3<Float>(0, 1, 0) })
    #expect(context.state.currentNormal == SIMD3<Float>(0, 1, 0))
}

@Test
func glxRenderDecoderReplaysCallListsWithListBase() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 506, visualID: 0x21)

    try registry.beginDisplayList(context: 506, list: 0x22, mode: 0x1301)
    let drawCommands = renderCommand(4, uint32s(0x0001)) +
        renderCommand(70, floats32(0, 0, 0)) +
        renderCommand(70, floats32(1, 0, 0)) +
        renderCommand(23, [])
    _ = try drawCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 506, bytes: $0, byteOrder: .littleEndian)
    }
    try registry.endDisplayList(context: 506)
    let context = try #require(registry.contexts[506]?.context)
    #expect(context.completedDrawCalls.count == 1)

    var callCommands: [UInt8] = []
    callCommands += renderCommand(3, uint32s(0x20))
    callCommands += renderCommand(2, uint32s(1, 0x1405, 0x02))
    let summary = try callCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 506, bytes: $0, byteOrder: .littleEndian)
    }

    #expect(summary == GLXRenderExecutionSummary(
        commandCount: 6,
        drawCallCount: 1,
        clearCount: 0,
        templateFallbackCount: 1,
        templateFallbackCurrentColorCount: 1
    ))
    #expect(context.completedDrawCalls.count == 2)
    try registry.deleteDisplayLists(context: 506, list: 0x22, range: 1)
    #expect(context.displayList(id: 0x22) == nil)
}

@Test
func glxRenderDecoderAppliesChangingRotationBeforeDisplayListReplay() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 507, visualID: 0x21)

    let list = try registry.generateDisplayLists(context: 507, range: 1)
    try registry.beginDisplayList(context: 507, list: list, mode: 0x1300)
    var listCommands: [UInt8] = []
    listCommands += renderCommand(4, uint32s(0x0004))
    listCommands += renderCommand(70, floats32(1, 0, 0))
    listCommands += renderCommand(70, floats32(0, 1, 0))
    listCommands += renderCommand(70, floats32(0, 0, 0))
    listCommands += renderCommand(23, [])

    _ = try listCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 507, bytes: $0, byteOrder: .littleEndian)
    }
    try registry.endDisplayList(context: 507)
    let context = try #require(registry.contexts[507]?.context)

    var firstReplay: [UInt8] = []
    firstReplay += renderCommand(176, [])
    firstReplay += renderCommand(186, floats32(0, 0, 0, 1))
    firstReplay += renderCommand(1, uint32s(list))
    let firstSummary = try firstReplay.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 507, bytes: $0, byteOrder: .littleEndian)
    }
    let firstMatrix = try #require(context.completedDrawCalls.last?.modelViewMatrix)

    context.clearFrameCommands()

    var secondReplay: [UInt8] = []
    secondReplay += renderCommand(176, [])
    secondReplay += renderCommand(186, floats32(90, 0, 0, 1))
    secondReplay += renderCommand(1, uint32s(list))
    let secondSummary = try secondReplay.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 507, bytes: $0, byteOrder: .littleEndian)
    }
    let secondMatrix = try #require(context.completedDrawCalls.last?.modelViewMatrix)

    #expect(firstSummary.rotationCount == 1)
    #expect(firstSummary.rotationSignature == 47)
    #expect(secondSummary.rotationCount == 1)
    #expect(secondSummary.rotationSignature == 137)
    #expect(firstMatrix[0, 0] == 1)
    #expect(abs(secondMatrix[0, 0]) < 0.0001)
    #expect(abs(secondMatrix[1, 0] - 1) < 0.0001)
}

@Test
func glxRenderDecoderReplaysDisplayListsWithPerFrameModelViewTransform() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 509, visualID: 0x21)

    let list = try registry.generateDisplayLists(context: 509, range: 1)
    try registry.beginDisplayList(context: 509, list: list, mode: 0x1300)
    var listCommands: [UInt8] = []
    listCommands += renderCommand(4, uint32s(0x0004))
    listCommands += renderCommand(70, floats32(1, 0, 0))
    listCommands += renderCommand(70, floats32(0, 1, 0))
    listCommands += renderCommand(70, floats32(0, 0, 0))
    listCommands += renderCommand(23, [])
    _ = try listCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 509, bytes: $0, byteOrder: .littleEndian)
    }
    try registry.endDisplayList(context: 509)
    let context = try #require(registry.contexts[509]?.context)

    var firstFrame: [UInt8] = []
    firstFrame += renderCommand(176, [])
    firstFrame += renderCommand(186, floats32(0, 0, 0, 1))
    firstFrame += renderCommand(1, uint32s(list))
    _ = try firstFrame.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 509, bytes: $0, byteOrder: .littleEndian)
    }
    let firstCall = try #require(context.completedDrawCalls.last)
    let firstVertex = transform(firstCall.vertices[0].position, by: firstCall.modelViewMatrix)

    context.clearFrameCommands()

    var secondFrame: [UInt8] = []
    secondFrame += renderCommand(176, [])
    secondFrame += renderCommand(186, floats32(90, 0, 0, 1))
    secondFrame += renderCommand(1, uint32s(list))
    _ = try secondFrame.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 509, bytes: $0, byteOrder: .littleEndian)
    }
    let secondCall = try #require(context.completedDrawCalls.last)
    let secondVertex = transform(secondCall.vertices[0].position, by: secondCall.modelViewMatrix)

    #expect(abs(firstVertex.x - 1) < 0.0001)
    #expect(abs(firstVertex.y) < 0.0001)
    #expect(abs(secondVertex.x) < 0.0001)
    #expect(abs(secondVertex.y - 1) < 0.0001)
}

@Test
func glxRenderDecoderProducesProjectedMotionForGlxgearsStyleFrame() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 510, visualID: 0x21)

    let list = try registry.generateDisplayLists(context: 510, range: 1)
    try registry.beginDisplayList(context: 510, list: list, mode: 0x1300)
    var listCommands: [UInt8] = []
    listCommands += renderCommand(4, uint32s(0x0004))
    listCommands += renderCommand(70, floats32(1.0, 0.0, 0.0))
    listCommands += renderCommand(70, floats32(2.5, 0.4, 0.0))
    listCommands += renderCommand(70, floats32(0.8, 1.3, 0.0))
    listCommands += renderCommand(23, [])
    _ = try listCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 510, bytes: $0, byteOrder: .littleEndian)
    }
    try registry.endDisplayList(context: 510)

    let context = try #require(registry.contexts[510]?.context)
    let firstFrame = glxgearsStyleFrameCommands(list: list, angle: 0)
    let firstSummary = try firstFrame.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 510, bytes: $0, byteOrder: .littleEndian)
    }
    let firstCall = try #require(context.completedDrawCalls.last)
    let firstSignature = projectedSignature(firstCall)

    context.clearFrameCommands()

    let secondFrame = glxgearsStyleFrameCommands(list: list, angle: 90)
    let secondSummary = try secondFrame.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 510, bytes: $0, byteOrder: .littleEndian)
    }
    let secondCall = try #require(context.completedDrawCalls.last)
    let secondSignature = projectedSignature(secondCall)

    #expect(firstSummary.drawCallCount == 1)
    #expect(secondSummary.drawCallCount == 1)
    #expect(firstSummary.rotationCount == 3)
    #expect(secondSummary.rotationCount == 3)
    #expect(abs(secondSignature - firstSignature) > 0.01)
}

@Test
func glxRenderDecoderCanApplyStateWithoutCapturingDrawCalls() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 508, visualID: 0x21)

    let stateList = try registry.generateDisplayLists(context: 508, range: 1)
    try registry.beginDisplayList(context: 508, list: stateList, mode: 0x1300)
    let stateCommands = renderCommand(97, uint32s(0x0408, 0x1602) + floats32(0.2, 0.3, 0.4, 1))
    _ = try stateCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 508, bytes: $0, byteOrder: .littleEndian)
    }
    try registry.endDisplayList(context: 508)

    let list = try registry.generateDisplayLists(context: 508, range: 1)
    #expect(list == stateList + 1)
    try registry.beginDisplayList(context: 508, list: list, mode: 0x1300)
    var listCommands: [UInt8] = []
    listCommands += renderCommand(97, uint32s(0x0408, 0x1602) + floats32(0.8, 0.1, 0.2, 1))
    listCommands += renderCommand(4, uint32s(0x0004))
    listCommands += renderCommand(70, floats32(1, 0, 0))
    listCommands += renderCommand(70, floats32(0, 1, 0))
    listCommands += renderCommand(70, floats32(0, 0, 0))
    listCommands += renderCommand(23, [])
    _ = try listCommands.withUnsafeBufferPointer {
        try registry.executeRenderCommands(context: 508, bytes: $0, byteOrder: .littleEndian)
    }
    try registry.endDisplayList(context: 508)

    var skippedFrame: [UInt8] = []
    skippedFrame += renderCommand(130, floats32(0.1, 0.2, 0.3, 1))
    skippedFrame += renderCommand(127, uint32s(0x00004000))
    skippedFrame += renderCommand(1, uint32s(stateList))
    skippedFrame += renderCommand(176, [])
    skippedFrame += renderCommand(186, floats32(90, 0, 0, 1))
    skippedFrame += renderCommand(1, uint32s(list))

    let skippedSummary = try skippedFrame.withUnsafeBufferPointer {
        try registry.executeRenderCommands(
            context: 508,
            bytes: $0,
            byteOrder: .littleEndian,
            captureDrawCalls: false
        )
    }
    let context = try #require(registry.contexts[508]?.context)

    #expect(skippedSummary.commandCount == 7)
    #expect(skippedSummary.drawCallCount == 0)
    #expect(skippedSummary.clearCount == 0)
    #expect(skippedSummary.rotationCount == 1)
    #expect(skippedSummary.skippedDisplayListCount == 1)
    #expect(context.completedDrawCalls.isEmpty)
    #expect(context.clearRequests.isEmpty)
    #expect(context.state.materialParameters[GLMaterialStateKey(face: 0x0408, parameter: 0x1201)] == [0.2, 0.3, 0.4, 1])

    var capturedFrame: [UInt8] = []
    capturedFrame += renderCommand(176, [])
    capturedFrame += renderCommand(186, floats32(45, 0, 0, 1))
    capturedFrame += renderCommand(1, uint32s(list))

    let capturedSummary = try capturedFrame.withUnsafeBufferPointer {
        try registry.executeRenderCommands(
            context: 508,
            bytes: $0,
            byteOrder: .littleEndian,
            captureDrawCalls: true
        )
    }
    let drawCall = try #require(context.completedDrawCalls.first)

    #expect(capturedSummary.drawCallCount == 1)
    #expect(drawCall.vertices.count == 3)
    #expect(drawCall.stateSnapshot.materialParameters[GLMaterialStateKey(face: 0x0408, parameter: 0x1201)] == [0.8, 0.1, 0.2, 1])
}

@Test
func glxRenderDecoderRejectsUnsupportedOpcode() throws {
    let registry = VisionGLXRegistry()
    try registry.createContext(id: 502, visualID: 0x21)

    let commands = renderCommand(999, [])
    do {
        _ = try commands.withUnsafeBufferPointer {
            try registry.executeRenderCommands(context: 502, bytes: $0, byteOrder: .littleEndian)
        }
        Issue.record("GLX render decoder unexpectedly accepted an unsupported opcode")
    } catch let error as GLXRenderError {
        #expect(error == .unsupportedOpcode(999))
    }
}

private final class GLXEventRecorder: @unchecked Sendable {
    var events: [GLXRegistryEvent] = []
}

private func renderCommand(_ opcode: UInt16, _ payload: [UInt8], byteOrder: GLXRenderByteOrder = .littleEndian) -> [UInt8] {
    var paddedPayload = payload
    while (4 + paddedPayload.count) % 4 != 0 {
        paddedPayload.append(0)
    }

    var bytes: [UInt8] = []
    bytes += uint16s(UInt16(4 + paddedPayload.count), opcode, byteOrder: byteOrder)
    bytes += paddedPayload
    return bytes
}

private func uint16s(_ values: UInt16..., byteOrder: GLXRenderByteOrder = .littleEndian) -> [UInt8] {
    values.flatMap { value in
        switch byteOrder {
        case .littleEndian:
            return [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
        case .bigEndian:
            return [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        }
    }
}

private func uint32s(_ values: UInt32..., byteOrder: GLXRenderByteOrder = .littleEndian) -> [UInt8] {
    uint32s(values, byteOrder: byteOrder)
}

private func uint32s(_ values: [UInt32], byteOrder: GLXRenderByteOrder = .littleEndian) -> [UInt8] {
    values.flatMap { value in
        switch byteOrder {
        case .littleEndian:
            return [
                UInt8(value & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 24) & 0xff)
            ]
        case .bigEndian:
            return [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff)
            ]
        }
    }
}

private func floats32(_ values: Float..., byteOrder: GLXRenderByteOrder = .littleEndian) -> [UInt8] {
    uint32s(values.map(\.bitPattern), byteOrder: byteOrder)
}

private func floats64(_ values: Double..., byteOrder: GLXRenderByteOrder = .littleEndian) -> [UInt8] {
    values.flatMap { value in
        let bitPattern = value.bitPattern
        switch byteOrder {
        case .littleEndian:
            return (0..<8).map { UInt8((bitPattern >> UInt64($0 * 8)) & 0xff) }
        case .bigEndian:
            return (0..<8).map { UInt8((bitPattern >> UInt64((7 - $0) * 8)) & 0xff) }
        }
    }
}

private func glxgearsStyleFrameCommands(list: UInt32, angle: Float) -> [UInt8] {
    var commands: [UInt8] = []
    commands += renderCommand(179, uint32s(0x1701))
    commands += renderCommand(176, [])
    commands += renderCommand(175, floats64(-1, 1, -0.75, 0.75, 5, 60))
    commands += renderCommand(179, uint32s(0x1700))
    commands += renderCommand(176, [])
    commands += renderCommand(190, floats32(0, 0, -40))
    commands += renderCommand(184, [])
    commands += renderCommand(186, floats32(20, 1, 0, 0))
    commands += renderCommand(186, floats32(30, 0, 1, 0))
    commands += renderCommand(190, floats32(-3, -2, 0))
    commands += renderCommand(186, floats32(angle, 0, 0, 1))
    commands += renderCommand(1, uint32s(list))
    commands += renderCommand(183, [])
    return commands
}

private func projectedSignature(_ call: ImmediateDrawCall) -> Float {
    let transformMatrix = call.projectionMatrix * call.modelViewMatrix
    var signature: Float = 0
    for (index, vertex) in call.vertices.enumerated() {
        let clip = transform(vertex.position, by: transformMatrix)
        guard clip.w.isFinite, abs(clip.w) > 0.000001 else {
            continue
        }
        let projectedX = clip.x / clip.w
        let projectedY = clip.y / clip.w
        guard projectedX.isFinite, projectedY.isFinite else {
            continue
        }
        let weight = Float(index + 1)
        signature += projectedX * weight + projectedY * (weight + 3)
    }
    return signature
}

private func transform(_ vector: SIMD4<Float>, by matrix: Matrix4) -> SIMD4<Float> {
    SIMD4<Float>(
        matrix[0, 0] * vector.x + matrix[0, 1] * vector.y + matrix[0, 2] * vector.z + matrix[0, 3] * vector.w,
        matrix[1, 0] * vector.x + matrix[1, 1] * vector.y + matrix[1, 2] * vector.z + matrix[1, 3] * vector.w,
        matrix[2, 0] * vector.x + matrix[2, 1] * vector.y + matrix[2, 2] * vector.z + matrix[2, 3] * vector.w,
        matrix[3, 0] * vector.x + matrix[3, 1] * vector.y + matrix[3, 2] * vector.z + matrix[3, 3] * vector.w
    )
}
