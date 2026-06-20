// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public struct MoshTerminalUserInputTranslator: Sendable {
    private enum State: Sendable {
        case ground
        case escape
        case ss3
    }

    private var state: State

    public init() {
        self.state = .ground
    }

    public mutating func translate(
        _ bytes: [UInt8],
        applicationCursorKeysEnabled: Bool
    ) -> [UInt8] {
        var output: [UInt8] = []
        for byte in bytes {
            output.append(contentsOf: self.translate(byte, applicationCursorKeysEnabled: applicationCursorKeysEnabled))
        }
        return output
    }

    public mutating func reset() {
        self.state = .ground
    }

    private mutating func translate(
        _ byte: UInt8,
        applicationCursorKeysEnabled: Bool
    ) -> [UInt8] {
        switch self.state {
        case .ground:
            if byte == 0x1b {
                self.state = .escape
            }
            return [byte]
        case .escape:
            if byte == UInt8(ascii: "O") {
                self.state = .ss3
                return []
            }
            self.state = .ground
            return [byte]
        case .ss3:
            self.state = .ground
            if applicationCursorKeysEnabled == false,
               (UInt8(ascii: "A")...UInt8(ascii: "D")).contains(byte) {
                return [UInt8(ascii: "["), byte]
            }
            return [UInt8(ascii: "O"), byte]
        }
    }
}
