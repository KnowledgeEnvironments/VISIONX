// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation

public struct Matrix4: Equatable, Sendable {
    public var storage: [Float]

    public init(_ storage: [Float]) {
        precondition(storage.count == 16, "Matrix4 requires exactly 16 values")
        self.storage = storage
    }

    public static let identity = Matrix4([
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    ])

    public subscript(row: Int, column: Int) -> Float {
        get { storage[column * 4 + row] }
        set { storage[column * 4 + row] = newValue }
    }

    public static func * (lhs: Matrix4, rhs: Matrix4) -> Matrix4 {
        let l = lhs.storage
        let r = rhs.storage
        return Matrix4([
            l[0] * r[0] + l[4] * r[1] + l[8] * r[2] + l[12] * r[3],
            l[1] * r[0] + l[5] * r[1] + l[9] * r[2] + l[13] * r[3],
            l[2] * r[0] + l[6] * r[1] + l[10] * r[2] + l[14] * r[3],
            l[3] * r[0] + l[7] * r[1] + l[11] * r[2] + l[15] * r[3],

            l[0] * r[4] + l[4] * r[5] + l[8] * r[6] + l[12] * r[7],
            l[1] * r[4] + l[5] * r[5] + l[9] * r[6] + l[13] * r[7],
            l[2] * r[4] + l[6] * r[5] + l[10] * r[6] + l[14] * r[7],
            l[3] * r[4] + l[7] * r[5] + l[11] * r[6] + l[15] * r[7],

            l[0] * r[8] + l[4] * r[9] + l[8] * r[10] + l[12] * r[11],
            l[1] * r[8] + l[5] * r[9] + l[9] * r[10] + l[13] * r[11],
            l[2] * r[8] + l[6] * r[9] + l[10] * r[10] + l[14] * r[11],
            l[3] * r[8] + l[7] * r[9] + l[11] * r[10] + l[15] * r[11],

            l[0] * r[12] + l[4] * r[13] + l[8] * r[14] + l[12] * r[15],
            l[1] * r[12] + l[5] * r[13] + l[9] * r[14] + l[13] * r[15],
            l[2] * r[12] + l[6] * r[13] + l[10] * r[14] + l[14] * r[15],
            l[3] * r[12] + l[7] * r[13] + l[11] * r[14] + l[15] * r[15]
        ])
    }

    public static func translation(x: Float, y: Float, z: Float) -> Matrix4 {
        var matrix = Matrix4.identity
        matrix[0, 3] = x
        matrix[1, 3] = y
        matrix[2, 3] = z
        return matrix
    }

    public static func scale(x: Float, y: Float, z: Float) -> Matrix4 {
        var matrix = Matrix4.identity
        matrix[0, 0] = x
        matrix[1, 1] = y
        matrix[2, 2] = z
        return matrix
    }

    public static func rotation(angleDegrees: Float, x: Float, y: Float, z: Float) -> Matrix4 {
        let length = sqrt(x * x + y * y + z * z)
        guard length > 0 else {
            return .identity
        }

        let radians = angleDegrees * .pi / 180
        let c = cos(radians)
        let s = sin(radians)
        let oneMinusC = 1 - c
        let nx = x / length
        let ny = y / length
        let nz = z / length

        return Matrix4([
            c + nx * nx * oneMinusC,
            ny * nx * oneMinusC + nz * s,
            nz * nx * oneMinusC - ny * s,
            0,

            nx * ny * oneMinusC - nz * s,
            c + ny * ny * oneMinusC,
            nz * ny * oneMinusC + nx * s,
            0,

            nx * nz * oneMinusC + ny * s,
            ny * nz * oneMinusC - nx * s,
            c + nz * nz * oneMinusC,
            0,

            0, 0, 0, 1
        ])
    }

    public static func frustum(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> Matrix4 {
        guard right != left, top != bottom, far != near, near > 0, far > 0 else {
            return .identity
        }

        return Matrix4([
            (2 * near) / (right - left), 0, 0, 0,
            0, (2 * near) / (top - bottom), 0, 0,
            (right + left) / (right - left), (top + bottom) / (top - bottom), -(far + near) / (far - near), -1,
            0, 0, -(2 * far * near) / (far - near), 0
        ])
    }

    public static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> Matrix4 {
        guard right != left, top != bottom, far != near else {
            return .identity
        }

        return Matrix4([
            2 / (right - left), 0, 0, 0,
            0, 2 / (top - bottom), 0, 0,
            0, 0, -2 / (far - near), 0,
            -(right + left) / (right - left),
            -(top + bottom) / (top - bottom),
            -(far + near) / (far - near),
            1
        ])
    }
}

public enum MatrixStackError: Error, Equatable {
    case underflow
    case overflow(maxDepth: Int)
}

public struct MatrixStack: Equatable, Sendable {
    public private(set) var stack: [Matrix4]
    public var maxDepth: Int

    public init(maxDepth: Int = 32) {
        self.stack = [.identity]
        self.maxDepth = maxDepth
    }

    public var current: Matrix4 {
        get { stack.last ?? .identity }
        set { stack[stack.count - 1] = newValue }
    }

    public mutating func loadIdentity() {
        current = .identity
    }

    public mutating func load(_ matrix: Matrix4) {
        current = matrix
    }

    public mutating func multiply(_ matrix: Matrix4) {
        current = current * matrix
    }

    public mutating func push() throws {
        guard stack.count < maxDepth else {
            throw MatrixStackError.overflow(maxDepth: maxDepth)
        }
        stack.append(current)
    }

    public mutating func pop() throws {
        guard stack.count > 1 else {
            throw MatrixStackError.underflow
        }
        stack.removeLast()
    }
}
