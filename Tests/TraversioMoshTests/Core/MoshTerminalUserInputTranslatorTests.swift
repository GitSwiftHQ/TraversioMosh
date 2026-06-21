// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore

struct MoshTerminalUserInputTranslatorTests {
    @Test
    func normalCursorModeTranslatesSS3CursorKeysToCSI() {
        var translator = MoshTerminalUserInputTranslator()

        let translated = translator.translate(
            [0x1b, UInt8(ascii: "O"), UInt8(ascii: "A")],
            applicationCursorKeysEnabled: false
        )

        #expect(translated == [0x1b, UInt8(ascii: "["), UInt8(ascii: "A")])
    }

    @Test
    func normalCursorModeTranslatesEveryOfficialSS3CursorFinal() {
        var translator = MoshTerminalUserInputTranslator()

        let translated = translator.translate(
            [
                0x1b, UInt8(ascii: "O"), UInt8(ascii: "A"),
                0x1b, UInt8(ascii: "O"), UInt8(ascii: "B"),
                0x1b, UInt8(ascii: "O"), UInt8(ascii: "C"),
                0x1b, UInt8(ascii: "O"), UInt8(ascii: "D"),
            ],
            applicationCursorKeysEnabled: false
        )

        #expect(
            translated == [
                0x1b, UInt8(ascii: "["), UInt8(ascii: "A"),
                0x1b, UInt8(ascii: "["), UInt8(ascii: "B"),
                0x1b, UInt8(ascii: "["), UInt8(ascii: "C"),
                0x1b, UInt8(ascii: "["), UInt8(ascii: "D"),
            ]
        )
    }

    @Test
    func normalCursorModePreservesSS3FinalsOutsideOfficialCursorRange() {
        var translator = MoshTerminalUserInputTranslator()

        let translated = translator.translate(
            [
                0x1b, UInt8(ascii: "O"), UInt8(ascii: "@"),
                0x1b, UInt8(ascii: "O"), UInt8(ascii: "E"),
            ],
            applicationCursorKeysEnabled: false
        )

        #expect(
            translated == [
                0x1b, UInt8(ascii: "O"), UInt8(ascii: "@"),
                0x1b, UInt8(ascii: "O"), UInt8(ascii: "E"),
            ]
        )
    }

    @Test
    func applicationCursorModePreservesSS3CursorKeys() {
        var translator = MoshTerminalUserInputTranslator()

        let translated = translator.translate(
            [0x1b, UInt8(ascii: "O"), UInt8(ascii: "B")],
            applicationCursorKeysEnabled: true
        )

        #expect(translated == [0x1b, UInt8(ascii: "O"), UInt8(ascii: "B")])
    }

    @Test
    func nonCursorSS3SequencesArePreserved() {
        var translator = MoshTerminalUserInputTranslator()

        let translated = translator.translate(
            [0x1b, UInt8(ascii: "O"), UInt8(ascii: "P")],
            applicationCursorKeysEnabled: false
        )

        #expect(translated == [0x1b, UInt8(ascii: "O"), UInt8(ascii: "P")])
    }

    @Test
    func splitSS3SequenceKeepsLookaheadStateAcrossCalls() {
        var translator = MoshTerminalUserInputTranslator()

        let escape = translator.translate([0x1b], applicationCursorKeysEnabled: false)
        let ss3Prefix = translator.translate([UInt8(ascii: "O")], applicationCursorKeysEnabled: false)
        let final = translator.translate([UInt8(ascii: "C")], applicationCursorKeysEnabled: false)

        #expect(escape == [0x1b])
        #expect(ss3Prefix == [])
        #expect(final == [UInt8(ascii: "["), UInt8(ascii: "C")])
    }

    @Test
    func currentModeAtSS3FinalByteControlsTranslation() {
        var translator = MoshTerminalUserInputTranslator()

        let escape = translator.translate([0x1b], applicationCursorKeysEnabled: false)
        let ss3Prefix = translator.translate([UInt8(ascii: "O")], applicationCursorKeysEnabled: false)
        let final = translator.translate([UInt8(ascii: "D")], applicationCursorKeysEnabled: true)

        #expect(escape == [0x1b])
        #expect(ss3Prefix == [])
        #expect(final == [UInt8(ascii: "O"), UInt8(ascii: "D")])
    }

    @Test
    func escapeFollowedByNonSS3ByteIsPreserved() {
        var translator = MoshTerminalUserInputTranslator()

        let translated = translator.translate(
            [0x1b, UInt8(ascii: "["), UInt8(ascii: "A")],
            applicationCursorKeysEnabled: false
        )

        #expect(translated == [0x1b, UInt8(ascii: "["), UInt8(ascii: "A")])
    }

    @Test
    func resetClearsPendingSS3LookaheadState() {
        var translator = MoshTerminalUserInputTranslator()

        _ = translator.translate([0x1b, UInt8(ascii: "O")], applicationCursorKeysEnabled: false)
        translator.reset()
        let translated = translator.translate([UInt8(ascii: "A")], applicationCursorKeysEnabled: false)

        #expect(translated == [UInt8(ascii: "A")])
    }
}
