// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import TraversioMoshCZlib

public enum MoshCompressionError: Error, Equatable, Sendable {
    case invalidArgument
    case outOfMemory
    case compressionFailed
    case decompressionFailed
    case outputLimitExceeded
    case invalidMaximumOutputByteCount(Int)
    case unknownStatus(Int32)
}

public struct MoshCompressor: Sendable {
    // Matches the reference peer's terminal-size ceiling (mosh compressor.h
    // BUFFER_SIZE = 2048 * 2048 = 4 MiB). A conformant server can emit a 2–4
    // MiB inflated instruction for a large full-screen redraw; a lower cap would
    // reject it and break the session. The cap still bounds zlib-bomb output.
    public static let defaultMaximumOutputByteCount = 2048 * 2048

    public init() {}

    public func compress(_ input: [UInt8]) throws -> [UInt8] {
        try input.withUnsafeBufferPointer { inputBuffer in
            var outputPointer: UnsafeMutablePointer<UInt8>?
            var outputLength = 0
            let status = traversiomosh_zlib_compress(
                inputBuffer.baseAddress,
                inputBuffer.count,
                &outputPointer,
                &outputLength
            )
            return try Self.takeOutput(
                outputPointer,
                outputLength: outputLength,
                status: status
            )
        }
    }

    public func decompress(
        _ input: [UInt8],
        maximumOutputByteCount: Int = Self.defaultMaximumOutputByteCount
    ) throws -> [UInt8] {
        guard maximumOutputByteCount >= 0 else {
            throw MoshCompressionError.invalidMaximumOutputByteCount(maximumOutputByteCount)
        }

        return try input.withUnsafeBufferPointer { inputBuffer in
            var outputPointer: UnsafeMutablePointer<UInt8>?
            var outputLength = 0
            let status = traversiomosh_zlib_decompress(
                inputBuffer.baseAddress,
                inputBuffer.count,
                maximumOutputByteCount,
                &outputPointer,
                &outputLength
            )
            return try Self.takeOutput(
                outputPointer,
                outputLength: outputLength,
                status: status
            )
        }
    }

    private static func takeOutput(
        _ outputPointer: UnsafeMutablePointer<UInt8>?,
        outputLength: Int,
        status: Int32
    ) throws -> [UInt8] {
        guard status == TRAVERSIOMOSH_ZLIB_SUCCESS else {
            if let outputPointer {
                traversiomosh_zlib_free(outputPointer)
            }
            throw Self.error(for: status)
        }

        guard outputLength > 0 else {
            if let outputPointer {
                traversiomosh_zlib_free(outputPointer)
            }
            return []
        }
        guard let outputPointer else {
            throw MoshCompressionError.invalidArgument
        }

        defer {
            traversiomosh_zlib_free(outputPointer)
        }
        return Array(UnsafeBufferPointer(start: outputPointer, count: outputLength))
    }

    private static func error(for status: Int32) -> MoshCompressionError {
        switch status {
        case TRAVERSIOMOSH_ZLIB_INVALID_ARGUMENT:
            return .invalidArgument
        case TRAVERSIOMOSH_ZLIB_OUT_OF_MEMORY:
            return .outOfMemory
        case TRAVERSIOMOSH_ZLIB_COMPRESS_FAILED:
            return .compressionFailed
        case TRAVERSIOMOSH_ZLIB_DECOMPRESS_FAILED:
            return .decompressionFailed
        case TRAVERSIOMOSH_ZLIB_OUTPUT_LIMIT_EXCEEDED:
            return .outputLimitExceeded
        default:
            return .unknownStatus(status)
        }
    }
}
