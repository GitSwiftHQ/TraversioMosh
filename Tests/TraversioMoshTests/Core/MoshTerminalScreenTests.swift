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
    func appliesCarriageReturnLineFeedBackspaceAndTab() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 8, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abc\rZ\nQR\u{08}!\tT".utf8)))

        #expect(screen.snapshot.lineStrings == ["Zbc     ", " Q!    T"])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 1, column: 7))
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
    func csiRelativeCursorMovementAndLineEraseMutateScreen() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("abcde\u{1b}[1DX\u{1b}[K".utf8)))

        #expect(screen.snapshot.lineStrings == ["abcX ", "     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
    }

    @Test
    func csiEraseScreenDoesNotPrintEscapePayload() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 5, rows: 2))

        try screen.apply(MoshTerminalOutput(bytes: Array("hello\u{1b}[2J".utf8)))

        #expect(screen.snapshot.lineStrings == ["     ", "     "])
        #expect(screen.snapshot.cursor == MoshTerminalCursor(row: 0, column: 4))
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
    func invalidUTF8FromOutputFailsAtParserBoundary() throws {
        var screen = try MoshTerminalScreen(dimensions: MoshTerminalDimensions(columns: 3, rows: 1))

        #expect(throws: MoshTerminalInputParserError.invalidUTF8(offset: 0)) {
            try screen.apply(MoshTerminalOutput(bytes: [0xe2, 0x28, 0xa1]))
        }
        #expect(screen.snapshot.lineStrings == ["   "])
    }
}
