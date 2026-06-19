// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import TraversioMoshCrypto

public struct MoshBootstrapResult: Equatable, Sendable {
    public let port: UInt16
    public let sessionKey: MoshSessionKey

    public init(port: UInt16, sessionKey: MoshSessionKey) {
        self.port = port
        self.sessionKey = sessionKey
    }
}

public enum MoshBootstrapParseError: Error, Equatable, Sendable {
    case connectLineNotFound
    case multipleConnectLines
    case malformedConnectLine
    case invalidPort
    case portOutOfRange(Int)
    case invalidSessionKey(MoshSessionKeyError)
}

public enum MoshBootstrapParser {
    public static func parse(_ output: String) throws -> MoshBootstrapResult {
        let candidateLines = output
            .split(whereSeparator: \.isNewline)
            .filter { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                return fields.count >= 2 && fields[0] == "MOSH" && fields[1] == "CONNECT"
            }

        guard let line = candidateLines.first else {
            throw MoshBootstrapParseError.connectLineNotFound
        }

        guard candidateLines.count == 1 else {
            throw MoshBootstrapParseError.multipleConnectLines
        }

        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 4 else {
            throw MoshBootstrapParseError.malformedConnectLine
        }

        let port = try Self.parsePort(fields[2])
        let sessionKey: MoshSessionKey
        do {
            sessionKey = try MoshSessionKey(encodedRepresentation: String(fields[3]))
        } catch let error as MoshSessionKeyError {
            throw MoshBootstrapParseError.invalidSessionKey(error)
        }

        return MoshBootstrapResult(port: port, sessionKey: sessionKey)
    }

    private static func parsePort(_ field: Substring) throws -> UInt16 {
        guard field.utf8.allSatisfy({ byte in byte >= asciiZero && byte <= asciiNine }) else {
            throw MoshBootstrapParseError.invalidPort
        }

        guard let value = Int(field) else {
            throw MoshBootstrapParseError.invalidPort
        }

        guard value >= 1 && value <= Int(UInt16.max) else {
            throw MoshBootstrapParseError.portOutOfRange(value)
        }

        return UInt16(value)
    }
}

private let asciiZero = UInt8(ascii: "0")
private let asciiNine = UInt8(ascii: "9")
