// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public enum MoshTerminalANSIColor: Int, Equatable, Sendable {
    case black = 0
    case red = 1
    case green = 2
    case yellow = 3
    case blue = 4
    case magenta = 5
    case cyan = 6
    case white = 7
}

public enum MoshTerminalColor: Equatable, Sendable {
    case ansi(MoshTerminalANSIColor, isBright: Bool)
    case indexed(UInt8)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

public enum MoshTerminalIntensity: Equatable, Sendable {
    case normal
    case bold
    case faint
}

public struct MoshTerminalTextAttributes: Equatable, Sendable {
    public static let `default` = MoshTerminalTextAttributes()

    public var intensity: MoshTerminalIntensity
    public var isItalic: Bool
    public var isUnderlined: Bool
    public var isInverse: Bool
    public var foregroundColor: MoshTerminalColor?
    public var backgroundColor: MoshTerminalColor?

    public init(
        intensity: MoshTerminalIntensity = .normal,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        isInverse: Bool = false,
        foregroundColor: MoshTerminalColor? = nil,
        backgroundColor: MoshTerminalColor? = nil
    ) {
        self.intensity = intensity
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isInverse = isInverse
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }
}
