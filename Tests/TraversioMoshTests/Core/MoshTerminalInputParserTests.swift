// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore

struct MoshTerminalInputParserTests {
    @Test
    func parsesASCIIPrintableScalarsAndControls() throws {
        var parser = MoshTerminalInputParser()

        let tokens = try parser.parse([
            0x41,
            0x08,
            0x0d,
            0x0a,
            0x0b,
            0x0c,
            0x1b,
            0x7f,
        ])

        #expect(tokens == [
            .scalar("A"),
            .control(.backspace),
            .control(.carriageReturn),
            .control(.lineFeed),
            .control(.lineFeed),
            .control(.lineFeed),
            .control(.escape),
            .control(.delete),
        ])
        #expect(parser.pendingByteCount == 0)
    }

    @Test
    func buffersSplitUTF8ScalarsAcrossWrites() throws {
        var parser = MoshTerminalInputParser()

        let firstTokens = try parser.parse([0xe4])
        let secondTokens = try parser.parse([0xbd])
        let thirdTokens = try parser.parse([0xa0])

        #expect(firstTokens == [])
        #expect(secondTokens == [])
        #expect(thirdTokens == [.scalar("你")])
        #expect(parser.pendingByteCount == 0)
    }

    @Test
    func emitsCompletedTokensBeforePendingUTF8Suffix() throws {
        var parser = MoshTerminalInputParser()

        let tokens = try parser.parse([0x41, 0xe2, 0x82])

        #expect(tokens == [.scalar("A")])
        #expect(parser.pendingByteCount == 2)

        let completed = try parser.parse([0xac, 0x42])

        #expect(completed == [.scalar("€"), .scalar("B")])
        #expect(parser.pendingByteCount == 0)
    }

    @Test
    func parsesUTF8EncodedC1Controls() throws {
        var parser = MoshTerminalInputParser()

        let tokens = try parser.parse([0xc2, 0x9b])

        #expect(tokens == [.control(.c1(0x9b))])
        #expect(parser.pendingByteCount == 0)
    }

    @Test
    func finishRejectsTruncatedUTF8() throws {
        var parser = MoshTerminalInputParser()

        let tokens = try parser.parse([0xf0, 0x9f])

        #expect(tokens == [])
        #expect(parser.pendingByteCount == 2)
        #expect(throws: MoshTerminalInputParserError.truncatedUTF8(byteCount: 2)) {
            try parser.finish()
        }
        #expect(parser.pendingByteCount == 0)
    }

    @Test
    func replacesInvalidContinuationBytesAndContinuesLikeOfficialMosh() throws {
        var parser = MoshTerminalInputParser()

        let tokens = try parser.parse([0xe2, 0x28, 0xa1, 0x42])

        #expect(tokens == [.scalar("\u{fffd}"), .scalar("("), .scalar("\u{fffd}"), .scalar("B")])
        #expect(parser.pendingByteCount == 0)
    }

    @Test
    func replacesInvalidLeadBytesLikeOfficialMosh() throws {
        var parser = MoshTerminalInputParser()

        let tokens = try parser.parse([0xff, 0x41])

        #expect(tokens == [.scalar("\u{fffd}"), .scalar("A")])
        #expect(parser.pendingByteCount == 0)
    }

    @Test
    func replacesOverlongAndSurrogateSequencesLikeOfficialMosh() throws {
        var overlongParser = MoshTerminalInputParser()
        var surrogateParser = MoshTerminalInputParser()

        let overlongTokens = try overlongParser.parse([0xc0, 0x80, 0x41])
        let surrogateTokens = try surrogateParser.parse([0xed, 0xa0, 0x80, 0x42])

        #expect(overlongTokens == [.scalar("\u{fffd}"), .scalar("\u{fffd}"), .scalar("A")])
        #expect(surrogateTokens == [.scalar("\u{fffd}"), .scalar("B")])
        #expect(overlongParser.pendingByteCount == 0)
        #expect(surrogateParser.pendingByteCount == 0)
    }
}
