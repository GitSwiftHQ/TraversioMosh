// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore

struct MoshTerminalScreenTests {
    @Test
    func placesPrintableScalarsAndWrapsOnNextPrintable() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcde".utf8)))

        #expect(screen.snapshot.lineStrings == ["abc", "de "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 2))
    }

    @Test
    func autoWrapModeWrapsOnNextPrintableAfterRightMargin() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abc", "X  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func disabledAutoWrapModeOverwritesRightMargin() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("ab\u{1b}[?7lXYZ".utf8)))

        #expect(screen.snapshot.lineStrings == ["abZ", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func reenabledAutoWrapModeUsesDeferredWrapFromDisabledMode() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("ab\u{1b}[?7lX\u{1b}[?7hYZ".utf8)))

        #expect(screen.snapshot.lineStrings == ["abX", "YZ "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 2))
    }

    @Test
    func resetRestoresAutoWrapMode() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?7labc\u{1b}cabcX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abc", "X  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func sgrSequenceDoesNotClearPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}[31mX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abc", "X  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
        #expect(screen.snapshot.rows[1][0].attributes.foregroundColor == .ansi(.red, isBright: false))
    }

    @Test
    func horizontalTabDoesNotClearPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\tX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcd", "X   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func deleteInGroundPreservesPendingWrapLikeOfficialPrintIgnore() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{7f}X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcd", "X   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func deleteControlLiveFixtureMatchesOfficialScreenState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 40, rows: 6))
        let marker = "TERMINAL-SCREEN-DELETE-CONTROL-OK"
        let payload = "\u{1b}[2J\u{1b}[H"
            + "\u{1b}[1;37Habcd\u{7f}X"
            + "\u{1b}[3;1HA\u{7f}B"
            + "\u{1b}[6;1H\(marker)"

        try screen.apply(MoshTerminalOutput(bytes: Array(payload.utf8)))

        #expect(screen.snapshot.lineStrings == [
            String(repeating: " ", count: 36) + "abcd",
            "X" + String(repeating: " ", count: 39),
            "AB" + String(repeating: " ", count: 38),
            String(repeating: " ", count: 40),
            String(repeating: " ", count: 40),
            marker + String(repeating: " ", count: 40 - marker.count)
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 5, column: marker.count))
    }

    @Test
    func nullControlClearsPendingWrapLikeOfficialUnsupportedDispatch() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{0}X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcX", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func verticalTabAndFormFeedClearPendingWrapAndIndex() throws {
        var verticalTabScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))
        var formFeedScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try verticalTabScreen.apply(MoshTerminalOutput(bytes: Array("abcd\u{0b}X".utf8)))
        try formFeedScreen.apply(MoshTerminalOutput(bytes: Array("abcd\u{0c}X".utf8)))

        #expect(verticalTabScreen.snapshot.lineStrings == ["abcd", "   X"])
        #expect(verticalTabScreen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 3))
        #expect(formFeedScreen.snapshot.lineStrings == ["abcd", "   X"])
        #expect(formFeedScreen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 3))
    }

    @Test
    func c1IndexAndNextLineClearPendingWrapBeforeMoving() throws {
        var indexScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 3))
        var nextLineScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 3))

        try indexScreen.apply(MoshTerminalOutput(bytes: Array("abcd".utf8) + [0xc2, 0x84] + Array("X".utf8)))
        try nextLineScreen.apply(MoshTerminalOutput(bytes: Array("abcd".utf8) + [0xc2, 0x85] + Array("X".utf8)))

        #expect(indexScreen.snapshot.lineStrings == ["abcd", "   X", "    "])
        #expect(indexScreen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 3))
        #expect(nextLineScreen.snapshot.lineStrings == ["abcd", "X   ", "    "])
        #expect(nextLineScreen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func c0ControlsLiveFixtureMatchesOfficialScreenState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 40, rows: 6))
        let marker = "TERMINAL-SCREEN-C0-CONTROLS-OK"
        let payload = "\u{1b}[2J\u{1b}[H"
            + "\u{07}"
            + "\u{1b}[1;37Habcd\u{08}X"
            + "\u{1b}[2;37Habcd\u{0d}X"
            + "\u{1b}[3;37Habcd\u{0a}X"
            + "\u{1b}[4;4H\u{0b}V"
            + "\u{1b}[4;8H\u{0c}F"
            + "\u{1b}[6;1H\(marker)"

        try screen.apply(MoshTerminalOutput(bytes: Array(payload.utf8)))

        #expect(screen.snapshot.lineStrings == [
            String(repeating: " ", count: 36) + "abXd",
            "X" + String(repeating: " ", count: 35) + "abcd",
            String(repeating: " ", count: 36) + "abcd",
            String(repeating: " ", count: 39) + "X",
            "   V   F" + String(repeating: " ", count: 32),
            marker + String(repeating: " ", count: 40 - marker.count)
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 5, column: marker.count))
        #expect(screen.snapshot.bellCount == 1)
    }

    @Test
    func c1ControlsLiveFixtureMatchesOfficialScreenState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 40, rows: 6))
        let marker = "TERMINAL-SCREEN-C1-CONTROLS-OK"
        let payload = "\u{1b}[2J\u{1b}[H"
            + "\u{1b}[1;37Habcd\u{0084}X"
            + "\u{1b}[3;10HN\u{0085}Y"
            + "\u{1b}[5;20H\u{008d}R"
            + "\u{1b}[5;5H\u{0088}"
            + "\u{1b}[5;1HA\tB"
            + "\u{1b}[6;1H\(marker)"

        try screen.apply(MoshTerminalOutput(bytes: Array(payload.utf8)))

        #expect(screen.snapshot.lineStrings == [
            String(repeating: " ", count: 36) + "abcd",
            String(repeating: " ", count: 39) + "X",
            String(repeating: " ", count: 9) + "N" + String(repeating: " ", count: 30),
            "Y" + String(repeating: " ", count: 18) + "R" + String(repeating: " ", count: 20),
            "A   B" + String(repeating: " ", count: 35),
            marker + String(repeating: " ", count: 40 - marker.count)
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 5, column: marker.count))
    }

    @Test
    func cancelControlsInGroundClearPendingWrapLikeOfficialDispatch() throws {
        var canScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))
        var subScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try canScreen.apply(MoshTerminalOutput(bytes: Array("abc\u{0018}X".utf8)))
        try subScreen.apply(MoshTerminalOutput(bytes: Array("abc\u{001a}X".utf8)))

        #expect(canScreen.snapshot.lineStrings == ["abX", "   "])
        #expect(canScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
        #expect(subScreen.snapshot.lineStrings == ["abX", "   "])
        #expect(subScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func unknownC1ExecuteControlInGroundClearsPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{0080}X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abX", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func c1SOSStringControlInGroundDoesNotRenderPayload() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 8, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{0098}hidden\u{009c}B".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB      "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func cursorHorizontalTabulationDoesNotClearPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[IX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcd", "X   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func cursorBackwardTabulationDoesNotClearPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[ZX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcd", "X   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func tabClearDoesNotClearPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[gX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcd", "X   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func unknownEscapeDispatchClearsPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}=X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcX", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func c0ControlExecutesInsideEscapeWithoutEndingSequence() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("AB\u{1b}\n[2CB".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB   ", "    B"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 4))
    }

    @Test
    func escapeInsideEscapeRestartsEscapeState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}\u{1b}[2CX".utf8)))

        #expect(screen.snapshot.lineStrings == ["A  X "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func unknownEscapeIntermediateConsumesFinalBeforeReturningGround() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}%GX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abX", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func nonASCIIScalarInsideEscapeIntermediateDispatchesUnknownLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}#\u{4f60}X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcX", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func c0ControlExecutesInsideEscapeIntermediateWithoutEndingSequence() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("AB\u{1b}%\nGX".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB  ", "  X "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 3))
    }

    @Test
    func unknownCSIDispatchClearsPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[qX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcX", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func colonCSIParametersEnterOfficialIgnoreState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[1:1HX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcd", "X   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func privateParameterAfterNumericCSIParameterEntersOfficialIgnoreState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[1?1HX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcd", "X   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func parameterAfterCSIIntermediateEntersOfficialIgnoreState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}[ 1HB".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func c0ControlExecutesInsideCSIWithoutEndingSequence() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 3))

        try screen.apply(MoshTerminalOutput(bytes: Array("AB\u{1b}[\n2CB".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB  ", "   B", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 3))
    }

    @Test
    func c0ControlExecutesInsideCSIIgnoreState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[1:\nHX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcd", "   X"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 3))
    }

    @Test
    func nonASCIIScalarInsideCSITerminatesAsUnknownDispatchLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[\u{4f60}X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcX", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func nonBreakingSpaceInsideCSIIgnoreTerminatesIgnoreStateLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[1:\u{a0}X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcd", "X   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func cancelControlInsideCSIClearsSequenceAndPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}[\u{0018}X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abX", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func substituteControlInsideCSIClearsSequenceAndPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}[\u{001a}X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abX", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func c1ControlInsideCSIReturnsToGroundAfterExecution() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("AB\u{1b}[\u{0085}X".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB  ", "X   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func c1CSIInsideCSIStartsFreshCSISequence() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}[5\u{009b}2CX".utf8)))

        #expect(screen.snapshot.lineStrings == ["A  X "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func privateCursorVisibilityModeUpdatesSnapshot() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}[?25lB".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB "])
        #expect(screen.snapshot.isCursorVisible == false)

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?25h".utf8)))

        #expect(screen.snapshot.isCursorVisible == true)
    }

    @Test
    func resetRestoresCursorVisibility() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?25l\u{1b}c".utf8)))

        #expect(screen.snapshot.isCursorVisible == true)
    }

    @Test
    func privateDisplayModesUpdateSnapshotWithoutRendering() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("\u{1b}[?5h\u{1b}[?2004h\u{1b}[?1004h\u{1b}[?1007hAB".utf8)
            )
        )

        #expect(screen.snapshot.lineStrings == ["AB "])
        #expect(screen.snapshot.isReverseVideoEnabled == true)
        #expect(screen.snapshot.isBracketedPasteEnabled == true)
        #expect(screen.snapshot.isMouseFocusEventEnabled == true)
        #expect(screen.snapshot.isMouseAlternateScrollEnabled == true)

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?5l\u{1b}[?2004l\u{1b}[?1004l\u{1b}[?1007l".utf8)))

        #expect(screen.snapshot.isReverseVideoEnabled == false)
        #expect(screen.snapshot.isBracketedPasteEnabled == false)
        #expect(screen.snapshot.isMouseFocusEventEnabled == false)
        #expect(screen.snapshot.isMouseAlternateScrollEnabled == false)
    }

    @Test
    func privateDisplayModesSurviveScreenErase() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array(
                    "\u{1b}[?5h\u{1b}[?25l\u{1b}[?2004h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?1004h\u{1b}[?1007hAB\u{1b}[2JX".utf8
                )
            )
        )

        #expect(screen.snapshot.lineStrings == ["  X ", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
        #expect(screen.snapshot.isCursorVisible == false)
        #expect(screen.snapshot.isReverseVideoEnabled == true)
        #expect(screen.snapshot.isBracketedPasteEnabled == true)
        #expect(screen.snapshot.mouseReportingMode == .buttonEvent)
        #expect(screen.snapshot.mouseEncodingMode == .sgr)
        #expect(screen.snapshot.isMouseFocusEventEnabled == true)
        #expect(screen.snapshot.isMouseAlternateScrollEnabled == true)
    }

    @Test
    func deccolmPrivateModeClearsScreenWithoutChangingDimensions() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcde1234\u{1b}[2;4H\u{1b}[?3hX".utf8)))

        #expect(screen.snapshot.dimensions == (try MoshTerminalDimensions(columns: 5, rows: 2)))
        #expect(screen.snapshot.lineStrings == ["X    ", "     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("YZ\u{1b}[?3lQ".utf8)))

        #expect(screen.snapshot.dimensions == (try MoshTerminalDimensions(columns: 5, rows: 2)))
        #expect(screen.snapshot.lineStrings == ["Q    ", "     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func deccolmPrivateModeHomesInsideOriginModeScrollRegion() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 4))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;3r\u{1b}[?6h\u{1b}[3;5HX\u{1b}[?3hY".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "     ",
            "Y    ",
            "     ",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func privateMouseReportingModesFollowOfficialSetAndClear() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?9h".utf8)))
        #expect(screen.snapshot.mouseReportingMode == .x10)

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?1002h".utf8)))
        #expect(screen.snapshot.mouseReportingMode == .buttonEvent)

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?1000l".utf8)))
        #expect(screen.snapshot.mouseReportingMode == .none)

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?1003h".utf8)))
        #expect(screen.snapshot.mouseReportingMode == .anyEvent)
    }

    @Test
    func privateMouseEncodingModesFollowOfficialSetAndClear() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?1005h".utf8)))
        #expect(screen.snapshot.mouseEncodingMode == .utf8)

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?1006h".utf8)))
        #expect(screen.snapshot.mouseEncodingMode == .sgr)

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?1015h".utf8)))
        #expect(screen.snapshot.mouseEncodingMode == .urxvt)

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?1006l".utf8)))
        #expect(screen.snapshot.mouseEncodingMode == .defaultMode)
    }

    @Test
    func applicationCursorKeysModeUpdatesAndSoftResetClearsOnlySoftResetModes() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("\u{1b}[?1h\u{1b}[?5h\u{1b}[?2004h\u{1b}[?1004h\u{1b}[?1006h\u{1b}[!p".utf8)
            )
        )

        #expect(screen.snapshot.isApplicationCursorKeysEnabled == false)
        #expect(screen.snapshot.isReverseVideoEnabled == true)
        #expect(screen.snapshot.isBracketedPasteEnabled == true)
        #expect(screen.snapshot.isMouseFocusEventEnabled == true)
        #expect(screen.snapshot.mouseEncodingMode == .sgr)
    }

    @Test
    func resetRestoresPrivateDisplayAndInputModes() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array(
                    "\u{1b}[?1h\u{1b}[?5h\u{1b}[?2004h\u{1b}[?1003h\u{1b}[?1004h\u{1b}[?1007h\u{1b}[?1015h\u{1b}c".utf8
                )
            )
        )

        #expect(screen.snapshot.isApplicationCursorKeysEnabled == false)
        #expect(screen.snapshot.isReverseVideoEnabled == false)
        #expect(screen.snapshot.isBracketedPasteEnabled == false)
        #expect(screen.snapshot.mouseReportingMode == .none)
        #expect(screen.snapshot.isMouseFocusEventEnabled == false)
        #expect(screen.snapshot.isMouseAlternateScrollEnabled == false)
        #expect(screen.snapshot.mouseEncodingMode == .defaultMode)
    }

    @Test
    func privateModeSequencesDoNotClearPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("abc\u{1b}[?5h\u{1b}[?2004h\u{1b}[?1004hX".utf8)
            )
        )

        #expect(screen.snapshot.lineStrings == ["abc", "X  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func applicationCursorModeDoesNotClearPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}[?1h".utf8)))

        #expect(screen.snapshot.isApplicationCursorKeysEnabled == true)

        try screen.apply(MoshTerminalOutput(bytes: Array("X\u{1b}[?1lY".utf8)))

        #expect(screen.snapshot.lineStrings == ["abc", "XY "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 2))
        #expect(screen.snapshot.isApplicationCursorKeysEnabled == false)
    }

    @Test
    func originModeSequencesClearPendingWrapThroughOfficialHome() throws {
        var setModeScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 4))
        var resetModeScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 4))

        try setModeScreen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;3r\u{1b}[1;1Habc\u{1b}[?6hX".utf8)))
        try resetModeScreen.apply(
            MoshTerminalOutput(bytes: Array("\u{1b}[2;3r\u{1b}[?6h\u{1b}[1;1Habc\u{1b}[?6lX".utf8))
        )

        #expect(setModeScreen.snapshot.lineStrings == ["Xbc", "   ", "   ", "   "])
        #expect(setModeScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
        #expect(resetModeScreen.snapshot.lineStrings == ["   ", "Xbc", "   ", "   "])
        #expect(resetModeScreen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func deccolmClearsPendingWrapThroughOfficialHome() throws {
        var setModeScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))
        var resetModeScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try setModeScreen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}[?3hX".utf8)))
        try resetModeScreen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}[?3lX".utf8)))

        #expect(setModeScreen.snapshot.lineStrings == ["X  ", "   "])
        #expect(setModeScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
        #expect(resetModeScreen.snapshot.lineStrings == ["X  ", "   "])
        #expect(resetModeScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func ansiModeSequencesClearPendingWrapLikeOfficialMosh() throws {
        var setModeScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))
        var resetModeScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try setModeScreen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}[4hX".utf8)))
        try resetModeScreen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[4habc\u{1b}[4lX".utf8)))

        #expect(setModeScreen.snapshot.lineStrings == ["abX", "   "])
        #expect(setModeScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
        #expect(resetModeScreen.snapshot.lineStrings == ["abX", "   "])
        #expect(resetModeScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func bellControlIncrementsSnapshotCountWithoutRendering() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{7}B\u{7}".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB "])
        #expect(screen.snapshot.bellCount == 2)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func bellControlClearsPendingWrapLikeOfficialDispatch() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{7}X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abX", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
        #expect(screen.snapshot.bellCount == 1)
    }

    @Test
    func resetAndSoftResetPreserveBellCount() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{7}\u{1b}c\u{1b}[!p".utf8)))

        #expect(screen.snapshot.bellCount == 1)
        #expect(screen.snapshot.lineStrings == ["   "])
    }

    @Test
    func oscBellTerminatorDoesNotIncrementBellCount() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}]2;title\u{7}X".utf8)))

        #expect(screen.snapshot.bellCount == 0)
        #expect(screen.snapshot.lineStrings == ["X  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func csiSoftResetRestoresModesWithoutClearingScreen() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 3))

        try screen.apply(MoshTerminalOutput(bytes: Array(
            "ABCDE\u{1b}[2;3r\u{1b}[?6h\u{1b}[?25l\u{1b}[4h\u{1b}[31m\u{1b}[!p\u{1b}[1;1HX".utf8
        )))

        #expect(screen.snapshot.lineStrings == ["XBCDE", "     ", "     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
        #expect(screen.snapshot.isCursorVisible == true)
        #expect(screen.snapshot.rows[0][0].attributes == .default)
    }

    @Test
    func csiSoftResetKeepsDisabledAutoWrapMode() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?7l\u{1b}[!pabcX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abX", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func csiSoftResetRestoresReplaceMode() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcdef\u{1b}[1;3H\u{1b}[4h\u{1b}[!pX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abXdef"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func csiSoftResetClearsSavedCursorState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("ab\u{1b}7\u{1b}[!p\u{1b}8X".utf8)))

        #expect(screen.snapshot.lineStrings == ["Xb  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func escapeSaveCursorClearsPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}7X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abX", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func escapeRestoreCursorDoesNotRestorePendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}7\u{1b}[1;1H!\u{1b}8X".utf8)))

        #expect(screen.snapshot.lineStrings == ["!bX", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func escapeSaveRestorePreservesAutoWrapMode() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?7l\u{1b}7\u{1b}[?7h\u{1b}8abcX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abX", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func saveRestoreCursorPreservesOriginMode() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4r\u{1b}[?6h\u{1b}7\u{1b}[?6l\u{1b}8\u{1b}[1;1HX".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "     ",
            "X    ",
            "     ",
            "     ",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func csiSaveAndRestoreAreUnsupportedDispatches() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("ab\u{1b}[s\u{1b}[1;1H!\u{1b}[uX".utf8)))

        #expect(screen.snapshot.lineStrings == ["!X  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func restoreCursorWithoutPriorSaveRestoresDefaultAutoWrapMode() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?7l\u{1b}8abcX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abc", "X  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func restoreCursorWithoutPriorSaveUsesDefaultState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[31mAB\u{1b}8X".utf8)))

        #expect(screen.snapshot.lineStrings == ["XB  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
        #expect(screen.snapshot.rows[0][0].attributes == .default)
    }

    @Test
    func characterSetDesignationIsUnsupportedLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 8, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}(0lqk\u{1b}(Babc".utf8)))

        #expect(screen.snapshot.lineStrings == ["lqkabc  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 6))
    }

    @Test
    func characterSetDesignationLeavesVT100RangePrintable() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 32, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}(0_`abcdefghijklmnopqrstuvwxyz{|}~".utf8)))

        #expect(screen.snapshot.lineStrings == ["_`abcdefghijklmnopqrstuvwxyz{|}~"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 31))
    }

    @Test
    func shiftOutAndShiftInDoNotSelectCharacterSetsLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 7, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b})0A\u{0e}xq\u{0f}xq".utf8)))

        #expect(screen.snapshot.lineStrings == ["Axqxq  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 5))
    }

    @Test
    func shiftOutAndShiftInClearPendingWrapAsUnsupportedControls() throws {
        var shiftOutScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))
        var shiftInScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try shiftOutScreen.apply(MoshTerminalOutput(bytes: Array("abc\u{0e}X".utf8)))
        try shiftInScreen.apply(MoshTerminalOutput(bytes: Array("abc\u{0f}X".utf8)))

        #expect(shiftOutScreen.snapshot.lineStrings == ["abX", "   "])
        #expect(shiftOutScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
        #expect(shiftInScreen.snapshot.lineStrings == ["abX", "   "])
        #expect(shiftInScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func unsupportedG0DesignationDoesNotAffectLaterPrintableText() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b})0\u{0e}\u{1b}(Bq\u{0f}q".utf8)))

        #expect(screen.snapshot.lineStrings == ["qq "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func escapeSaveRestoreIsUnaffectedByUnsupportedCharacterSetDesignation() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}(0\u{1b}7\u{1b}(Bq\u{1b}8q".utf8)))

        #expect(screen.snapshot.lineStrings == ["Aq "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func resetAfterUnsupportedCharacterSetDesignationKeepsASCII() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}(0\u{1b}cq".utf8)))

        #expect(screen.snapshot.lineStrings == ["q "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func decScreenAlignmentFillsCompleteScreenAndPreservesCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcde\u{1b}#8".utf8)))

        #expect(screen.snapshot.lineStrings == ["EEE", "EEE"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 2))
    }

    @Test
    func decScreenAlignmentClearsPendingWrapBeforeNextPrintable() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}#8X".utf8)))

        #expect(screen.snapshot.lineStrings == ["EEX", "EEE"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func decScreenAlignmentPreservesScrollRegion() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 4))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;3r\u{1b}#8\u{1b}[3;1H\nX".utf8)))

        #expect(screen.snapshot.lineStrings == ["EEE", "EEE", "X  ", "EEE"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 2, column: 1))
    }

    @Test
    func decScreenAlignmentPreservesOriginModeAndCurrentRendition() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 3))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;3r\u{1b}[?6h\u{1b}[31m\u{1b}#8\u{1b}[1;1HX".utf8)))

        #expect(screen.snapshot.lineStrings == ["EEE", "XEE", "EEE"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
        #expect(screen.snapshot.rows[1][0].attributes.foregroundColor == .ansi(.red, isBright: false))
        #expect(screen.snapshot.rows[1][1].attributes.foregroundColor == nil)
    }

    @Test
    func decScreenAlignmentClearsCellHyperlinksWithoutClearingCurrentHyperlink() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))

        try screen.apply(
            MoshTerminalOutput(bytes: Array("\u{1b}]8;id=align;https://example.test\u{1b}\\\u{1b}#8X".utf8))
        )

        let link = MoshTerminalHyperlink(parameters: "id=align", url: "https://example.test")
        #expect(screen.snapshot.lineStrings == ["XE"])
        #expect(screen.snapshot.currentHyperlink == link)
        #expect(screen.snapshot.rows[0][0].hyperlink == link)
        #expect(screen.snapshot.rows[0][1].contents == "E")
        #expect(screen.snapshot.rows[0][1].hyperlink == nil)
    }

    @Test
    func decScreenAlignmentCanBeSplitAcrossWrites() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("ab\u{1b}#".utf8)))
        try screen.apply(MoshTerminalOutput(bytes: Array("8".utf8)))

        #expect(screen.snapshot.lineStrings == ["EE", "EE"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func unsupportedHashEscapeFinalDoesNotRenderFinalByte() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}#9B".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func decLineWidthHeightEscapesAreUnsupportedLikeOfficialMosh() throws {
        for final in ["3", "4", "5", "6"] {
            var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

            try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}#\(final)X".utf8)))

            #expect(screen.snapshot.lineStrings == ["abcX"])
            #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
        }
    }

    @Test
    func escapedC1MnemonicFinalsExecuteOfficialControlCodes() throws {
        var indexScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))
        var nextLineScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))
        var reverseIndexScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))
        var tabSetScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 12, rows: 1))

        try indexScreen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}DX".utf8)))
        try nextLineScreen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}EX".utf8)))
        try reverseIndexScreen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}MX".utf8)))
        try tabSetScreen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[3g\u{1b}[4G\u{1b}H\r\tX".utf8)))

        #expect(indexScreen.snapshot.lineStrings == ["abcd", "   X"])
        #expect(indexScreen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 3))
        #expect(nextLineScreen.snapshot.lineStrings == ["abcd", "X   "])
        #expect(nextLineScreen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
        #expect(reverseIndexScreen.snapshot.lineStrings == ["   X", "abcd"])
        #expect(reverseIndexScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
        #expect(tabSetScreen.snapshot.lineStrings == ["   X        "])
        #expect(tabSetScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func escapedC1LiveFixtureMatchesOfficialScreenState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 40, rows: 6))
        let fixture = "\u{1b}[2J\u{1b}[H"
            + "I\u{1b}DX"
            + "\u{1b}[2;10HN\u{1b}EY"
            + "\u{1b}[4;5H\u{1b}H\u{1b}[4;1H\tT"
            + "\u{1b}[6;10H\u{1b}MZ"
            + "\u{1b}[6;1HTERMINAL-SCREEN-ESCAPED-C1-OK"

        try screen.apply(MoshTerminalOutput(bytes: Array(fixture.utf8)))

        #expect(screen.snapshot.lineStrings == [
            "I                                       ",
            " X       N                              ",
            "Y                                       ",
            "    T                                   ",
            "         Z                              ",
            "TERMINAL-SCREEN-ESCAPED-C1-OK           ",
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 5, column: 29))
    }

    @Test
    func appliesCarriageReturnLineFeedBackspaceAndTab() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 8, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\rZ\nQR\u{08}!\tT".utf8)))

        #expect(screen.snapshot.lineStrings == ["Zbc     ", " Q!    T"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 7))
    }

    @Test
    func horizontalTabUsesMutableTabStops() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 12, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[3g\u{1b}[4G\u{0088}\r\tX".utf8)))

        #expect(screen.snapshot.lineStrings == ["   X        "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func tabClearCurrentRemovesCustomTabStop() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 12, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[3g\u{1b}[4G\u{0088}\u{1b}[g\r\tX".utf8)))

        #expect(screen.snapshot.lineStrings == ["           X"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 11))
    }

    @Test
    func resizeExtendsDefaultTabStopsLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 8, rows: 1))

        screen.resize(try MoshTerminalDimensions(columns: 16, rows: 1))
        try screen.apply(MoshTerminalOutput(bytes: Array("\tX".utf8)))

        #expect(screen.snapshot.lineStrings == ["        X       "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 9))
    }

    @Test
    func resizeDoesNotRestoreDefaultTabStopsAfterClearAllLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 8, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[3g".utf8)))
        screen.resize(try MoshTerminalDimensions(columns: 16, rows: 1))
        try screen.apply(MoshTerminalOutput(bytes: Array("\tX".utf8)))

        #expect(screen.snapshot.lineStrings == ["               X"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 15))
    }

    @Test
    func resizePreservesPendingWrapLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd".utf8)))
        screen.resize(try MoshTerminalDimensions(columns: 6, rows: 2))
        try screen.apply(MoshTerminalOutput(bytes: Array("X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcd  ", "X     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func resizePreservesTopLeftCellsAndClampsCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcdef".utf8)))
        screen.resize(try MoshTerminalDimensions(columns: 3, rows: 3))

        #expect(screen.snapshot.lineStrings == ["abc", "ef ", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 2))
    }

    @Test
    func renderResizeOperationResizesScreen() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("ab".utf8)))
        try screen.apply(.resize(try MoshTerminalDimensions(columns: 3, rows: 2)))

        #expect(screen.snapshot.lineStrings == ["ab ", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func csiCursorPositionPlacesTextWithoutPrintingSequenceBytes() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}[2;3HX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abc  ", "  X  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 3))
    }

    @Test
    func unregisteredCursorMovementFinalsClearPendingWrapWithoutMoving() throws {
        let finals = [
            UInt8(ascii: "E"),
            UInt8(ascii: "F"),
            UInt8(ascii: "a"),
            UInt8(ascii: "e")
        ]

        for final in finals {
            var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))
            var bytes = Array("abcd\u{1b}[2".utf8)
            bytes.append(final)
            bytes.append(UInt8(ascii: "X"))

            try screen.apply(MoshTerminalOutput(bytes: bytes))

            let finalName = String(decoding: [final], as: UTF8.self)
            #expect(
                screen.snapshot.lineStrings == ["abcX", "    "],
                "CSI \(finalName) must not move the cursor like CNL/CPL/HPR/VPR."
            )
            #expect(
                screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3),
                "CSI \(finalName) must only clear pending wrap before the next printable."
            )
        }
    }

    @Test
    func csiHorizontalAndVerticalAbsolutePositioningMovesCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 8, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;2H\u{1b}[4`A\u{1b}[4dB".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "        ",
            "   A    ",
            "        ",
            "    B   ",
            "        "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 3, column: 5))
    }

    @Test
    func deviceAttributeQueriesReturnOfficialTerminalToHostReplies() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        let replies = try screen.apply(
            MoshTerminalOutput(bytes: Array("\u{1b}[c\u{1b}[0c\u{1b}[>c".utf8))
        )

        #expect(replies == Array("\u{1b}[?62c\u{1b}[?62c\u{1b}[>1;10;0c".utf8))
        #expect(screen.snapshot.lineStrings == ["    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 0))
    }

    @Test
    func privateDeviceAttributeQueriesDoNotReturnReplies() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        let replies = try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?c\u{1b}[=c\u{1b}[<c".utf8)))

        #expect(replies.isEmpty)
        #expect(screen.snapshot.lineStrings == ["    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 0))
    }

    @Test
    func deviceStatusReportsReturnStatusAndOneBasedCursorPosition() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 8, rows: 5))

        let replies = try screen.apply(MoshTerminalOutput(bytes: Array("x\u{1b}[4;6H\u{1b}[5n\u{1b}[6n".utf8)))

        #expect(replies == Array("\u{1b}[0n\u{1b}[4;6R".utf8))
        #expect(screen.snapshot.lineStrings[0] == "x       ")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 3, column: 5))
    }

    @Test
    func unregisteredRelativeHorizontalAndVerticalFinalsDoNotMoveCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 3))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;2H\u{1b}[2aX\u{1b}[1eY".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "     ",
            " XY  ",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 3))
    }

    @Test
    func csiForwardAndBackwardTabulationUseTabStops() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 20, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[3C\u{1b}[2I\u{1b}[Z".utf8)))

        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 8))
    }

    @Test
    func registeredRelativeCursorMovementClampsToViewportBounds() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 3))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("\u{1b}[2;3H\u{1b}[9A\u{1b}[9D\u{1b}[1B\u{1b}[2CX\u{1b}[9B\u{1b}[9CY".utf8)
            )
        )

        #expect(screen.snapshot.lineStrings == [
            "     ",
            "  X  ",
            "    Y",
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 2, column: 4))
    }

    @Test
    func csiRelativeCursorMovementAndLineEraseMutateScreen() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcde\u{1b}[1DX\u{1b}[K".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcX ", "     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func csiInsertCharactersShiftsCurrentLineRight() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcdef\u{1b}[1;3H\u{1b}[2@".utf8)))

        #expect(screen.snapshot.lineStrings == ["ab  cd"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func insertModeShiftsCellsBeforePrinting() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcdef\u{1b}[1;3H\u{1b}[4hXY".utf8)))

        #expect(screen.snapshot.lineStrings == ["abXYcd"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func disablingInsertModeRestoresReplacementPrinting() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcdef\u{1b}[1;3H\u{1b}[4hX\u{1b}[4lY".utf8)))

        #expect(screen.snapshot.lineStrings == ["abXYde"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func resetRestoresReplacementPrintingMode() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[4h\u{1b}cabcd\u{1b}[1;2HX".utf8)))

        #expect(screen.snapshot.lineStrings == ["aXcd"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func insertModePreservesWideScalarContinuationsWhileShifting() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 7, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A中BC\u{1b}[1;2H\u{1b}[4hX".utf8)))

        #expect(screen.snapshot.lineStrings == ["AX中 BC "])
        #expect(screen.snapshot.rows[0][2].contents == "中")
        #expect(screen.snapshot.rows[0][2].displayWidth == 2)
        #expect(screen.snapshot.rows[0][3].isContinuation == true)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func csiDeleteCharactersShiftsCurrentLineLeft() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcdef\u{1b}[1;3H\u{1b}[2P".utf8)))

        #expect(screen.snapshot.lineStrings == ["abef  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func csiEraseCharactersBlanksCurrentLineWithoutShifting() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcdef\u{1b}[1;3H\u{1b}[3X".utf8)))

        #expect(screen.snapshot.lineStrings == ["ab   f"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func csiIntermediateSequenceDoesNotDispatchBaseFinalByte() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcde\u{1b}[1;3H\u{1b}[ X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcde"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func csiParameterOverflowTruncatesWithoutEnteringIgnoreLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))
        let retainedPrefix = String(repeating: "0;", count: 49) + "31"
        let ignoredSuffix = ";0;0;0"

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[\(retainedPrefix)\(ignoredSuffix)mX".utf8)))

        #expect(screen.snapshot.lineStrings == ["X   "])
        #expect(screen.snapshot.rows[0][0].attributes.foregroundColor == .ansi(.red, isBright: false))
    }

    @Test
    func csiIntermediateOverflowStillDispatchesUnknownLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[\(String(repeating: "!", count: 9))pX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcX", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func oversizedCSIParameterUsesOfficialDefaultValue() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}[70000CX".utf8)))

        #expect(screen.snapshot.lineStrings == ["A X  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func oversizedSGRExtendedColorComponentsDefaultLikeOfficialMosh() throws {
        var indexedScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))
        var trueColorScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))

        try indexedScreen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[31mA\u{1b}[38;5;70000mB".utf8)))
        try trueColorScreen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[31mA\u{1b}[38;2;70000;1;2mB".utf8)))

        #expect(indexedScreen.snapshot.rows[0][0].attributes.foregroundColor == .ansi(.red, isBright: false))
        #expect(indexedScreen.snapshot.rows[0][1].attributes.foregroundColor == .ansi(.black, isBright: false))
        #expect(trueColorScreen.snapshot.rows[0][0].attributes.foregroundColor == .ansi(.red, isBright: false))
        #expect(trueColorScreen.snapshot.rows[0][1].attributes.foregroundColor == .rgb(red: 0, green: 1, blue: 2))
    }

    @Test
    func csiEraseScreenDoesNotPrintEscapePayload() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("hello\u{1b}[2J".utf8)))

        #expect(screen.snapshot.lineStrings == ["     ", "     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func csiEraseScreenModeThreeClearsPendingWrapWithoutClearingFramebuffer() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[3JX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcX", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func privateEraseDisplayIsUnsupportedDispatchLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[?2JX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcX", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func privateEraseLineIsUnsupportedDispatchLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcde\u{1b}[1;3H\u{1b}[?KX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abXde"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func privateCursorPositionIsUnsupportedDispatchLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcde\u{1b}[?2;1HX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcdX", "     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func greaterThanEraseDisplayIsUnsupportedDispatchLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcde12345\u{1b}[1;3H\u{1b}[>JX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abXde", "12345"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func lessThanCursorPositionIsUnsupportedDispatchLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcde12345\u{1b}[<2;1HX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcde", "1234X"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 4))
    }

    @Test
    func equalsSGRIsUnsupportedDispatchLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[31mA\u{1b}[=mB".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB  "])
        #expect(screen.snapshot.rows[0][0].attributes.foregroundColor == .ansi(.red, isBright: false))
        #expect(screen.snapshot.rows[0][1].attributes.foregroundColor == .ansi(.red, isBright: false))
    }

    @Test
    func secondaryDeviceAttributesAllowNumericParametersLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        let replies = try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[>0c".utf8)))

        #expect(replies == Array("\u{1b}[>1;10;0c".utf8))
        #expect(screen.snapshot.lineStrings == ["    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 0))
    }

    @Test
    func oscTitleStringTerminatedByBellDoesNotRenderPayload() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}]0;title\u{07}B".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func oscStringTerminatedBySTDoesNotRenderPayloadAcrossWrites() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}]2;title".utf8)))
        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}\\B".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func oscEscapeExitsStringBeforeFollowingBellControl() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}]2;title\u{1b}\u{07}B".utf8)))

        #expect(screen.snapshot.lineStrings == ["A     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
        #expect(screen.snapshot.windowTitle == "title")
        #expect(screen.snapshot.bellCount == 1)
    }

    @Test
    func oscCancelControlsExitStringBeforeNextPrintable() throws {
        var canScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))
        var subScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try canScreen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}]2;can\u{0018}B".utf8)))
        try subScreen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}]2;sub\u{001a}B".utf8)))

        #expect(canScreen.snapshot.lineStrings == ["AB  "])
        #expect(canScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
        #expect(canScreen.snapshot.windowTitle == "can")
        #expect(subScreen.snapshot.lineStrings == ["AB  "])
        #expect(subScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
        #expect(subScreen.snapshot.windowTitle == "sub")
    }

    @Test
    func dcsCancelControlExitsStringBeforeNextPrintable() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}Pignored\u{0018}B".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func oscTitleCommandsUpdateSnapshotMetadata() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 8, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}]0;both\u{07}".utf8)))

        #expect(screen.snapshot.titleInitialized == true)
        #expect(screen.snapshot.iconName == "both")
        #expect(screen.snapshot.windowTitle == "both")
        #expect(screen.snapshot.lineStrings == ["A       "])
        #expect(screen.snapshot.bellCount == 0)

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}]1;icon\u{1b}\\\u{1b}]2;window\u{07}".utf8)))

        #expect(screen.snapshot.titleInitialized == true)
        #expect(screen.snapshot.iconName == "icon")
        #expect(screen.snapshot.windowTitle == "window")
        #expect(screen.snapshot.lineStrings == ["A       "])
    }

    @Test
    func oscTitleLiveFixtureMatchesOfficialScreenState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 40, rows: 6))
        let marker = "TERMINAL-SCREEN-OSC-TITLE-OK"
        let payload = "\u{1b}]1;Mosh Icon Title\u{07}"
            + "\u{1b}]2;Mosh Window Title\u{07}"
            + "\u{1b}[2J\u{1b}[5;1H\(marker)"

        try screen.apply(MoshTerminalOutput(bytes: Array(payload.utf8)))

        #expect(screen.snapshot.titleInitialized == true)
        #expect(screen.snapshot.iconName == "Mosh Icon Title")
        #expect(screen.snapshot.windowTitle == "Mosh Window Title")
        #expect(screen.snapshot.lineStrings[4] == marker + String(repeating: " ", count: 40 - marker.count))
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 4, column: marker.count))
        #expect(screen.snapshot.bellCount == 0)
    }

    @Test
    func implicitOSCTitleCommandSetsIconAndWindowTitle() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}];implicit\u{07}".utf8)))

        #expect(screen.snapshot.titleInitialized == true)
        #expect(screen.snapshot.iconName == "implicit")
        #expect(screen.snapshot.windowTitle == "implicit")
        #expect(screen.snapshot.lineStrings == ["    "])
    }

    @Test
    func oscTitleTruncatesToOfficialLimit() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))
        let longTitle = String(repeating: "a", count: 300)

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}]2;\(longTitle)\u{07}".utf8)))

        #expect(screen.snapshot.windowTitle == String(repeating: "a", count: 254))
        #expect(screen.snapshot.iconName == "")
        #expect(screen.snapshot.titleInitialized == true)
    }

    @Test
    func oscTitleLimitLiveFixtureMatchesOfficialScreenState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 40, rows: 6))
        let marker = "TERMINAL-SCREEN-OSC-TITLE-LIMIT-OK"
        let longTitle = String(repeating: "a", count: 300)
        let expectedTitle = String(repeating: "a", count: 254)
        let payload = "\u{1b}]2;\(longTitle)\u{07}"
            + "\u{1b}[2J\u{1b}[5;1H\(marker)"

        try screen.apply(MoshTerminalOutput(bytes: Array(payload.utf8)))

        #expect(screen.snapshot.titleInitialized == true)
        #expect(screen.snapshot.iconName == "")
        #expect(screen.snapshot.windowTitle == expectedTitle)
        #expect(screen.snapshot.lineStrings[4] == marker + String(repeating: " ", count: 40 - marker.count))
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 4, column: marker.count))
        #expect(screen.snapshot.bellCount == 0)
    }

    @Test
    func oscClipboardUpdatesSnapshotWithoutRendering() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}]52;c;payload\u{07}X".utf8)))

        #expect(screen.snapshot.clipboard == "payload")
        #expect(screen.snapshot.lineStrings == ["X   "])
        #expect(screen.snapshot.bellCount == 0)
    }

    @Test
    func oscClipboardPayloadTruncatesAtOfficialCollectionLimit() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))
        let maximumOSCPayloadScalars = 16 * 1024
        let commandPrefix = "52;c;"
        let clipboardPayload = String(repeating: "a", count: maximumOSCPayloadScalars + 64)
        let expectedClipboard = String(
            repeating: "a",
            count: maximumOSCPayloadScalars - commandPrefix.count
        )

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}]\(commandPrefix)\(clipboardPayload)\u{07}".utf8)))

        #expect(screen.snapshot.clipboard == expectedClipboard)
        #expect(screen.snapshot.lineStrings == ["    "])
        #expect(screen.snapshot.bellCount == 0)
    }

    @Test
    func oscClipboardLimitLiveFixtureMatchesOfficialScreenState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 40, rows: 6))
        let maximumOSCPayloadScalars = 16 * 1024
        let marker = "TERMINAL-SCREEN-OSC-CLIPBOARD-LIMIT-OK"
        let commandPrefix = "52;c;"
        let clipboardPayload = String(repeating: "a", count: maximumOSCPayloadScalars + 64)
        let expectedClipboard = String(
            repeating: "a",
            count: maximumOSCPayloadScalars - commandPrefix.count
        )
        let payload = "\u{1b}]\(commandPrefix)\(clipboardPayload)\u{07}"
            + "\u{1b}[2J\u{1b}[5;1H\(marker)"

        try screen.apply(MoshTerminalOutput(bytes: Array(payload.utf8)))

        #expect(screen.snapshot.clipboard == expectedClipboard)
        #expect(screen.snapshot.lineStrings[4] == marker + String(repeating: " ", count: 40 - marker.count))
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 4, column: marker.count))
        #expect(screen.snapshot.bellCount == 0)
    }

    @Test
    func oscPayloadPreservesDeleteByteLikeOfficialMosh() throws {
        let delete = "\u{7f}"
        var titleScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))
        var clipboardScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try titleScreen.apply(MoshTerminalOutput(bytes: Array("\u{1b}]2;A\(delete)B\u{07}".utf8)))
        try clipboardScreen.apply(MoshTerminalOutput(bytes: Array("\u{1b}]52;c;A\(delete)B\u{07}".utf8)))

        #expect(titleScreen.snapshot.windowTitle == "A\(delete)B")
        #expect(titleScreen.snapshot.titleInitialized == true)
        #expect(clipboardScreen.snapshot.clipboard == "A\(delete)B")
    }

    @Test
    func oscDeletePayloadLiveFixtureMatchesOfficialScreenState() throws {
        let delete = "\u{7f}"
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 40, rows: 6))
        let marker = "TERMINAL-SCREEN-OSC-DELETE-OK"
        let payload = "\u{1b}]2;A\(delete)B\u{07}"
            + "\u{1b}]52;c;A\(delete)B\u{07}"
            + "\u{1b}[2J\u{1b}[5;1H\(marker)"

        try screen.apply(MoshTerminalOutput(bytes: Array(payload.utf8)))

        #expect(screen.snapshot.titleInitialized == true)
        #expect(screen.snapshot.iconName == "")
        #expect(screen.snapshot.windowTitle == "A\(delete)B")
        #expect(screen.snapshot.clipboard == "A\(delete)B")
        #expect(screen.snapshot.lineStrings[4] == marker + String(repeating: " ", count: 40 - marker.count))
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 4, column: marker.count))
        #expect(screen.snapshot.bellCount == 0)
    }

    @Test
    func osc8HyperlinkAppliesToPrintedCellsAndCanClear() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))
        let link = MoshTerminalHyperlink(parameters: "id=1", url: "https://example.test")

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("\u{1b}]8;id=1;https://example.test\u{1b}\\A\u{1b}]8;;\u{1b}\\B".utf8)
            )
        )

        #expect(screen.snapshot.lineStrings == ["AB  "])
        #expect(screen.snapshot.rows[0][0].hyperlink == link)
        #expect(screen.snapshot.rows[0][1].hyperlink == nil)
        #expect(screen.snapshot.currentHyperlink == nil)
    }

    @Test
    func osc8RejectsNonASCIIPayloadWithoutChangingCurrentHyperlink() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))
        let link = MoshTerminalHyperlink(parameters: "id=1", url: "https://example.test")

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("\u{1b}]8;id=1;https://example.test\u{1b}\\A\u{1b}]8;id=2;https://例.test\u{1b}\\B".utf8)
            )
        )

        #expect(screen.snapshot.lineStrings == ["AB  "])
        #expect(screen.snapshot.rows[0][0].hyperlink == link)
        #expect(screen.snapshot.rows[0][1].hyperlink == link)
        #expect(screen.snapshot.currentHyperlink == link)
    }

    @Test
    func resetClearsWindowTitleClipboardAndCurrentHyperlinkLikeOfficialFramebuffer() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array(
                    "\u{1b}]0;both\u{07}\u{1b}]52;c;payload\u{07}\u{1b}]8;id=1;https://example.test\u{1b}\\\u{1b}cX".utf8
                )
            )
        )

        #expect(screen.snapshot.titleInitialized == true)
        #expect(screen.snapshot.iconName == "both")
        #expect(screen.snapshot.windowTitle == "")
        #expect(screen.snapshot.clipboard == "")
        #expect(screen.snapshot.currentHyperlink == nil)
        #expect(screen.snapshot.rows[0][0].hyperlink == nil)
        #expect(screen.snapshot.lineStrings == ["X   "])
    }

    @Test
    func softResetClearsCurrentHyperlinkButPreservesTitleAndClipboard() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array(
                    "\u{1b}]2;title\u{07}\u{1b}]52;c;payload\u{07}\u{1b}]8;id=1;https://example.test\u{1b}\\\u{1b}[!pX".utf8
                )
            )
        )

        #expect(screen.snapshot.titleInitialized == true)
        #expect(screen.snapshot.windowTitle == "title")
        #expect(screen.snapshot.clipboard == "payload")
        #expect(screen.snapshot.currentHyperlink == nil)
        #expect(screen.snapshot.rows[0][0].hyperlink == nil)
        #expect(screen.snapshot.lineStrings == ["X   "])
    }

    @Test
    func stringControlC1STTerminatorEndsString() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}Pignored\u{009c}B".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func dcsPMAndAPCStringControlsDoNotRenderPayload() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}Pignored\u{1b}\\B\u{1b}^hidden\u{1b}\\C\u{1b}_skip\u{1b}\\D".utf8)))

        #expect(screen.snapshot.lineStrings == ["ABCD  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func scrollRegionConstrainsLineFeedScrolling() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 4))

        try screen.apply(MoshTerminalOutput(bytes: Array("1111222233334444\u{1b}[2;3r\u{1b}[3;1H\n".utf8)))

        #expect(screen.snapshot.lineStrings == ["1111", "3333", "    ", "4444"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 2, column: 0))
    }

    @Test
    func invalidScrollRegionClearsPendingWrapLikeOfficialDispatch() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[2;2rX".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcX", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func originModePositionsCursorRelativeToScrollRegion() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4r\u{1b}[?6h\u{1b}[1;2HX\u{1b}[9;5HY".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "     ",
            " X   ",
            "     ",
            "    Y",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 3, column: 4))
    }

    @Test
    func verticalPositionAbsoluteUsesOriginModeLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4r\u{1b}[?6h\u{1b}[3G\u{1b}[1dX\u{1b}[9dY".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "     ",
            "  X  ",
            "     ",
            "   Y ",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 3, column: 4))
    }

    @Test
    func horizontalPositionAbsoluteBacktickMatchesCHALikeOfficialMosh() throws {
        var hpaScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))
        var chaScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try hpaScreen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[2`X".utf8)))
        try chaScreen.apply(MoshTerminalOutput(bytes: Array("abcd\u{1b}[2GX".utf8)))

        #expect(hpaScreen.snapshot.lineStrings == ["aXcd", "    "])
        #expect(chaScreen.snapshot.lineStrings == ["aXcd", "    "])
        #expect(hpaScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
        #expect(chaScreen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func disablingOriginModeRestoresViewportCursorPositioning() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4r\u{1b}[?6h\u{1b}[1;1HX\u{1b}[?6l\u{1b}[1;1HY".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "Y    ",
            "X    ",
            "     ",
            "     ",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func originModeSetHomesBeforeSwitchingToScrollRegionCoordinatesLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4r\u{1b}[?6hX\u{1b}[1;1HY".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "X    ",
            "Y    ",
            "     ",
            "     ",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func originModeResetHomesBeforeSwitchingToViewportCoordinatesLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4r\u{1b}[?6h\u{1b}[2;1H\u{1b}[?6lX".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "     ",
            "X    ",
            "     ",
            "     ",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func settingScrollRegionHomesCursorInsideRegionWhenOriginModeIsEnabled() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[?6h\u{1b}[2;4rX".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "     ",
            "X    ",
            "     ",
            "     ",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func cursorUpDownIgnoreScrollRegionMarginsWhenOriginModeIsDisabledLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4r\u{1b}[3;3H\u{1b}[9BA\u{1b}[9AB".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "   B ",
            "     ",
            "     ",
            "     ",
            "  A  "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func originModeCursorUpDownStopAtScrollRegionMarginsLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4r\u{1b}[?6h\u{1b}[9BA\u{1b}[9AB".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "     ",
            " B   ",
            "     ",
            "A    ",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 2))
    }

    @Test
    func reverseIndexScrollsDownInsideScrollRegion() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 4))

        try screen.apply(MoshTerminalOutput(bytes: Array("1111222233334444\u{1b}[2;3r\u{1b}[2;1H\u{008d}".utf8)))

        #expect(screen.snapshot.lineStrings == ["1111", "    ", "2222", "4444"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 0))
    }

    @Test
    func csiInsertAndDeleteLinesRespectScrollRegion() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("aaabbbcccdddeee\u{1b}[2;5r\u{1b}[3;1H\u{1b}[L".utf8)))

        #expect(screen.snapshot.lineStrings == ["aaa", "bbb", "   ", "ccc", "ddd"])

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[M".utf8)))

        #expect(screen.snapshot.lineStrings == ["aaa", "bbb", "ccc", "ddd", "   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 2, column: 0))
    }

    @Test
    func csiInsertAndDeleteLinesMoveCursorToFirstColumn() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 4))

        try screen.apply(MoshTerminalOutput(bytes: Array("aaaaabbbbbcccccddddd\u{1b}[2;3H\u{1b}[L".utf8)))

        #expect(screen.snapshot.lineStrings == ["aaaaa", "     ", "bbbbb", "ccccc"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 0))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4H\u{1b}[M".utf8)))

        #expect(screen.snapshot.lineStrings == ["aaaaa", "bbbbb", "ccccc", "     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 0))
    }

    @Test
    func csiInsertAndDeleteLineCountsClampToRemainingScrollRegion() throws {
        var inserted = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 4))
        var deleted = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 4))
        let setup = "\u{1b}[44m"
            + "\u{1b}[1;1H111"
            + "\u{1b}[2;1H222"
            + "\u{1b}[3;1H333"
            + "\u{1b}[4;1H444"
            + "\u{1b}[2;4r"

        try inserted.apply(
            MoshTerminalOutput(bytes: Array((setup + "\u{1b}[3;2H\u{1b}[9L").utf8))
        )
        try deleted.apply(
            MoshTerminalOutput(bytes: Array((setup + "\u{1b}[2;2H\u{1b}[2M").utf8))
        )

        let eraseAttributes = MoshTerminalTextAttributes(backgroundColor: .ansi(.blue, isBright: false))
        #expect(inserted.snapshot.lineStrings == ["111", "222", "   ", "   "])
        #expect(inserted.snapshot.rows[2].allSatisfy { $0.attributes == eraseAttributes })
        #expect(inserted.snapshot.rows[3].allSatisfy { $0.attributes == eraseAttributes })
        #expect(inserted.snapshot.cursor == MoshTerminalCursor(row: 2, column: 0))

        #expect(deleted.snapshot.lineStrings == ["111", "444", "   ", "   "])
        #expect(deleted.snapshot.rows[2].allSatisfy { $0.attributes == eraseAttributes })
        #expect(deleted.snapshot.rows[3].allSatisfy { $0.attributes == eraseAttributes })
        #expect(deleted.snapshot.cursor == MoshTerminalCursor(row: 1, column: 0))
    }

    @Test
    func csiInsertLineOutsideScrollRegionStillClearsPendingWrapAndMovesToFirstColumn() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 3))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;3rabcd\u{1b}[LX".utf8)))

        #expect(screen.snapshot.lineStrings == ["Xbcd", "    ", "    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func csiScrollUpAndDownUseConfiguredScrollRegion() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("11112222333344445555\u{1b}[2;4r\u{1b}[S".utf8)))

        #expect(screen.snapshot.lineStrings == ["1111", "3333", "4444", "    ", "5555"])

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[T".utf8)))

        #expect(screen.snapshot.lineStrings == ["1111", "    ", "3333", "4444", "5555"])
    }

    @Test
    func alternateScreenPrivateModesAreConsumedWithoutChangingScreenState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("AB\u{1b}[?47hC\u{1b}[?1047hD\u{1b}[?1049h\u{1b}[?1049lE".utf8)
            )
        )

        #expect(screen.snapshot.lineStrings == ["ABCD", "E   "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func alternateScreenCursorSavePrivateModeIsConsumedWithoutRestoringCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("A\u{1b}[2;4HN\u{1b}[?1048h\u{1b}[1;5HR\u{1b}[?1048lS".utf8)
            )
        )

        #expect(screen.snapshot.lineStrings == ["A   R", "S  N "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func alternateScreenPrivateModesPreservePendingWrapLikeOfficialMosh() throws {
        var setModeScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))
        var resetModeScreen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try setModeScreen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}[?47hX".utf8)))
        try resetModeScreen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}[?1049lY".utf8)))

        #expect(setModeScreen.snapshot.lineStrings == ["abc", "X  "])
        #expect(setModeScreen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
        #expect(resetModeScreen.snapshot.lineStrings == ["abc", "Y  "])
        #expect(resetModeScreen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func sgrAppliesStylesToNewCellsAndResetRestoresDefaults() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[1;3;4;7;31mA\u{1b}[0mB".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB "])
        #expect(
            screen.snapshot.rows[0][0].attributes == MoshTerminalTextAttributes(
                intensity: .bold,
                isItalic: true,
                isUnderlined: true,
                isInverse: true,
                foregroundColor: .ansi(.red, isBright: false)
            )
        )
        #expect(screen.snapshot.rows[0][1].attributes == .default)
    }

    @Test
    func sgrSupportsBrightForegroundAndBackgroundColors() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[92;104mX".utf8)))

        #expect(screen.snapshot.lineStrings == ["X "])
        #expect(screen.snapshot.rows[0][0].attributes.foregroundColor == .ansi(.green, isBright: true))
        #expect(screen.snapshot.rows[0][0].attributes.backgroundColor == .ansi(.blue, isBright: true))
    }

    @Test
    func sgrSupportsIndexedAndRGBColors() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[38;5;196;48;2;1;2;3mX".utf8)))

        #expect(screen.snapshot.lineStrings == ["X "])
        #expect(screen.snapshot.rows[0][0].attributes.foregroundColor == .indexed(196))
        #expect(screen.snapshot.rows[0][0].attributes.backgroundColor == .rgb(red: 1, green: 2, blue: 3))
    }

    @Test
    func sgrTrueColorComponentsUseOfficialBitPackedRenditionBytes() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("\u{1b}[31;44mA\u{1b}[38;2;300;511;65535;48;2;256;257;258mB".utf8)
            )
        )

        #expect(screen.snapshot.rows[0][0].attributes.foregroundColor == .ansi(.red, isBright: false))
        #expect(screen.snapshot.rows[0][0].attributes.backgroundColor == .ansi(.blue, isBright: false))
        #expect(screen.snapshot.rows[0][1].attributes.foregroundColor == .rgb(red: 45, green: 255, blue: 255))
        #expect(screen.snapshot.rows[0][1].attributes.backgroundColor == .rgb(red: 1, green: 1, blue: 2))
    }

    @Test
    func sgrLowIndexedColorsNormalizeToANSIColorSemanticsLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("\u{1b}[38;5;0;48;5;7mA\u{1b}[38;5;8;48;5;15mB\u{1b}[38;5;16;48;5;196mC".utf8)
            )
        )

        #expect(screen.snapshot.rows[0][0].attributes.foregroundColor == .ansi(.black, isBright: false))
        #expect(screen.snapshot.rows[0][0].attributes.backgroundColor == .ansi(.white, isBright: false))
        #expect(screen.snapshot.rows[0][1].attributes.foregroundColor == .ansi(.black, isBright: true))
        #expect(screen.snapshot.rows[0][1].attributes.backgroundColor == .ansi(.white, isBright: true))
        #expect(screen.snapshot.rows[0][2].attributes.foregroundColor == .indexed(16))
        #expect(screen.snapshot.rows[0][2].attributes.backgroundColor == .indexed(196))
    }

    @Test
    func sgrOutOfRangeIndexedColorsAreConsumedWithoutBlinkLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[31;44mA\u{1b}[38;5;256;48;5;300mB".utf8)))

        #expect(screen.snapshot.rows[0][0].attributes.isBlinking == false)
        #expect(screen.snapshot.rows[0][0].attributes.foregroundColor == .ansi(.red, isBright: false))
        #expect(screen.snapshot.rows[0][0].attributes.backgroundColor == .ansi(.blue, isBright: false))
        #expect(screen.snapshot.rows[0][1].attributes.isBlinking == false)
        #expect(screen.snapshot.rows[0][1].attributes.foregroundColor == .ansi(.red, isBright: false))
        #expect(screen.snapshot.rows[0][1].attributes.backgroundColor == .ansi(.blue, isBright: false))
    }

    @Test
    func eraseCharactersUseCurrentBackgroundForBlankCellsOnly() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[1;31;44mABCD\u{1b}[1;2H\u{1b}[2X".utf8)))

        let eraseAttributes = MoshTerminalTextAttributes(backgroundColor: .ansi(.blue, isBright: false))
        #expect(screen.snapshot.lineStrings == ["A  D"])
        #expect(screen.snapshot.rows[0][0].attributes.intensity == .bold)
        #expect(screen.snapshot.rows[0][0].attributes.foregroundColor == .ansi(.red, isBright: false))
        #expect(screen.snapshot.rows[0][0].attributes.backgroundColor == .ansi(.blue, isBright: false))
        #expect(screen.snapshot.rows[0][1].attributes == eraseAttributes)
        #expect(screen.snapshot.rows[0][2].attributes == eraseAttributes)
        #expect(screen.snapshot.rows[0][3].attributes.foregroundColor == .ansi(.red, isBright: false))
    }

    @Test
    func characterShiftsUseCurrentBackgroundForIntroducedBlanks() throws {
        var inserted = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))
        var deleted = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try inserted.apply(MoshTerminalOutput(bytes: Array("\u{1b}[44mABCD\u{1b}[1;2H\u{1b}[@".utf8)))
        try deleted.apply(MoshTerminalOutput(bytes: Array("\u{1b}[44mABCD\u{1b}[1;2H\u{1b}[2P".utf8)))

        let eraseAttributes = MoshTerminalTextAttributes(backgroundColor: .ansi(.blue, isBright: false))
        #expect(inserted.snapshot.lineStrings == ["A BC"])
        #expect(inserted.snapshot.rows[0][1].attributes == eraseAttributes)
        #expect(deleted.snapshot.lineStrings == ["AD  "])
        #expect(deleted.snapshot.rows[0][2].attributes == eraseAttributes)
        #expect(deleted.snapshot.rows[0][3].attributes == eraseAttributes)
    }

    @Test
    func rowOperationsUseCurrentBackgroundForIntroducedRows() throws {
        var inserted = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 3))
        var scrolled = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 3))

        try inserted.apply(
            MoshTerminalOutput(bytes: Array("\u{1b}[44m\u{1b}[1;1HAAA\u{1b}[2;1HBBB\u{1b}[3;1HCCC\u{1b}[2;1H\u{1b}[L".utf8))
        )
        try scrolled.apply(
            MoshTerminalOutput(bytes: Array("\u{1b}[44m\u{1b}[1;1HAAA\u{1b}[2;1HBBB\u{1b}[3;1HCCC\u{1b}[S".utf8))
        )

        let eraseAttributes = MoshTerminalTextAttributes(backgroundColor: .ansi(.blue, isBright: false))
        #expect(inserted.snapshot.lineStrings == ["AAA", "   ", "BBB"])
        #expect(inserted.snapshot.rows[1].allSatisfy { $0.attributes == eraseAttributes })
        #expect(scrolled.snapshot.lineStrings == ["BBB", "CCC", "   "])
        #expect(scrolled.snapshot.rows[2].allSatisfy { $0.attributes == eraseAttributes })
    }

    @Test
    func resizeIntroducedCellsUseCurrentBackground() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[44mAB".utf8)))
        screen.resize(try MoshTerminalDimensions(columns: 4, rows: 2))

        let eraseAttributes = MoshTerminalTextAttributes(backgroundColor: .ansi(.blue, isBright: false))
        #expect(screen.snapshot.lineStrings == ["AB  ", "    "])
        #expect(screen.snapshot.rows[0][2].attributes == eraseAttributes)
        #expect(screen.snapshot.rows[0][3].attributes == eraseAttributes)
        #expect(screen.snapshot.rows[1].allSatisfy { $0.attributes == eraseAttributes })
    }

    @Test
    func decScreenAlignmentUsesCurrentBackgroundOnly() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[1;31;44m\u{1b}#8".utf8)))

        let eraseAttributes = MoshTerminalTextAttributes(backgroundColor: .ansi(.blue, isBright: false))
        #expect(screen.snapshot.lineStrings == ["EE"])
        #expect(screen.snapshot.rows[0][0].attributes == eraseAttributes)
        #expect(screen.snapshot.rows[0][1].attributes == eraseAttributes)
    }

    @Test
    func sgrDisableCodesClearIndividualAttributes() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(
            MoshTerminalOutput(bytes: Array("\u{1b}[1;3;4;7;33;44mA\u{1b}[22;23;24;27;39;49mB".utf8))
        )

        #expect(screen.snapshot.lineStrings == ["AB "])
        #expect(screen.snapshot.rows[0][0].attributes.intensity == .bold)
        #expect(screen.snapshot.rows[0][0].attributes.isItalic == true)
        #expect(screen.snapshot.rows[0][0].attributes.isUnderlined == true)
        #expect(screen.snapshot.rows[0][0].attributes.isInverse == true)
        #expect(screen.snapshot.rows[0][0].attributes.foregroundColor == .ansi(.yellow, isBright: false))
        #expect(screen.snapshot.rows[0][0].attributes.backgroundColor == .ansi(.blue, isBright: false))
        #expect(screen.snapshot.rows[0][1].attributes == .default)
    }

    @Test
    func sgrFaintCodeIsIgnoredToMatchOfficialRenditions() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2mA\u{1b}[1mB\u{1b}[22mC".utf8)))

        #expect(screen.snapshot.lineStrings == ["ABC"])
        #expect(screen.snapshot.rows[0][0].attributes.intensity == .normal)
        #expect(screen.snapshot.rows[0][1].attributes.intensity == .bold)
        #expect(screen.snapshot.rows[0][2].attributes.intensity == .normal)
    }

    @Test
    func sgrBlinkAndInvisibleFollowOfficialRenditionSetAndResetCodes() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[5;8mA\u{1b}[25mB\u{1b}[28mC\u{1b}[0mD".utf8)))

        #expect(screen.snapshot.lineStrings == ["ABCD"])
        #expect(screen.snapshot.rows[0][0].attributes.isBlinking == true)
        #expect(screen.snapshot.rows[0][0].attributes.isInvisible == true)
        #expect(screen.snapshot.rows[0][1].attributes.isBlinking == false)
        #expect(screen.snapshot.rows[0][1].attributes.isInvisible == true)
        #expect(screen.snapshot.rows[0][2].attributes.isBlinking == false)
        #expect(screen.snapshot.rows[0][2].attributes.isInvisible == false)
        #expect(screen.snapshot.rows[0][3].attributes == .default)
    }

    @Test
    func emptySGRSequenceResetsAttributes() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[31mA\u{1b}[mB".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB "])
        #expect(screen.snapshot.rows[0][0].attributes.foregroundColor == .ansi(.red, isBright: false))
        #expect(screen.snapshot.rows[0][1].attributes == .default)
    }

    @Test
    func resetEscapeClearsScreenAndCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("hello\u{1b}c".utf8)))

        #expect(screen.snapshot.lineStrings == ["     ", "     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 0))
    }

    @Test
    func combiningScalarsAttachToPreviousCell() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("e\u{0301}x".utf8)))

        #expect(screen.snapshot.lineStrings == ["e\u{0301}x "])
        #expect(screen.snapshot.rows[0][0].contents == "e\u{0301}")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func combiningScalarAtLineStartUsesOfficialFallbackCellAndAdvances() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{0301}A".utf8)))

        #expect(screen.snapshot.lineStrings == ["\u{00a0}\u{0301}A "])
        #expect(screen.snapshot.rows[0][0].contents == "\u{00a0}\u{0301}")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func combiningScalarAfterLineFeedUsesOfficialFallbackAtCurrentCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\n\u{0301}B".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "A   ",
            " \u{00a0}\u{0301}B "
        ])
        #expect(screen.snapshot.rows[1][1].contents == "\u{00a0}\u{0301}")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 3))
    }

    @Test
    func combiningScalarAppendStopsAtOfficialCellByteLimit() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))
        let accents = String(repeating: "\u{0301}", count: 20)
        let expectedAccents = String(repeating: "\u{0301}", count: 16)

        try screen.apply(MoshTerminalOutput(bytes: Array("A\(accents)B".utf8)))

        #expect(screen.snapshot.rows[0][0].contents == "A\(expectedAccents)")
        #expect(screen.snapshot.rows[0][1].contents == "B")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func combiningFallbackCellAppendStopsAtOfficialCellByteLimit() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))
        let accents = String(repeating: "\u{0301}", count: 20)
        let expectedAccents = String(repeating: "\u{0301}", count: 16)

        try screen.apply(MoshTerminalOutput(bytes: Array("\(accents)B".utf8)))

        #expect(screen.snapshot.rows[0][0].contents == "\u{00a0}\(expectedAccents)")
        #expect(screen.snapshot.rows[0][1].contents == "B")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func wideScalarsOccupyTwoCellsAndAdvanceByTwoColumns() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A中B".utf8)))

        #expect(screen.snapshot.lineStrings == ["A中 B "])
        #expect(screen.snapshot.rows[0][1].contents == "中")
        #expect(screen.snapshot.rows[0][1].displayWidth == 2)
        #expect(screen.snapshot.rows[0][2].isContinuation == true)
        #expect(screen.snapshot.rows[0][2].displayWidth == 0)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func unicodeWidthLiveFixtureMatchesOfficialScreenState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 40, rows: 6))
        let marker = "TERMINAL-SCREEN-UNICODE-WIDTH-OK"
        let payload = "\u{1b}[2J\u{1b}[H"
            + "A中B"
            + "\u{1b}[2;1He\u{0301}x"
            + "\u{1b}[3;1H\u{0301}A"
            + "\u{1b}[4;40H中X"
            + "\u{1b}[6;1H\(marker)"

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array(payload.utf8)
            )
        )

        #expect(screen.snapshot.lineStrings == [
            "A中 B" + String(repeating: " ", count: 36),
            "e\u{0301}x" + String(repeating: " ", count: 38),
            "\u{00a0}\u{0301}A" + String(repeating: " ", count: 38),
            String(repeating: " ", count: 40),
            "中 X" + String(repeating: " ", count: 37),
            marker + String(repeating: " ", count: 40 - marker.count)
        ])
        #expect(screen.snapshot.rows[0][1].contents == "中")
        #expect(screen.snapshot.rows[0][1].displayWidth == 2)
        #expect(screen.snapshot.rows[0][2].isContinuation == true)
        #expect(screen.snapshot.rows[1][0].contents == "e\u{0301}")
        #expect(screen.snapshot.rows[2][0].contents == "\u{00a0}\u{0301}")
        #expect(screen.snapshot.rows[4][0].contents == "中")
        #expect(screen.snapshot.rows[4][0].displayWidth == 2)
        #expect(screen.snapshot.rows[4][1].isContinuation == true)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 5, column: marker.count))
    }

    @Test
    func printableISO88591LiveFixtureMatchesOfficialScreenState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 40, rows: 6))
        let marker = "TERMINAL-SCREEN-LATIN1-OK"
        let payload = "\u{1b}[2J\u{1b}[H"
            + "A\u{00a1}B\u{00ff}C"
            + "\u{1b}[2;40H\u{00a1}X"
            + "\u{1b}[6;1H\(marker)"

        try screen.apply(MoshTerminalOutput(bytes: Array(payload.utf8)))

        #expect(screen.snapshot.lineStrings == [
            "A\u{00a1}B\u{00ff}C" + String(repeating: " ", count: 35),
            String(repeating: " ", count: 39) + "\u{00a1}",
            "X" + String(repeating: " ", count: 39),
            String(repeating: " ", count: 40),
            String(repeating: " ", count: 40),
            marker + String(repeating: " ", count: 40 - marker.count)
        ])
        #expect(screen.snapshot.rows[0][1].contents == "\u{00a1}")
        #expect(screen.snapshot.rows[0][1].displayWidth == 1)
        #expect(screen.snapshot.rows[0][3].contents == "\u{00ff}")
        #expect(screen.snapshot.rows[0][3].displayWidth == 1)
        #expect(screen.snapshot.rows[1][39].contents == "\u{00a1}")
        #expect(screen.snapshot.rows[1][39].displayWidth == 1)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 5, column: marker.count))
    }

    @Test
    func printableISO88591FormatScalarsAreNarrowLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{00ad}B".utf8)))

        #expect(screen.snapshot.rows[0][0].contents == "A")
        #expect(screen.snapshot.rows[0][1].contents == "\u{00ad}")
        #expect(screen.snapshot.rows[0][2].contents == "B")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func emojiPresentationScalarsOccupyTwoCells() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("🙂X".utf8)))

        #expect(screen.snapshot.lineStrings == ["🙂 X "])
        #expect(screen.snapshot.rows[0][0].displayWidth == 2)
        #expect(screen.snapshot.rows[0][1].isContinuation == true)
        #expect(screen.snapshot.rows[0][2].contents == "X")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func emojiModifierScalarsOccupySeparateWideCellsLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("👍🏽X".utf8)))

        #expect(screen.snapshot.lineStrings == ["👍 🏽 X "])
        #expect(screen.snapshot.rows[0][0].contents == "👍")
        #expect(screen.snapshot.rows[0][0].displayWidth == 2)
        #expect(screen.snapshot.rows[0][1].isContinuation == true)
        #expect(screen.snapshot.rows[0][2].contents == "🏽")
        #expect(screen.snapshot.rows[0][2].displayWidth == 2)
        #expect(screen.snapshot.rows[0][3].isContinuation == true)
        #expect(screen.snapshot.rows[0][4].contents == "X")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 5))
    }

    @Test
    func zwjEmojiSequenceKeepsFollowingWideScalarInSeparateCellLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("👩‍💻X".utf8)))

        #expect(screen.snapshot.lineStrings == ["👩‍ 💻 X "])
        #expect(screen.snapshot.rows[0][0].contents == "👩‍")
        #expect(screen.snapshot.rows[0][0].displayWidth == 2)
        #expect(screen.snapshot.rows[0][1].isContinuation == true)
        #expect(screen.snapshot.rows[0][2].contents == "💻")
        #expect(screen.snapshot.rows[0][2].displayWidth == 2)
        #expect(screen.snapshot.rows[0][3].isContinuation == true)
        #expect(screen.snapshot.rows[0][4].contents == "X")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 5))
    }

    @Test
    func emojiGraphemeOverwriteLiveFixtureMatchesOfficialScreenState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 40, rows: 6))
        let marker = "TERMINAL-SCREEN-EMOJI-GRAPHEME-OK"
        let payload = "\u{1b}[2J\u{1b}[H"
            + "👩‍💻\u{1b}[1;3HZ"
            + "\u{1b}[2;1H👍🏽\u{1b}[2;3HZ"
            + "\u{1b}[6;1H\(marker)"

        try screen.apply(MoshTerminalOutput(bytes: Array(payload.utf8)))

        #expect(screen.snapshot.lineStrings == [
            "👩‍ Z" + String(repeating: " ", count: 37),
            "👍 Z" + String(repeating: " ", count: 37),
            String(repeating: " ", count: 40),
            String(repeating: " ", count: 40),
            String(repeating: " ", count: 40),
            marker + String(repeating: " ", count: 40 - marker.count)
        ])
        #expect(screen.snapshot.rows[0][0].contents == "👩‍")
        #expect(screen.snapshot.rows[0][1].isContinuation == true)
        #expect(screen.snapshot.rows[0][2].contents == "Z")
        #expect(screen.snapshot.rows[1][0].contents == "👍")
        #expect(screen.snapshot.rows[1][1].isContinuation == true)
        #expect(screen.snapshot.rows[1][2].contents == "Z")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 5, column: marker.count))
    }

    @Test
    func wideScalarWrapsBeforeRightEdgeWhenItCannotFit() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("ab中".utf8)))

        #expect(screen.snapshot.lineStrings == ["ab ", "中  "])
        #expect(screen.snapshot.rows[1][0].displayWidth == 2)
        #expect(screen.snapshot.rows[1][1].isContinuation == true)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 2))
    }

    @Test
    func wideScalarInSingleColumnScreenUsesSingleCell() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 1, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("中".utf8)))

        #expect(screen.snapshot.lineStrings == ["中"])
        #expect(screen.snapshot.rows[0][0].displayWidth == 1)
        #expect(screen.snapshot.rows[0][0].isContinuation == false)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 0))
    }

    @Test
    func insertCharactersPreservesShiftedWideScalarContinuations() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A中B\u{1b}[1;2H\u{1b}[@".utf8)))

        #expect(screen.snapshot.lineStrings == ["A 中 B "])
        #expect(screen.snapshot.rows[0][2].contents == "中")
        #expect(screen.snapshot.rows[0][2].displayWidth == 2)
        #expect(screen.snapshot.rows[0][3].isContinuation == true)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func deleteCharactersCanRemoveWideScalarWithoutLeavingContinuation() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A中B\u{1b}[1;2H\u{1b}[2P".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB    "])
        #expect(screen.snapshot.rows[0][2].isContinuation == false)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func eraseCharactersClearsIntersectedWideScalar() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A中B\u{1b}[1;3H\u{1b}[X".utf8)))

        #expect(screen.snapshot.lineStrings == ["A  B  "])
        #expect(screen.snapshot.rows[0][1].isContinuation == false)
        #expect(screen.snapshot.rows[0][2].isContinuation == false)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func overwritingWideScalarClearsContinuationCell() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("中\u{1b}[1;1HX".utf8)))

        #expect(screen.snapshot.lineStrings == ["X   "])
        #expect(screen.snapshot.rows[0][1].isContinuation == false)
        #expect(screen.snapshot.rows[0][1].contents == " ")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func backspaceMovesAcrossWideScalar() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("中\u{08}A".utf8)))

        #expect(screen.snapshot.lineStrings == ["A   "])
        #expect(screen.snapshot.rows[0][1].isContinuation == false)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func zeroWidthFormatScalarsAttachWithoutAdvancingCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("e\u{0301}A\u{fe0f}B".utf8)))

        #expect(screen.snapshot.lineStrings == ["e\u{0301}A\u{fe0f}B "])
        #expect(screen.snapshot.rows[0][0].contents == "e\u{0301}")
        #expect(screen.snapshot.rows[0][1].contents == "A\u{fe0f}")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func invalidUTF8FromOutputRendersReplacementAndContinuesLikeOfficialMosh() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: [0xe2, 0x28, 0xa1, 0x58]))

        #expect(screen.snapshot.lineStrings == ["\u{fffd}(\u{fffd}X "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }
}
