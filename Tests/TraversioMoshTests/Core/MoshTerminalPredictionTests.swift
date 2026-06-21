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
}
