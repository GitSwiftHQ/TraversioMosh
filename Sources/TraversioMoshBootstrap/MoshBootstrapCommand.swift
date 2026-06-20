// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public struct MoshBootstrapCommand: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

public enum MoshBootstrapBindAddress: Equatable, Sendable {
    case any
    case sshConnectionLocalAddress
    case address(String)
}

public enum MoshBootstrapCommandField: Equatable, Sendable {
    case serverPath
    case bindAddress
    case localeName
    case localeValue(name: String)
    case remoteCommandArgument(index: Int)
}

public enum MoshBootstrapCommandError: Error, Equatable, Sendable {
    case emptyServerPath
    case stringContainsNullByte(MoshBootstrapCommandField)
    case emptyBindAddress
    case emptyLocaleName
    case localeNameContainsEquals(String)
    case invalidColorCount(Int)
    case invalidVerboseLevel(Int)
    case invertedPortRange(lowerBound: UInt16, upperBound: UInt16)
    case portRangeStartingAtZero(upperBound: UInt16)
}

public struct MoshBootstrapPortRange: Equatable, Sendable {
    public let lowerBound: UInt16
    public let upperBound: UInt16

    public init(port: UInt16) {
        self.lowerBound = port
        self.upperBound = port
    }

    public init(_ range: ClosedRange<UInt16>) throws {
        try self.init(lowerBound: range.lowerBound, upperBound: range.upperBound)
    }

    public init(lowerBound: UInt16, upperBound: UInt16) throws {
        guard lowerBound <= upperBound else {
            throw MoshBootstrapCommandError.invertedPortRange(
                lowerBound: lowerBound,
                upperBound: upperBound
            )
        }

        guard lowerBound != 0 || upperBound == 0 else {
            throw MoshBootstrapCommandError.portRangeStartingAtZero(upperBound: upperBound)
        }

        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var commandArgument: String {
        if self.lowerBound == self.upperBound {
            return "\(self.lowerBound)"
        }

        return "\(self.lowerBound):\(self.upperBound)"
    }
}

public struct MoshBootstrapLocaleVariable: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) throws {
        guard name.isEmpty == false else {
            throw MoshBootstrapCommandError.emptyLocaleName
        }

        guard name.contains("=") == false else {
            throw MoshBootstrapCommandError.localeNameContainsEquals(name)
        }

        guard name.containsNullByte == false else {
            throw MoshBootstrapCommandError.stringContainsNullByte(.localeName)
        }

        guard value.containsNullByte == false else {
            throw MoshBootstrapCommandError.stringContainsNullByte(.localeValue(name: name))
        }

        self.name = name
        self.value = value
    }

    public var commandArgument: String {
        "\(self.name)=\(self.value)"
    }
}

public enum MoshBootstrapLocaleFallback {
    public static let forwardedVariableNames = [
        "LANG",
        "LANGUAGE",
        "LC_CTYPE",
        "LC_NUMERIC",
        "LC_TIME",
        "LC_COLLATE",
        "LC_MONETARY",
        "LC_MESSAGES",
        "LC_PAPER",
        "LC_NAME",
        "LC_ADDRESS",
        "LC_TELEPHONE",
        "LC_MEASUREMENT",
        "LC_IDENTIFICATION",
        "LC_ALL",
    ]

    public static func variables(from environment: [String: String]) throws -> [MoshBootstrapLocaleVariable] {
        try self.forwardedVariableNames.compactMap { name in
            guard let value = environment[name] else {
                return nil
            }

            return try MoshBootstrapLocaleVariable(name: name, value: value)
        }
    }
}

public struct MoshBootstrapCommandConfiguration: Equatable, Sendable {
    public var serverPath: String
    public var bindAddress: MoshBootstrapBindAddress
    public var portRange: MoshBootstrapPortRange?
    public var colorCount: Int
    public var localeVariables: [MoshBootstrapLocaleVariable]
    public var remoteCommand: [String]
    public var verboseLevel: Int

    public init(
        serverPath: String = "mosh-server",
        bindAddress: MoshBootstrapBindAddress = .sshConnectionLocalAddress,
        portRange: MoshBootstrapPortRange? = nil,
        colorCount: Int = 256,
        localeVariables: [MoshBootstrapLocaleVariable] = [],
        remoteCommand: [String] = [],
        verboseLevel: Int = 0
    ) {
        self.serverPath = serverPath
        self.bindAddress = bindAddress
        self.portRange = portRange
        self.colorCount = colorCount
        self.localeVariables = localeVariables
        self.remoteCommand = remoteCommand
        self.verboseLevel = verboseLevel
    }

    public func makeCommand() throws -> MoshBootstrapCommand {
        guard self.serverPath.isEmpty == false else {
            throw MoshBootstrapCommandError.emptyServerPath
        }

        guard self.serverPath.containsNullByte == false else {
            throw MoshBootstrapCommandError.stringContainsNullByte(.serverPath)
        }

        guard self.colorCount >= 0 else {
            throw MoshBootstrapCommandError.invalidColorCount(self.colorCount)
        }

        guard self.verboseLevel >= 0 else {
            throw MoshBootstrapCommandError.invalidVerboseLevel(self.verboseLevel)
        }

        var arguments = ["new", "-c", "\(self.colorCount)"]

        switch self.bindAddress {
        case .any:
            break
        case .sshConnectionLocalAddress:
            arguments.append("-s")
        case let .address(address):
            guard address.isEmpty == false else {
                throw MoshBootstrapCommandError.emptyBindAddress
            }
            guard address.containsNullByte == false else {
                throw MoshBootstrapCommandError.stringContainsNullByte(.bindAddress)
            }

            arguments.append(contentsOf: ["-i", address])
        }

        if let portRange {
            arguments.append(contentsOf: ["-p", portRange.commandArgument])
        }

        for _ in 0..<self.verboseLevel {
            arguments.append("-v")
        }

        for localeVariable in self.localeVariables {
            arguments.append(contentsOf: ["-l", localeVariable.commandArgument])
        }

        if self.remoteCommand.isEmpty == false {
            for (index, argument) in self.remoteCommand.enumerated() {
                guard argument.containsNullByte == false else {
                    throw MoshBootstrapCommandError.stringContainsNullByte(
                        .remoteCommandArgument(index: index)
                    )
                }
            }

            arguments.append("--")
            arguments.append(contentsOf: self.remoteCommand)
        }

        return MoshBootstrapCommand(
            executablePath: self.serverPath,
            arguments: arguments
        )
    }
}

public protocol MoshBootstrapExecutor: Sendable {
    func runBootstrapCommand(_ command: MoshBootstrapCommand) async throws -> String
}

public enum MoshBootstrapRunner {
    public static func run(
        configuration: MoshBootstrapCommandConfiguration = MoshBootstrapCommandConfiguration(),
        executor: any MoshBootstrapExecutor
    ) async throws -> MoshBootstrapResult {
        let command = try configuration.makeCommand()
        let output = try await executor.runBootstrapCommand(command)
        return try MoshBootstrapParser.parse(output)
    }
}

private extension String {
    var containsNullByte: Bool {
        self.utf8.contains(0)
    }
}
