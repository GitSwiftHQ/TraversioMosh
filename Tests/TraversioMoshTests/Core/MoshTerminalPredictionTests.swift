// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
@testable import TraversioMoshCore

struct MoshTerminalPredictionTests {
    @Test
    func predictsNarrowUnicodeInputAfterConfirmedEpoch() throws {
        let dimensions = try MoshTerminalDimensions(columns: 4, rows: 1)
        var screen = MoshTerminalScreen(dimensions: dimensions)
        var prediction = MoshTerminalPredictionEngine(
            configuration: MoshPredictionConfiguration(displayPreference: .always)
        )

        prediction.setLocalFrameSent(1)
        prediction.registerUserInput(
            Array("a".utf8),
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 0
        )

        #expect(prediction.projectedSnapshot(baseSnapshot: screen.snapshot).lineStrings == ["    "])

        try screen.apply(MoshTerminalOutput(bytes: Array("a".utf8)))
        prediction.setLocalFrameLateAcknowledged(2)
        prediction.cull(baseSnapshot: screen.snapshot, nowMilliseconds: 1)

        prediction.setLocalFrameSent(2)
        prediction.registerUserInput(
            Array("\u{00e9}".utf8),
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 2
        )

        let projected = prediction.projectedSnapshot(baseSnapshot: screen.snapshot)

        #expect(projected.lineStrings == ["a\u{00e9}  "])
        #expect(projected.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func bulkInputLargerThanOfficialReadThresholdClearsActivePredictions() throws {
        let dimensions = try MoshTerminalDimensions(columns: 6, rows: 1)
        var screen = MoshTerminalScreen(dimensions: dimensions)
        var prediction = MoshTerminalPredictionEngine(
            configuration: MoshPredictionConfiguration(displayPreference: .always)
        )

        prediction.setLocalFrameSent(1)
        prediction.registerUserInput(
            Array("a".utf8),
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 0
        )

        try screen.apply(MoshTerminalOutput(bytes: Array("a".utf8)))
        prediction.setLocalFrameLateAcknowledged(2)
        prediction.cull(baseSnapshot: screen.snapshot, nowMilliseconds: 1)

        prediction.setLocalFrameSent(2)
        prediction.registerUserInput(
            Array("b".utf8),
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 2
        )

        #expect(prediction.projectedSnapshot(baseSnapshot: screen.snapshot).lineStrings == ["ab    "])

        prediction.registerUserInput(
            Array(repeating: UInt8(ascii: "x"), count: 101),
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 3
        )

        #expect(prediction.projectedSnapshot(baseSnapshot: screen.snapshot).lineStrings == ["a     "])
    }

    @Test
    func delayedBlankPredictionDoesNotUnderlineAlreadyBlankCells() throws {
        let dimensions = try MoshTerminalDimensions(columns: 4, rows: 1)
        let screen = MoshTerminalScreen(dimensions: dimensions)
        var prediction = MoshTerminalPredictionEngine(
            configuration: MoshPredictionConfiguration(displayPreference: .experimental)
        )

        prediction.setLocalFrameSent(1)
        prediction.registerUserInput(
            [UInt8(ascii: "\r")],
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 0
        )
        prediction.cull(baseSnapshot: screen.snapshot, nowMilliseconds: 5_000)

        let projected = prediction.projectedSnapshot(baseSnapshot: screen.snapshot)

        #expect(projected.lineStrings == ["    "])
        #expect(projected.rows[0].allSatisfy { $0.attributes.isUnderlined == false })
    }

    @Test
    func bottomRowBlankPredictionClearsReplacementRenditionsLikeOfficialMosh() throws {
        let dimensions = try MoshTerminalDimensions(columns: 4, rows: 1)
        var screen = MoshTerminalScreen(dimensions: dimensions)
        var prediction = MoshTerminalPredictionEngine(
            configuration: MoshPredictionConfiguration(displayPreference: .experimental)
        )

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[41mABC".utf8)))
        prediction.setLocalFrameSent(1)
        prediction.registerUserInput(
            [UInt8(ascii: "\r")],
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 0
        )
        prediction.cull(baseSnapshot: screen.snapshot, nowMilliseconds: 1)

        let projected = prediction.projectedSnapshot(baseSnapshot: screen.snapshot)
        let projectedAttributes = projected.rows[0].map(\.attributes)
        var underlinedPredictionAttributes = MoshTerminalTextAttributes.default
        underlinedPredictionAttributes.isUnderlined = true

        #expect(projected.lineStrings == ["    "])
        #expect(projectedAttributes == [
            underlinedPredictionAttributes,
            underlinedPredictionAttributes,
            underlinedPredictionAttributes,
            .default
        ])
    }

    @Test
    func unknownPredictionUnderlinesExistingCellExceptLastColumn() throws {
        let dimensions = try MoshTerminalDimensions(columns: 4, rows: 1)
        var screen = MoshTerminalScreen(dimensions: dimensions)
        var prediction = MoshTerminalPredictionEngine(
            configuration: MoshPredictionConfiguration(displayPreference: .experimental)
        )

        try screen.apply(MoshTerminalOutput(bytes: Array("ABCD\u{1b}[1;3H".utf8)))
        prediction.setLocalFrameSent(1)
        prediction.setSendIntervalMilliseconds(81)
        prediction.registerUserInput(
            [0x7f, 0x7f],
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 0
        )
        prediction.cull(baseSnapshot: screen.snapshot, nowMilliseconds: 1)

        let projected = prediction.projectedSnapshot(baseSnapshot: screen.snapshot)

        #expect(projected.lineStrings == ["CBCD"])
        #expect(projected.rows[0].map { $0.attributes.isUnderlined } == [true, true, true, false])
    }

    @Test
    func confirmedEchoUpdatesLaterPredictionAttributesLikeOfficialOverlay() throws {
        let dimensions = try MoshTerminalDimensions(columns: 4, rows: 1)
        var screen = MoshTerminalScreen(dimensions: dimensions)
        var prediction = MoshTerminalPredictionEngine(
            configuration: MoshPredictionConfiguration(displayPreference: .always)
        )
        prediction.setSendIntervalMilliseconds(20)

        prediction.setLocalFrameSent(1)
        prediction.registerUserInput(
            Array("a".utf8),
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 0
        )
        prediction.setLocalFrameSent(2)
        prediction.registerUserInput(
            Array("b".utf8),
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 1
        )

        try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[31ma".utf8)))
        prediction.setLocalFrameLateAcknowledged(2)
        prediction.cull(baseSnapshot: screen.snapshot, nowMilliseconds: 2)

        let projected = prediction.projectedSnapshot(baseSnapshot: screen.snapshot)
        let confirmedAttributes = projected.rows[0][0].attributes

        #expect(projected.lineStrings == ["ab  "])
        #expect(confirmedAttributes.foregroundColor == .ansi(.red, isBright: false))
        #expect(projected.rows[0][1].attributes == confirmedAttributes)
    }

    @Test
    func escapeRestartBeforeSS3CursorControlMatchesOfficialOverlayParser() throws {
        let dimensions = try MoshTerminalDimensions(columns: 4, rows: 1)
        var screen = MoshTerminalScreen(dimensions: dimensions)
        var prediction = MoshTerminalPredictionEngine(
            configuration: MoshPredictionConfiguration(displayPreference: .experimental)
        )

        try screen.apply(MoshTerminalOutput(bytes: Array("ABCD\u{1b}[1;2H".utf8)))
        prediction.registerUserInput(
            [0x1b, 0x1b, UInt8(ascii: "O"), UInt8(ascii: "C")],
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 0
        )

        let projected = prediction.projectedSnapshot(baseSnapshot: screen.snapshot)

        #expect(projected.lineStrings == ["ABCD"])
        #expect(projected.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func c0ControlInsideCSIPreservesPredictionParserStateLikeOfficialOverlay() throws {
        let dimensions = try MoshTerminalDimensions(columns: 4, rows: 1)
        var screen = MoshTerminalScreen(dimensions: dimensions)
        var prediction = MoshTerminalPredictionEngine(
            configuration: MoshPredictionConfiguration(displayPreference: .experimental)
        )

        try screen.apply(MoshTerminalOutput(bytes: Array("ABCD\u{1b}[1;2H".utf8)))
        prediction.registerUserInput(
            [0x1b, UInt8(ascii: "["), 0x07, UInt8(ascii: "C")],
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 0
        )

        let projected = prediction.projectedSnapshot(baseSnapshot: screen.snapshot)

        #expect(projected.lineStrings == ["ABCD"])
        #expect(projected.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func c0ControlInsideEscapePreservesPredictionParserStateLikeOfficialOverlay() throws {
        let dimensions = try MoshTerminalDimensions(columns: 4, rows: 1)
        var screen = MoshTerminalScreen(dimensions: dimensions)
        var prediction = MoshTerminalPredictionEngine(
            configuration: MoshPredictionConfiguration(displayPreference: .experimental)
        )

        try screen.apply(MoshTerminalOutput(bytes: Array("ABCD\u{1b}[1;2H".utf8)))
        prediction.registerUserInput(
            [0x1b, 0x07, UInt8(ascii: "["), UInt8(ascii: "C")],
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 0
        )

        let projected = prediction.projectedSnapshot(baseSnapshot: screen.snapshot)

        #expect(projected.lineStrings == ["ABCD"])
        #expect(projected.cursor == MoshTerminalCursor(row: 0, column: 2))
    }

    @Test
    func c0ControlInsideSS3CursorSequencePreservesPredictionParserStateLikeOfficialOverlay() throws {
        let dimensions = try MoshTerminalDimensions(columns: 4, rows: 1)
        var screen = MoshTerminalScreen(dimensions: dimensions)
        var prediction = MoshTerminalPredictionEngine(
            configuration: MoshPredictionConfiguration(displayPreference: .experimental)
        )

        try screen.apply(MoshTerminalOutput(bytes: Array("ABCD\u{1b}[1;2H".utf8)))
        prediction.registerUserInput(
            [0x1b, UInt8(ascii: "O"), 0x07, UInt8(ascii: "C")],
            baseSnapshot: screen.snapshot,
            nowMilliseconds: 0
        )

        let projected = prediction.projectedSnapshot(baseSnapshot: screen.snapshot)

        #expect(projected.lineStrings == ["ABCD"])
        #expect(projected.cursor == MoshTerminalCursor(row: 0, column: 2))
    }
}
