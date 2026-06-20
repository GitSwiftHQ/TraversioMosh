// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshBootstrap

struct MoshBootstrapCommandTests {
    @Test
    func buildsDefaultServerNewCommand() throws {
        let command = try MoshBootstrapCommandConfiguration().makeCommand()

        #expect(command.executablePath == "mosh-server")
        #expect(command.arguments == ["new", "-c", "256", "-s"])
    }

    @Test
    func buildsFullServerNewCommand() throws {
        let portRange = try MoshBootstrapPortRange(60000...60010)
        let localeVariables = [
            try MoshBootstrapLocaleVariable(name: "LANG", value: "en_US.UTF-8"),
            try MoshBootstrapLocaleVariable(name: "LC_CTYPE", value: "en_US.UTF-8"),
        ]
        let configuration = MoshBootstrapCommandConfiguration(
            serverPath: "/usr/local/bin/mosh-server",
            bindAddress: .address("127.0.0.1"),
            portRange: portRange,
            colorCount: 0,
            localeVariables: localeVariables,
            remoteCommand: ["tmux", "new", "-A", "-s", "work"],
            verboseLevel: 2
        )

        let command = try configuration.makeCommand()

        #expect(command.executablePath == "/usr/local/bin/mosh-server")
        #expect(command.arguments == [
            "new",
            "-c",
            "0",
            "-i",
            "127.0.0.1",
            "-p",
            "60000:60010",
            "-v",
            "-v",
            "-l",
            "LANG=en_US.UTF-8",
            "-l",
            "LC_CTYPE=en_US.UTF-8",
            "--",
            "tmux",
            "new",
            "-A",
            "-s",
            "work",
        ])
    }

    @Test
    func omitsBindArgumentForAnyInterface() throws {
        let configuration = MoshBootstrapCommandConfiguration(bindAddress: .any)
        let command = try configuration.makeCommand()

        #expect(command.arguments == ["new", "-c", "256"])
    }

    @Test
    func serializesSinglePortAndZeroPortLikeMoshServer() throws {
        let requestedPort = MoshBootstrapPortRange(port: 60001)
        let ephemeralPort = MoshBootstrapPortRange(port: 0)

        #expect(requestedPort.commandArgument == "60001")
        #expect(ephemeralPort.commandArgument == "0")
    }

    @Test
    func rejectsZeroBasedPortRange() throws {
        #expect(throws: MoshBootstrapCommandError.portRangeStartingAtZero(upperBound: 60010)) {
            _ = try MoshBootstrapPortRange(lowerBound: 0, upperBound: 60010)
        }
    }

    @Test
    func rejectsInvertedPortRange() throws {
        #expect(throws: MoshBootstrapCommandError.invertedPortRange(lowerBound: 60010, upperBound: 60000)) {
            _ = try MoshBootstrapPortRange(lowerBound: 60010, upperBound: 60000)
        }
    }

    @Test
    func rejectsInvalidServerPathAndCounts() {
        #expect(throws: MoshBootstrapCommandError.emptyServerPath) {
            _ = try MoshBootstrapCommandConfiguration(serverPath: "").makeCommand()
        }

        #expect(throws: MoshBootstrapCommandError.invalidColorCount(-1)) {
            _ = try MoshBootstrapCommandConfiguration(colorCount: -1).makeCommand()
        }

        #expect(throws: MoshBootstrapCommandError.invalidVerboseLevel(-1)) {
            _ = try MoshBootstrapCommandConfiguration(verboseLevel: -1).makeCommand()
        }
    }

    @Test
    func rejectsInvalidLocaleVariableNames() {
        #expect(throws: MoshBootstrapCommandError.emptyLocaleName) {
            _ = try MoshBootstrapLocaleVariable(name: "", value: "en_US.UTF-8")
        }

        #expect(throws: MoshBootstrapCommandError.localeNameContainsEquals("LANG=bad")) {
            _ = try MoshBootstrapLocaleVariable(name: "LANG=bad", value: "en_US.UTF-8")
        }
    }

    @Test
    func buildsLocaleFallbackVariablesInOfficialOrder() throws {
        let variables = try MoshBootstrapLocaleFallback.variables(from: [
            "LC_ALL": "en_US.UTF-8",
            "LC_CTYPE": "zh_CN.UTF-8",
            "LANG": "C.UTF-8",
            "PATH": "/usr/bin",
        ])

        #expect(variables.map(\.commandArgument) == [
            "LANG=C.UTF-8",
            "LC_CTYPE=zh_CN.UTF-8",
            "LC_ALL=en_US.UTF-8",
        ])
    }

    @Test
    func rejectsNullBytesInCommandFields() throws {
        #expect(throws: MoshBootstrapCommandError.stringContainsNullByte(.serverPath)) {
            _ = try MoshBootstrapCommandConfiguration(serverPath: "mosh-server\u{0}").makeCommand()
        }

        #expect(throws: MoshBootstrapCommandError.stringContainsNullByte(.bindAddress)) {
            _ = try MoshBootstrapCommandConfiguration(bindAddress: .address("127.0.0.1\u{0}")).makeCommand()
        }

        #expect(throws: MoshBootstrapCommandError.stringContainsNullByte(.localeName)) {
            _ = try MoshBootstrapLocaleVariable(name: "LANG\u{0}", value: "en_US.UTF-8")
        }

        #expect(throws: MoshBootstrapCommandError.stringContainsNullByte(.localeValue(name: "LANG"))) {
            _ = try MoshBootstrapLocaleVariable(name: "LANG", value: "en_US.UTF-8\u{0}")
        }

        #expect(throws: MoshBootstrapCommandError.stringContainsNullByte(.remoteCommandArgument(index: 1))) {
            _ = try MoshBootstrapCommandConfiguration(
                remoteCommand: ["printf", "bad\u{0}"]
            ).makeCommand()
        }
    }

    @Test
    func runnerExecutesBuiltCommandAndParsesOutput() async throws {
        let configuration = MoshBootstrapCommandConfiguration(
            portRange: MoshBootstrapPortRange(port: 60001),
            remoteCommand: ["echo", "ready"]
        )
        let expectedCommand = MoshBootstrapCommand(
            executablePath: "mosh-server",
            arguments: ["new", "-c", "256", "-s", "-p", "60001", "--", "echo", "ready"]
        )
        let executor = FakeBootstrapExecutor(
            expectedCommand: expectedCommand,
            output: "MOSH CONNECT 60001 UAkFedSsVJs2LfMe2Fkedw\n"
        )

        let result = try await MoshBootstrapRunner.run(
            configuration: configuration,
            executor: executor
        )

        #expect(result.port == 60001)
        #expect(result.sessionKey.encodedRepresentation == "UAkFedSsVJs2LfMe2Fkedw")
    }
}

private struct FakeBootstrapExecutor: MoshBootstrapExecutor {
    let expectedCommand: MoshBootstrapCommand
    let output: String

    func runBootstrapCommand(_ command: MoshBootstrapCommand) async throws -> String {
        #expect(command == self.expectedCommand)
        return self.output
    }
}
