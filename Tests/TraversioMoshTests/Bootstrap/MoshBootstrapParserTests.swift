// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshBootstrap
import TraversioMoshCrypto

struct MoshBootstrapParserTests {
    private let sampleKey = "UAkFedSsVJs2LfMe2Fkedw"

    @Test
    func parsesConnectLineWithSurroundingOutput() throws {
        let output = """
        Warning: locale requested by LC_CTYPE was not available.
        MOSH CONNECT 60001 UAkFedSsVJs2LfMe2Fkedw

        """

        let result = try MoshBootstrapParser.parse(output)

        #expect(result.port == 60001)
        #expect(result.sessionKey.encodedRepresentation == self.sampleKey)
    }

    @Test("Parses valid UDP port boundaries", arguments: [1, 65535])
    func parsesValidPortBoundaries(port: Int) throws {
        let result = try MoshBootstrapParser.parse("MOSH CONNECT \(port) \(self.sampleKey)\n")

        #expect(result.port == UInt16(port))
    }

    @Test
    func rejectsMissingConnectLine() {
        #expect(throws: MoshBootstrapParseError.connectLineNotFound) {
            _ = try MoshBootstrapParser.parse("mosh-server failed to bind a UDP port\n")
        }
    }

    @Test("Rejects malformed connect lines", arguments: [
        "MOSH CONNECT\n",
        "MOSH CONNECT 60001\n",
        "MOSH CONNECT 60001 UAkFedSsVJs2LfMe2Fkedw extra\n",
    ])
    func rejectsMalformedConnectLines(output: String) {
        #expect(throws: MoshBootstrapParseError.malformedConnectLine) {
            _ = try MoshBootstrapParser.parse(output)
        }
    }

    @Test
    func rejectsMultipleConnectLines() {
        let output = """
        MOSH CONNECT 60001 UAkFedSsVJs2LfMe2Fkedw
        MOSH CONNECT 60002 UAkFedSsVJs2LfMe2Fkedw
        """

        #expect(throws: MoshBootstrapParseError.multipleConnectLines) {
            _ = try MoshBootstrapParser.parse(output)
        }
    }

    @Test("Rejects non-decimal ports", arguments: [
        "abc",
        "+60001",
        "-1",
        "60_001",
    ])
    func rejectsNonDecimalPorts(port: String) {
        #expect(throws: MoshBootstrapParseError.invalidPort) {
            _ = try MoshBootstrapParser.parse("MOSH CONNECT \(port) \(self.sampleKey)")
        }
    }

    @Test("Rejects out-of-range ports", arguments: [
        (port: "0", value: 0),
        (port: "65536", value: 65536),
    ])
    func rejectsOutOfRangePorts(input: (port: String, value: Int)) {
        #expect(throws: MoshBootstrapParseError.portOutOfRange(input.value)) {
            _ = try MoshBootstrapParser.parse("MOSH CONNECT \(input.port) \(self.sampleKey)")
        }
    }

    @Test
    func rejectsInvalidSessionKey() {
        #expect(throws: MoshBootstrapParseError.invalidSessionKey(.invalidBase64)) {
            _ = try MoshBootstrapParser.parse("MOSH CONNECT 60001 UAkFedSsVJs2LfMe2Fked!")
        }
    }
}
