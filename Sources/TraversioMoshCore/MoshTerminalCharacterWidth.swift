// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

enum MoshTerminalScalarWidth: Int, Equatable, Sendable {
    case zero = 0
    case narrow = 1
    case wide = 2
}

enum MoshTerminalCharacterWidth {
    static func width(of scalar: Unicode.Scalar) -> MoshTerminalScalarWidth {
        if Self.isZeroWidth(scalar) {
            return .zero
        }
        if Self.isWide(scalar) {
            return .wide
        }
        return .narrow
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return true
        default:
            break
        }

        switch scalar.value {
        case 0x0300...0x036f,
             0x1ab0...0x1aff,
             0x1dc0...0x1dff,
             0x20d0...0x20ff,
             0xfe00...0xfe0f,
             0xfe20...0xfe2f,
             0xe0100...0xe01ef:
            return true
        default:
            return false
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isEmojiPresentation {
            return true
        }

        switch scalar.value {
        case 0x1100...0x115f,
             0x231a...0x231b,
             0x2329...0x232a,
             0x23e9...0x23ec,
             0x23f0,
             0x23f3,
             0x25fd...0x25fe,
             0x2614...0x2615,
             0x2648...0x2653,
             0x267f,
             0x2693,
             0x26a1,
             0x26aa...0x26ab,
             0x26bd...0x26be,
             0x26c4...0x26c5,
             0x26ce,
             0x26d4,
             0x26ea,
             0x26f2...0x26f3,
             0x26f5,
             0x26fa,
             0x26fd,
             0x2705,
             0x270a...0x270b,
             0x2728,
             0x274c,
             0x274e,
             0x2753...0x2755,
             0x2757,
             0x2795...0x2797,
             0x27b0,
             0x27bf,
             0x2b1b...0x2b1c,
             0x2b50,
             0x2b55,
             0x2e80...0xa4cf,
             0xac00...0xd7a3,
             0xf900...0xfaff,
             0xfe10...0xfe19,
             0xfe30...0xfe6f,
             0xff00...0xff60,
             0xffe0...0xffe6,
             0x1f000...0x1faff,
             0x20000...0x3fffd:
            return true
        default:
            return false
        }
    }
}
