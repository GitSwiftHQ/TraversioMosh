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
    func reenabledAutoWrapModeRestoresDeferredWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("ab\u{1b}[?7lX\u{1b}[?7hYZ".utf8)))

        #expect(screen.snapshot.lineStrings == ["abY", "Z  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
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
    func saveRestoreCursorPreservesPendingWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}7\u{1b}[1;1H!\u{1b}8X".utf8)))

        #expect(screen.snapshot.lineStrings == ["!bc", "X  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
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
    func csiSaveAndRestoreCursorMatchesEscapeSaveRestore() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("ab\u{1b}[s\u{1b}[1;1H!\u{1b}[uX".utf8)))

        #expect(screen.snapshot.lineStrings == ["!bX "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
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
    func decSpecialGraphicsG0MapsLineDrawingCharacters() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 8, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}(0lqk\u{1b}(Babc".utf8)))

        #expect(screen.snapshot.lineStrings == ["┌─┐abc  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 6))
    }

    @Test
    func decSpecialGraphicsMapsCompleteVT100Range() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 32, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}(0_`abcdefghijklmnopqrstuvwxyz{|}~".utf8)))

        #expect(screen.snapshot.lineStrings == ["▮◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 31))
    }

    @Test
    func shiftOutUsesG1AndShiftInRestoresG0() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 7, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b})0A\u{0e}xq\u{0f}xq".utf8)))

        #expect(screen.snapshot.lineStrings == ["A│─xq  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 5))
    }

    @Test
    func designatingG0DoesNotOverrideActiveG1Selection() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b})0\u{0e}\u{1b}(Bq\u{0f}q".utf8)))

        #expect(screen.snapshot.lineStrings == ["─q "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func saveRestoreCursorPreservesCharacterSetState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}(0\u{1b}7\u{1b}(Bq\u{1b}8q".utf8)))

        #expect(screen.snapshot.lineStrings == ["A─ "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func resetRestoresASCIICharacterSetDesignation() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}(0\u{1b}cq".utf8)))

        #expect(screen.snapshot.lineStrings == ["q "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func decScreenAlignmentFillsCompleteScreenAndHomesCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcde\u{1b}#8".utf8)))

        #expect(screen.snapshot.lineStrings == ["EEE", "EEE"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 0))
    }

    @Test
    func decScreenAlignmentClearsPendingWrapBeforeNextPrintable() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\u{1b}#8X".utf8)))

        #expect(screen.snapshot.lineStrings == ["XEE", "EEE"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func decScreenAlignmentResetsScrollRegionToFullScreen() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 4))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;3r\u{1b}#8\u{1b}[4;1H\nX".utf8)))

        #expect(screen.snapshot.lineStrings == ["EEE", "EEE", "EEE", "X  "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 3, column: 1))
    }

    @Test
    func decScreenAlignmentResetsOriginModeAndRendition() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 3))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;3r\u{1b}[?6h\u{1b}[31m\u{1b}#8X".utf8)))

        #expect(screen.snapshot.lineStrings == ["XEE", "EEE", "EEE"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
        #expect(screen.snapshot.rows[0][0].attributes == .default)
        #expect(screen.snapshot.rows[0][1].attributes == .default)
    }

    @Test
    func decScreenAlignmentCanBeSplitAcrossWrites() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("ab\u{1b}#".utf8)))
        try screen.apply(MoshTerminalOutput(bytes: Array("8".utf8)))

        #expect(screen.snapshot.lineStrings == ["EE", "EE"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 0))
    }

    @Test
    func unsupportedHashEscapeFinalDoesNotRenderFinalByte() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}#9B".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func decLineRenditionSequencesUpdateCurrentRows() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 4))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}#3\n\u{1b}#4\n\u{1b}#5\n\u{1b}#6".utf8)))

        #expect(screen.snapshot.lineRenditions == [
            .doubleHeightTop,
            .doubleHeightBottom,
            .singleWidth,
            .doubleWidth
        ])
    }

    @Test
    func decDoubleWidthLineDiscardsRightHalfAndClampsCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcdef\u{1b}[1;6H\u{1b}#6X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abX   "])
        #expect(screen.snapshot.lineRenditions == [.doubleWidth])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func decSingleWidthLineRestoresFullWidthCapacityWithoutRestoringDiscardedCells() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcdef\u{1b}#6\u{1b}#5\u{1b}[1;6HZ".utf8)))

        #expect(screen.snapshot.lineStrings == ["abc  Z"])
        #expect(screen.snapshot.lineRenditions == [.singleWidth])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 5))
    }

    @Test
    func decLineRenditionsMoveWithScrolledRowsAndNewRowsAreSingleWidth() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 3))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}#6\n\u{1b}#3\u{1b}[3;1H\n".utf8)))

        #expect(screen.snapshot.lineRenditions == [
            .doubleHeightTop,
            .singleWidth,
            .singleWidth
        ])
    }

    @Test
    func alternateScreenPreservesLineRenditionsSeparately() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}#6\u{1b}[?1049h\u{1b}#3\u{1b}[?1049l".utf8)))

        #expect(screen.snapshot.lineRenditions == [
            .doubleWidth,
            .singleWidth
        ])
    }

    @Test
    func resetAndScreenAlignmentRestoreSingleWidthLines() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}#6\n\u{1b}#3\u{1b}#8".utf8)))

        #expect(screen.snapshot.lineRenditions == [.singleWidth, .singleWidth])

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}#6\u{1b}c".utf8)))

        #expect(screen.snapshot.lineRenditions == [.singleWidth, .singleWidth])
    }

    @Test
    func resizePreservesLineRenditionsAndReclampsDoubleWidthCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcdef\u{1b}[1;3H\u{1b}#6".utf8)))
        screen.resize(try MoshTerminalDimensions(columns: 4, rows: 2))

        #expect(screen.snapshot.lineStrings == ["ab  ", "    "])
        #expect(screen.snapshot.lineRenditions == [.doubleWidth, .singleWidth])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 1))
    }

    @Test
    func savedCursorRestoreReclampsToDoubleWidthLine() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcdef\u{1b}[1;6H\u{1b}7\u{1b}#6\u{1b}8X".utf8)))

        #expect(screen.snapshot.lineStrings == ["abX   "])
        #expect(screen.snapshot.lineRenditions == [.doubleWidth])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
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

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[3g\u{1b}[4G\u{1b}H\r\tX".utf8)))

        #expect(screen.snapshot.lineStrings == ["   X        "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func tabClearCurrentRemovesCustomTabStop() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 12, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[3g\u{1b}[4G\u{1b}H\u{1b}[g\r\tX".utf8)))

        #expect(screen.snapshot.lineStrings == ["           X"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 11))
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
    func csiNextAndPrecedingLineMoveToColumnZero() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 3))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4H\u{1b}[EZ\u{1b}[FQ".utf8)))

        #expect(screen.snapshot.lineStrings == ["     ", "Q    ", "Z    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func csiHorizontalAndVerticalPositioningMovesCursor() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 8, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;2H\u{1b}[4`A\u{1b}[2aB\u{1b}[4dC\u{1b}[1eD".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "        ",
            "   A  B ",
            "        ",
            "       C",
            "       D"
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 4, column: 7))
    }

    @Test
    func csiForwardAndBackwardTabulationUseTabStops() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 20, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[3C\u{1b}[2I\u{1b}[Z".utf8)))

        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 8))
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
    func csiEraseScreenDoesNotPrintEscapePayload() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("hello\u{1b}[2J".utf8)))

        #expect(screen.snapshot.lineStrings == ["     ", "     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
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
    func oscBellTerminatorAfterEscapeStillEndsString() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 6, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("A\u{1b}]2;title\u{1b}\u{07}B".utf8)))

        #expect(screen.snapshot.lineStrings == ["AB    "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
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
    func cursorUpDownStopAtScrollRegionMargins() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4r\u{1b}[3;3H\u{1b}[9BA\u{1b}[9AB".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "     ",
            "   B ",
            "     ",
            "  A  ",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 4))
    }

    @Test
    func cursorNextAndPrecedingLineStopAtScrollRegionMargins() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[2;4r\u{1b}[3;3H\u{1b}[9EA\u{1b}[9FB".utf8)))

        #expect(screen.snapshot.lineStrings == [
            "     ",
            "B    ",
            "     ",
            "A    ",
            "     "
        ])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
    }

    @Test
    func reverseIndexScrollsDownInsideScrollRegion() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 4))

        try screen.apply(MoshTerminalOutput(bytes: Array("1111222233334444\u{1b}[2;3r\u{1b}[2;1H\u{1b}M".utf8)))

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
    func csiScrollUpAndDownUseConfiguredScrollRegion() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 5))

        try screen.apply(MoshTerminalOutput(bytes: Array("11112222333344445555\u{1b}[2;4r\u{1b}[S".utf8)))

        #expect(screen.snapshot.lineStrings == ["1111", "3333", "4444", "    ", "5555"])

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[T".utf8)))

        #expect(screen.snapshot.lineStrings == ["1111", "    ", "3333", "4444", "5555"])
    }

    @Test
    func alternateScreen1049ClearsAndRestoresNormalBufferCursorAndAttributes() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 4, rows: 2))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("main\u{1b}[2;3H\u{1b}[31mX\u{1b}[?1049halt\u{1b}[?1049lY".utf8)
            )
        )

        #expect(screen.snapshot.lineStrings == ["main", "  XY"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 3))
        #expect(screen.snapshot.rows[1][3].attributes.foregroundColor == .ansi(.red, isBright: false))
    }

    @Test
    func alternateScreenUsesSeparateSavedCursorState() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(
            MoshTerminalOutput(
                bytes: Array("A\u{1b}[2;4H\u{1b}[31mN\u{1b}[?1049hQ\u{1b}7\u{1b}[1;5HR\u{1b}8S\u{1b}[?1049lY".utf8)
            )
        )

        #expect(screen.snapshot.lineStrings == ["A    ", "   NY"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 4))
        #expect(screen.snapshot.rows[1][4].attributes.foregroundColor == .ansi(.red, isBright: false))
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
    func emojiModifierAttachesToPreviousEmojiCell() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("👍🏽X".utf8)))

        #expect(screen.snapshot.lineStrings == ["👍🏽 X  "])
        #expect(screen.snapshot.rows[0][0].contents == "👍🏽")
        #expect(screen.snapshot.rows[0][0].displayWidth == 2)
        #expect(screen.snapshot.rows[0][1].isContinuation == true)
        #expect(screen.snapshot.rows[0][2].contents == "X")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func zwjEmojiClusterUsesOneWideCell() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 1))

        try screen.apply(MoshTerminalOutput(bytes: Array("👩‍💻X".utf8)))

        #expect(screen.snapshot.lineStrings == ["👩‍💻 X  "])
        #expect(screen.snapshot.rows[0][0].contents == "👩‍💻")
        #expect(screen.snapshot.rows[0][0].displayWidth == 2)
        #expect(screen.snapshot.rows[0][1].isContinuation == true)
        #expect(screen.snapshot.rows[0][2].contents == "X")
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 3))
    }

    @Test
    func zwjEmojiClusterPreservesDeferredWrap() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 2, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("👩‍💻X".utf8)))

        #expect(screen.snapshot.lineStrings == ["👩‍💻 ", "X "])
        #expect(screen.snapshot.rows[0][0].contents == "👩‍💻")
        #expect(screen.snapshot.rows[0][1].isContinuation == true)
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 1))
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
    func invalidUTF8FromOutputFailsAtParserBoundary() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        #expect(throws: MoshTerminalInputParserError.invalidUTF8(offset: 0)) {
            try screen.apply(MoshTerminalOutput(bytes: [0xe2, 0x28, 0xa1]))
        }
        #expect(screen.snapshot.lineStrings == ["   "])
    }
}
