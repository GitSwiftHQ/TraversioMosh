// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public enum MoshPredictionDisplayPreference: Equatable, Sendable {
    case always
    case never
    case adaptive
    case experimental
}

public struct MoshPredictionConfiguration: Equatable, Sendable {
    public var displayPreference: MoshPredictionDisplayPreference
    public var predictsOverwrite: Bool

    public init(
        displayPreference: MoshPredictionDisplayPreference = .adaptive,
        predictsOverwrite: Bool = false
    ) {
        self.displayPreference = displayPreference
        self.predictsOverwrite = predictsOverwrite
    }
}

struct MoshTerminalPredictionEngine: Sendable {
    private enum ParserState: Equatable, Sendable {
        case ground
        case escape
        case escapeIntermediate
        case controlSequence(CSIParserState)
        case ss3
        case stringControl(terminatesOnBell: Bool)
    }

    private enum CSIParserState: Equatable, Sendable {
        case entry
        case parameter
        case intermediate
        case ignore
    }

    private static let bulkInputByteThreshold = 100
    private static let sendIntervalDisplayTriggerHighMilliseconds: UInt64 = 30
    private static let sendIntervalDisplayTriggerLowMilliseconds: UInt64 = 20
    private static let underlineTriggerHighMilliseconds: UInt64 = 80
    private static let underlineTriggerLowMilliseconds: UInt64 = 50
    private static let glitchThresholdMilliseconds: UInt64 = 250
    private static let glitchRepairCount = 10
    private static let glitchRepairMinimumIntervalMilliseconds: UInt64 = 150
    private static let glitchUnderlineThresholdMilliseconds: UInt64 = 5_000

    private var configuration: MoshPredictionConfiguration
    private var inputParser: MoshTerminalInputParser
    private var parserState: ParserState
    private var overlayRows: [Int: PredictedRow]
    private var cursorPredictions: [PredictedCursor]
    private var localFrameSent: UInt64
    private var localFrameAcknowledged: UInt64
    private var localFrameLateAcknowledged: UInt64
    private var sendIntervalMilliseconds: UInt64
    private var predictionEpoch: UInt64
    private var confirmedEpoch: UInt64
    private var sendIntervalTrigger: Bool
    private var underlinePredictions: Bool
    private var glitchTrigger: Int
    private var lastQuickConfirmationMilliseconds: UInt64
    private var lastDimensions: MoshTerminalDimensions?

    init(configuration: MoshPredictionConfiguration) {
        self.configuration = configuration
        self.inputParser = MoshTerminalInputParser()
        self.parserState = .ground
        self.overlayRows = [:]
        self.cursorPredictions = []
        self.localFrameSent = 0
        self.localFrameAcknowledged = 0
        self.localFrameLateAcknowledged = 0
        self.sendIntervalMilliseconds = 250
        self.predictionEpoch = 1
        self.confirmedEpoch = 0
        self.sendIntervalTrigger = false
        self.underlinePredictions = false
        self.glitchTrigger = 0
        self.lastQuickConfirmationMilliseconds = 0
        self.lastDimensions = nil
    }

    mutating func setLocalFrameSent(_ number: UInt64) {
        self.localFrameSent = number
    }

    mutating func setLocalFrameAcknowledged(_ number: UInt64) {
        self.localFrameAcknowledged = number
    }

    mutating func setLocalFrameLateAcknowledged(_ number: UInt64) {
        self.localFrameLateAcknowledged = number
    }

    mutating func setSendIntervalMilliseconds(_ milliseconds: UInt64) {
        self.sendIntervalMilliseconds = milliseconds
    }

    mutating func registerUserInput(
        _ bytes: [UInt8],
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        guard self.configuration.displayPreference != .never else {
            return
        }

        guard bytes.count <= Self.bulkInputByteThreshold else {
            self.reset()
            return
        }

        let tokens: [MoshTerminalInputToken]
        do {
            tokens = try self.inputParser.parse(bytes)
        } catch {
            self.reset()
            return
        }

        for token in tokens {
            self.registerUserToken(
                token,
                baseSnapshot: baseSnapshot,
                nowMilliseconds: nowMilliseconds
            )
        }
    }

    mutating func cull(baseSnapshot: MoshTerminalScreenSnapshot, nowMilliseconds: UInt64) {
        guard self.configuration.displayPreference != .never else {
            return
        }

        self.updateDisplayTriggers()
        if self.lastDimensions != baseSnapshot.dimensions {
            self.lastDimensions = baseSnapshot.dimensions
            self.reset()
            return
        }

        for rowNumber in Array(self.overlayRows.keys).sorted() {
            guard var row = self.overlayRows[rowNumber] else {
                continue
            }
            guard baseSnapshot.rows.indices.contains(rowNumber) else {
                self.overlayRows.removeValue(forKey: rowNumber)
                continue
            }

            for index in row.cells.indices {
                switch row.cells[index].validity(
                    baseSnapshot: baseSnapshot,
                    row: rowNumber,
                    lateAcknowledgedFrame: self.localFrameLateAcknowledged
                ) {
                case .inactive:
                    break
                case .pending:
                    self.notePredictionStillPending(
                        row.cells[index],
                        nowMilliseconds: nowMilliseconds
                    )
                case .correct:
                    self.notePredictionConfirmedQuickly(
                        row.cells[index],
                        nowMilliseconds: nowMilliseconds
                    )
                    row.updateReplacementAttributes(
                        from: index,
                        attributes: baseSnapshot.rows[rowNumber][index].attributes
                    )
                    if row.cells[index].tentativeUntilEpoch > self.confirmedEpoch {
                        self.confirmedEpoch = row.cells[index].tentativeUntilEpoch
                    }
                    row.cells[index].reset()
                case .correctNoCredit:
                    row.cells[index].reset()
                case .incorrectOrExpired:
                    if row.cells[index].tentative(confirmedEpoch: self.confirmedEpoch) {
                        self.killEpoch(row.cells[index].tentativeUntilEpoch, baseSnapshot: baseSnapshot)
                    } else {
                        self.reset()
                        return
                    }
                }
            }

            if row.cells.contains(where: \.active) {
                self.overlayRows[rowNumber] = row
            } else {
                self.overlayRows.removeValue(forKey: rowNumber)
            }
        }

        if let cursor = self.cursorPredictions.last {
            switch cursor.validity(
                baseSnapshot: baseSnapshot,
                lateAcknowledgedFrame: self.localFrameLateAcknowledged
            ) {
            case .inactive, .correct, .correctNoCredit:
                self.cursorPredictions.removeAll()
            case .pending:
                break
            case .incorrectOrExpired:
                if self.configuration.displayPreference == .experimental {
                    self.cursorPredictions.removeAll()
                } else {
                    self.reset()
                }
            }
        }

        self.updateDisplayTriggers()
    }

    func projectedSnapshot(baseSnapshot: MoshTerminalScreenSnapshot) -> MoshTerminalScreenSnapshot {
        guard self.shouldDisplayPredictions else {
            return baseSnapshot
        }

        var rows = baseSnapshot.rows
        for row in self.overlayRows.values {
            row.apply(
                to: &rows,
                confirmedEpoch: self.confirmedEpoch,
                underlinePredictions: self.underlinePredictions
            )
        }

        var cursor = baseSnapshot.cursor
        for prediction in self.cursorPredictions {
            prediction.apply(to: &cursor, confirmedEpoch: self.confirmedEpoch)
        }

        return MoshTerminalScreenSnapshot(
            dimensions: baseSnapshot.dimensions,
            cursor: cursor,
            isCursorVisible: baseSnapshot.isCursorVisible,
            isReverseVideoEnabled: baseSnapshot.isReverseVideoEnabled,
            isBracketedPasteEnabled: baseSnapshot.isBracketedPasteEnabled,
            mouseReportingMode: baseSnapshot.mouseReportingMode,
            isMouseFocusEventEnabled: baseSnapshot.isMouseFocusEventEnabled,
            isMouseAlternateScrollEnabled: baseSnapshot.isMouseAlternateScrollEnabled,
            mouseEncodingMode: baseSnapshot.mouseEncodingMode,
            isApplicationCursorKeysEnabled: baseSnapshot.isApplicationCursorKeysEnabled,
            bellCount: baseSnapshot.bellCount,
            titleInitialized: baseSnapshot.titleInitialized,
            iconName: baseSnapshot.iconName,
            windowTitle: baseSnapshot.windowTitle,
            clipboard: baseSnapshot.clipboard,
            currentHyperlink: baseSnapshot.currentHyperlink,
            rows: rows
        )
    }

    private var shouldDisplayPredictions: Bool {
        switch self.configuration.displayPreference {
        case .never:
            return false
        case .always, .experimental:
            return true
        case .adaptive:
            return self.sendIntervalTrigger || self.glitchTrigger > 0
        }
    }

    private var hasActivePrediction: Bool {
        self.cursorPredictions.isEmpty == false
            || self.overlayRows.values.contains { row in
                row.cells.contains(where: \.active)
            }
    }

    private mutating func updateDisplayTriggers() {
        if self.sendIntervalMilliseconds > Self.sendIntervalDisplayTriggerHighMilliseconds {
            self.sendIntervalTrigger = true
        } else if self.sendIntervalTrigger,
                  self.sendIntervalMilliseconds <= Self.sendIntervalDisplayTriggerLowMilliseconds,
                  self.hasActivePrediction == false {
            self.sendIntervalTrigger = false
        }

        if self.sendIntervalMilliseconds > Self.underlineTriggerHighMilliseconds {
            self.underlinePredictions = true
        } else if self.sendIntervalMilliseconds <= Self.underlineTriggerLowMilliseconds {
            self.underlinePredictions = false
        }

        if self.glitchTrigger > Self.glitchRepairCount {
            self.underlinePredictions = true
        }
    }

    private mutating func notePredictionConfirmedQuickly(
        _ cell: PredictedCell,
        nowMilliseconds: UInt64
    ) {
        guard self.glitchTrigger > 0,
              let predictionTimeMilliseconds = cell.predictionTimeMilliseconds,
              nowMilliseconds >= predictionTimeMilliseconds,
              nowMilliseconds - predictionTimeMilliseconds < Self.glitchThresholdMilliseconds,
              nowMilliseconds >= self.lastQuickConfirmationMilliseconds,
              nowMilliseconds - self.lastQuickConfirmationMilliseconds >= Self.glitchRepairMinimumIntervalMilliseconds else {
            return
        }

        self.glitchTrigger -= 1
        self.lastQuickConfirmationMilliseconds = nowMilliseconds
    }

    private mutating func notePredictionStillPending(
        _ cell: PredictedCell,
        nowMilliseconds: UInt64
    ) {
        guard let predictionTimeMilliseconds = cell.predictionTimeMilliseconds,
              nowMilliseconds >= predictionTimeMilliseconds else {
            return
        }

        let pendingMilliseconds = nowMilliseconds - predictionTimeMilliseconds
        if pendingMilliseconds >= Self.glitchUnderlineThresholdMilliseconds {
            self.glitchTrigger = Self.glitchRepairCount * 2
        } else if pendingMilliseconds >= Self.glitchThresholdMilliseconds,
                  self.glitchTrigger < Self.glitchRepairCount {
            self.glitchTrigger = Self.glitchRepairCount
        }
    }

    private mutating func registerUserByte(
        _ byte: UInt8,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        if self.configuration.displayPreference == .experimental {
            self.predictionEpoch = self.confirmedEpoch
        }

        self.cull(baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)

        switch self.parserState {
        case .ground:
            self.registerGroundByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
        case .escape:
            self.registerEscapeByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
        case .escapeIntermediate:
            self.registerEscapeIntermediateByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
        case .controlSequence(let state):
            self.registerControlSequenceByte(
                byte,
                state: state,
                baseSnapshot: baseSnapshot,
                nowMilliseconds: nowMilliseconds
            )
        case .ss3:
            guard byte != 0x1b else {
                self.parserState = .escape
                return
            }
            if Self.isPredictionC0Prime(byte) {
                self.registerExecuteByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
                return
            }
            if byte == 0x7f {
                return
            }
            self.parserState = .ground
            self.registerCursorControlByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
        case .stringControl(let terminatesOnBell):
            self.registerStringControlByte(
                byte,
                terminatesOnBell: terminatesOnBell,
                baseSnapshot: baseSnapshot,
                nowMilliseconds: nowMilliseconds
            )
        }
    }

    private mutating func registerUserToken(
        _ token: MoshTerminalInputToken,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        switch token {
        case .scalar(let scalar):
            self.registerUserScalar(
                scalar,
                baseSnapshot: baseSnapshot,
                nowMilliseconds: nowMilliseconds
            )
        case .control(let control):
            if case .c1(let byte) = control {
                self.registerUserC1Byte(
                    byte,
                    baseSnapshot: baseSnapshot,
                    nowMilliseconds: nowMilliseconds
                )
            } else if let byte = Self.byte(for: control) {
                self.registerUserByte(
                    byte,
                    baseSnapshot: baseSnapshot,
                    nowMilliseconds: nowMilliseconds
                )
            } else {
                self.cull(baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
                self.parserState = .ground
                self.becomeTentative()
            }
        }
    }

    private mutating func registerUserC1Byte(
        _ byte: UInt8,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        if self.configuration.displayPreference == .experimental {
            self.predictionEpoch = self.confirmedEpoch
        }

        self.cull(baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)

        switch byte {
        case 0x9b:
            self.parserState = .controlSequence(.entry)
        case 0x90, 0x98, 0x9e, 0x9f:
            self.parserState = .stringControl(terminatesOnBell: false)
        case 0x9d:
            self.parserState = .stringControl(terminatesOnBell: true)
        case 0x9c:
            self.parserState = .ground
        default:
            self.parserState = .ground
            self.becomeTentative()
        }
    }

    private mutating func registerUserScalar(
        _ scalar: Unicode.Scalar,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        if scalar.value < 0x80 {
            self.registerUserByte(
                UInt8(scalar.value),
                baseSnapshot: baseSnapshot,
                nowMilliseconds: nowMilliseconds
            )
            return
        }

        self.cull(baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)

        if case .stringControl = self.parserState {
            return
        }

        guard self.parserState == .ground,
              scalar.value >= 0x20,
              MoshTerminalCharacterWidth.width(of: scalar) == .narrow else {
            self.parserState = .ground
            self.becomeTentative()
            return
        }

        self.predictPrintableScalar(
            scalar,
            baseSnapshot: baseSnapshot,
            nowMilliseconds: nowMilliseconds
        )
    }

    private static func byte(for control: MoshTerminalControl) -> UInt8? {
        switch control {
        case .null:
            return 0x00
        case .bell:
            return 0x07
        case .backspace:
            return 0x08
        case .horizontalTab:
            return 0x09
        case .lineFeed:
            return 0x0a
        case .carriageReturn:
            return 0x0d
        case .escape:
            return 0x1b
        case .delete:
            return 0x7f
        case .c0(let byte):
            return byte
        case .c1:
            return nil
        }
    }

    private static func isPredictionC0Prime(_ byte: UInt8) -> Bool {
        byte <= 0x17 || byte == 0x19 || (0x1c...0x1f).contains(byte)
    }

    private mutating func registerExecuteByte(
        _ byte: UInt8,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        self.becomeTentative()
        if byte == 0x0d {
            self.predictCarriageReturnLineFeed(baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
        }
    }

    private mutating func registerGroundByte(
        _ byte: UInt8,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        switch byte {
        case 0x1b:
            self.parserState = .escape
        case 0x0d:
            self.becomeTentative()
            self.predictCarriageReturnLineFeed(baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
        case 0x20...0x7e:
            self.predictPrintableScalar(
                Unicode.Scalar(byte),
                baseSnapshot: baseSnapshot,
                nowMilliseconds: nowMilliseconds
            )
        case 0x7f:
            self.predictBackspace(baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
        default:
            self.becomeTentative()
            self.parserState = .ground
        }
    }

    private mutating func registerEscapeByte(
        _ byte: UInt8,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        switch byte {
        case 0x1b:
            self.parserState = .escape
        case _ where Self.isPredictionC0Prime(byte):
            self.registerExecuteByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
        case 0x7f:
            return
        case 0x20...0x2f:
            self.parserState = .escapeIntermediate
        case UInt8(ascii: "O"):
            self.parserState = .ss3
        case UInt8(ascii: "["):
            self.parserState = .controlSequence(.entry)
        case UInt8(ascii: "]"):
            self.parserState = .stringControl(terminatesOnBell: true)
        case UInt8(ascii: "P"),
             UInt8(ascii: "X"),
             UInt8(ascii: "^"),
             UInt8(ascii: "_"):
            self.parserState = .stringControl(terminatesOnBell: false)
        default:
            self.parserState = .ground
            self.becomeTentative()
        }
    }

    private mutating func registerEscapeIntermediateByte(
        _ byte: UInt8,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        switch byte {
        case 0x1b:
            self.parserState = .escape
        case _ where Self.isPredictionC0Prime(byte):
            self.registerExecuteByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
        case 0x7f, 0x20...0x2f:
            return
        case 0x30...0x7e:
            self.parserState = .ground
            self.becomeTentative()
        default:
            self.parserState = .ground
            self.becomeTentative()
        }
    }

    private mutating func registerStringControlByte(
        _ byte: UInt8,
        terminatesOnBell: Bool,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        switch byte {
        case 0x1b:
            self.parserState = .escape
        case 0x07 where terminatesOnBell:
            self.parserState = .ground
        case 0x18, 0x1a:
            self.parserState = .ground
            self.registerExecuteByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
        default:
            return
        }
    }

    private mutating func registerControlSequenceByte(
        _ byte: UInt8,
        state: CSIParserState,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        guard byte != 0x1b else {
            self.parserState = .escape
            return
        }

        if Self.isPredictionC0Prime(byte) {
            self.registerExecuteByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
            return
        }

        if byte == 0x7f {
            return
        }

        if byte == 0x18 || byte == 0x1a {
            self.parserState = .ground
            self.registerExecuteByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
            return
        }

        switch state {
        case .entry:
            switch byte {
            case 0x30...0x39, 0x3b, 0x3c...0x3f:
                self.parserState = .controlSequence(.parameter)
            case 0x3a:
                self.parserState = .controlSequence(.ignore)
            case 0x20...0x2f:
                self.parserState = .controlSequence(.intermediate)
            case 0x40...0x7e:
                self.parserState = .ground
                self.registerCursorControlByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
            default:
                self.parserState = .ground
                self.becomeTentative()
            }
        case .parameter:
            switch byte {
            case 0x30...0x39, 0x3b:
                return
            case 0x3a, 0x3c...0x3f:
                self.parserState = .controlSequence(.ignore)
            case 0x20...0x2f:
                self.parserState = .controlSequence(.intermediate)
            case 0x40...0x7e:
                self.parserState = .ground
                self.registerCursorControlByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
            default:
                self.parserState = .ground
                self.becomeTentative()
            }
        case .intermediate:
            switch byte {
            case 0x20...0x2f:
                return
            case 0x30...0x3f:
                self.parserState = .controlSequence(.ignore)
            case 0x40...0x7e:
                self.parserState = .ground
                self.registerCursorControlByte(byte, baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
            default:
                self.parserState = .ground
                self.becomeTentative()
            }
        case .ignore:
            guard (0x40...0x7e).contains(byte) else {
                return
            }
            self.parserState = .ground
        }
    }

    private mutating func registerCursorControlByte(
        _ byte: UInt8,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        switch byte {
        case UInt8(ascii: "C"):
            self.initializeCursor(baseSnapshot: baseSnapshot)
            guard var cursor = self.cursorPredictions.last else {
                return
            }
            if cursor.column < baseSnapshot.dimensions.columnCount - 1 {
                cursor.column += 1
                cursor.expire(frame: self.predictionExpirationFrame, nowMilliseconds: nowMilliseconds)
                self.cursorPredictions[self.cursorPredictions.count - 1] = cursor
            }
        case UInt8(ascii: "D"):
            self.initializeCursor(baseSnapshot: baseSnapshot)
            guard var cursor = self.cursorPredictions.last else {
                return
            }
            if cursor.column > 0 {
                cursor.column -= 1
                cursor.expire(frame: self.predictionExpirationFrame, nowMilliseconds: nowMilliseconds)
                self.cursorPredictions[self.cursorPredictions.count - 1] = cursor
            }
        default:
            self.becomeTentative()
        }
    }

    private mutating func predictPrintableScalar(
        _ scalar: Unicode.Scalar,
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        guard MoshTerminalCharacterWidth.width(of: scalar) == .narrow else {
            self.becomeTentative()
            return
        }

        self.initializeCursor(baseSnapshot: baseSnapshot)
        guard var cursor = self.cursorPredictions.last else {
            return
        }

        if cursor.column + 1 >= baseSnapshot.dimensions.columnCount {
            self.becomeTentative()
        }

        var row = self.row(for: cursor.row, columnCount: baseSnapshot.dimensions.columnCount)
        let rightmostColumn = self.configuration.predictsOverwrite
            ? cursor.column
            : baseSnapshot.dimensions.columnCount - 1

        if rightmostColumn > cursor.column {
            for column in stride(from: rightmostColumn, through: cursor.column + 1, by: -1) {
                row.preparePrediction(
                    at: column,
                    frame: self.predictionExpirationFrame,
                    epoch: self.predictionEpoch,
                    nowMilliseconds: nowMilliseconds,
                    original: self.baseCell(baseSnapshot: baseSnapshot, row: cursor.row, column: column)
                )

                if column == baseSnapshot.dimensions.columnCount - 1 {
                    row.cells[column].unknown = true
                    row.cells[column].replacement = nil
                } else {
                    let previous = self.predictedCellSource(
                        baseSnapshot: baseSnapshot,
                        row: cursor.row,
                        column: column - 1,
                        overlayRow: row
                    )
                    row.cells[column].unknown = previous.isUnknown
                    row.cells[column].replacement = previous.cell
                }
            }
        }

        var attributes = baseSnapshot.rows[cursor.row][cursor.column].attributes
        if cursor.column > 0 {
            attributes = self.predictedCell(
                baseSnapshot: baseSnapshot,
                row: cursor.row,
                column: cursor.column - 1,
                overlayRow: row
            )?.attributes ?? attributes
        }

        row.preparePrediction(
            at: cursor.column,
            frame: self.predictionExpirationFrame,
            epoch: self.predictionEpoch,
            nowMilliseconds: nowMilliseconds,
            original: self.baseCell(baseSnapshot: baseSnapshot, row: cursor.row, column: cursor.column)
        )
        row.cells[cursor.column].unknown = false
        row.cells[cursor.column].replacement = MoshTerminalCell(
            contents: String(scalar),
            attributes: attributes,
            hyperlink: nil
        )

        cursor.expire(frame: self.predictionExpirationFrame, nowMilliseconds: nowMilliseconds)
        if cursor.column < baseSnapshot.dimensions.columnCount - 1 {
            cursor.column += 1
        } else {
            self.becomeTentative()
            cursor.column = 0
            if cursor.row == baseSnapshot.dimensions.rowCount - 1 {
                self.predictBlankLastRow(baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
            } else {
                cursor.row += 1
            }
        }

        self.overlayRows[row.rowNumber] = row
        self.cursorPredictions[self.cursorPredictions.count - 1] = cursor
    }

    private mutating func predictBackspace(
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        self.initializeCursor(baseSnapshot: baseSnapshot)
        guard var cursor = self.cursorPredictions.last, cursor.column > 0 else {
            return
        }

        cursor.column -= 1
        cursor.expire(frame: self.predictionExpirationFrame, nowMilliseconds: nowMilliseconds)

        var row = self.row(for: cursor.row, columnCount: baseSnapshot.dimensions.columnCount)
        if self.configuration.predictsOverwrite {
            row.preparePrediction(
                at: cursor.column,
                frame: self.predictionExpirationFrame,
                epoch: self.predictionEpoch,
                nowMilliseconds: nowMilliseconds,
                original: self.baseCell(baseSnapshot: baseSnapshot, row: cursor.row, column: cursor.column)
            )
            row.cells[cursor.column].unknown = false
            row.cells[cursor.column].replacement = .blank(
                attributes: baseSnapshot.rows[cursor.row][cursor.column].attributes
            )
        } else {
            for column in cursor.column..<baseSnapshot.dimensions.columnCount {
                row.preparePrediction(
                    at: column,
                    frame: self.predictionExpirationFrame,
                    epoch: self.predictionEpoch,
                    nowMilliseconds: nowMilliseconds,
                    original: self.baseCell(baseSnapshot: baseSnapshot, row: cursor.row, column: column)
                )

                if column + 2 < baseSnapshot.dimensions.columnCount {
                    let next = self.predictedCellSource(
                        baseSnapshot: baseSnapshot,
                        row: cursor.row,
                        column: column + 1,
                        overlayRow: row
                    )
                    row.cells[column].unknown = next.isUnknown
                    row.cells[column].replacement = next.cell
                } else {
                    row.cells[column].unknown = true
                    row.cells[column].replacement = nil
                }
            }
        }

        self.overlayRows[row.rowNumber] = row
        self.cursorPredictions[self.cursorPredictions.count - 1] = cursor
    }

    private mutating func predictCarriageReturnLineFeed(
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        self.initializeCursor(baseSnapshot: baseSnapshot)
        guard var cursor = self.cursorPredictions.last else {
            return
        }

        cursor.column = 0
        if cursor.row == baseSnapshot.dimensions.rowCount - 1 {
            self.predictBlankLastRow(baseSnapshot: baseSnapshot, nowMilliseconds: nowMilliseconds)
        } else {
            cursor.row += 1
        }
        cursor.expire(frame: self.predictionExpirationFrame, nowMilliseconds: nowMilliseconds)
        self.cursorPredictions[self.cursorPredictions.count - 1] = cursor
    }

    private mutating func predictBlankLastRow(
        baseSnapshot: MoshTerminalScreenSnapshot,
        nowMilliseconds: UInt64
    ) {
        let rowNumber = baseSnapshot.dimensions.rowCount - 1
        var row = self.row(for: rowNumber, columnCount: baseSnapshot.dimensions.columnCount)
        for column in 0..<baseSnapshot.dimensions.columnCount {
            row.prepareBlankPredictionClearingReplacement(
                at: column,
                frame: self.predictionExpirationFrame,
                epoch: self.predictionEpoch,
                nowMilliseconds: nowMilliseconds
            )
        }
        self.overlayRows[rowNumber] = row
    }

    private mutating func initializeCursor(baseSnapshot: MoshTerminalScreenSnapshot) {
        if self.cursorPredictions.isEmpty {
            self.cursorPredictions.append(PredictedCursor(
                expirationFrame: self.predictionExpirationFrame,
                row: baseSnapshot.cursor.row,
                column: baseSnapshot.cursor.column,
                active: true,
                tentativeUntilEpoch: self.predictionEpoch,
                predictionTimeMilliseconds: nil
            ))
            return
        }

        guard let cursor = self.cursorPredictions.last,
              cursor.tentativeUntilEpoch != self.predictionEpoch else {
            return
        }

        self.cursorPredictions.append(PredictedCursor(
            expirationFrame: self.predictionExpirationFrame,
            row: cursor.row,
            column: cursor.column,
            active: true,
            tentativeUntilEpoch: self.predictionEpoch,
            predictionTimeMilliseconds: nil
        ))
    }

    private var predictionExpirationFrame: UInt64 {
        self.localFrameSent == UInt64.max ? UInt64.max : self.localFrameSent + 1
    }

    private mutating func becomeTentative() {
        guard self.configuration.displayPreference != .experimental else {
            return
        }
        self.predictionEpoch &+= 1
    }

    private mutating func killEpoch(_ epoch: UInt64, baseSnapshot: MoshTerminalScreenSnapshot) {
        self.cursorPredictions.removeAll { prediction in
            prediction.tentativeUntilEpoch >= epoch
        }
        self.cursorPredictions.append(PredictedCursor(
            expirationFrame: self.predictionExpirationFrame,
            row: baseSnapshot.cursor.row,
            column: baseSnapshot.cursor.column,
            active: true,
            tentativeUntilEpoch: self.predictionEpoch,
            predictionTimeMilliseconds: nil
        ))

        for rowNumber in Array(self.overlayRows.keys) {
            guard var row = self.overlayRows[rowNumber] else {
                continue
            }
            for index in row.cells.indices where row.cells[index].tentativeUntilEpoch >= epoch {
                row.cells[index].reset()
            }
            self.overlayRows[rowNumber] = row
        }
        self.becomeTentative()
    }

    private mutating func reset() {
        self.overlayRows.removeAll(keepingCapacity: true)
        self.cursorPredictions.removeAll(keepingCapacity: true)
        self.inputParser = MoshTerminalInputParser()
        self.parserState = .ground
        self.becomeTentative()
    }

    private func row(for rowNumber: Int, columnCount: Int) -> PredictedRow {
        if let row = self.overlayRows[rowNumber], row.cells.count == columnCount {
            return row
        }
        return PredictedRow(rowNumber: rowNumber, columnCount: columnCount)
    }

    private func baseCell(
        baseSnapshot: MoshTerminalScreenSnapshot,
        row: Int,
        column: Int
    ) -> MoshTerminalCell {
        baseSnapshot.rows[row][column]
    }

    private func predictedCell(
        baseSnapshot: MoshTerminalScreenSnapshot,
        row rowNumber: Int,
        column: Int,
        overlayRow: PredictedRow
    ) -> MoshTerminalCell? {
        guard baseSnapshot.rows.indices.contains(rowNumber),
              baseSnapshot.rows[rowNumber].indices.contains(column),
              overlayRow.cells.indices.contains(column) else {
            return nil
        }

        let predicted = overlayRow.cells[column]
        if predicted.active, predicted.unknown == false, let replacement = predicted.replacement {
            return replacement
        }
        return baseSnapshot.rows[rowNumber][column]
    }

    private func predictedCellSource(
        baseSnapshot: MoshTerminalScreenSnapshot,
        row rowNumber: Int,
        column: Int,
        overlayRow: PredictedRow
    ) -> (cell: MoshTerminalCell?, isUnknown: Bool) {
        guard baseSnapshot.rows.indices.contains(rowNumber),
              baseSnapshot.rows[rowNumber].indices.contains(column),
              overlayRow.cells.indices.contains(column) else {
            return (nil, true)
        }

        let predicted = overlayRow.cells[column]
        if predicted.active {
            if predicted.unknown {
                return (nil, true)
            }
            guard let replacement = predicted.replacement else {
                return (nil, true)
            }
            return (replacement, false)
        }

        return (baseSnapshot.rows[rowNumber][column], false)
    }
}

private struct PredictedRow: Equatable, Sendable {
    var rowNumber: Int
    var cells: [PredictedCell]

    init(rowNumber: Int, columnCount: Int) {
        self.rowNumber = rowNumber
        self.cells = (0..<columnCount).map { column in
            PredictedCell(column: column)
        }
    }

    mutating func preparePrediction(
        at column: Int,
        frame: UInt64,
        epoch: UInt64,
        nowMilliseconds: UInt64,
        original: MoshTerminalCell
    ) {
        guard self.cells.indices.contains(column) else {
            return
        }

        self.cells[column].resetKeepingReplacementAsOriginal()
        self.cells[column].active = true
        self.cells[column].tentativeUntilEpoch = epoch
        self.cells[column].expire(frame: frame, nowMilliseconds: nowMilliseconds)
        self.cells[column].originalContents.append(original)
    }

    mutating func prepareBlankPredictionClearingReplacement(
        at column: Int,
        frame: UInt64,
        epoch: UInt64,
        nowMilliseconds: UInt64
    ) {
        guard self.cells.indices.contains(column) else {
            return
        }

        let replacement = self.cells[column].replacement ?? .blank
        self.cells[column].active = true
        self.cells[column].tentativeUntilEpoch = epoch
        self.cells[column].expire(frame: frame, nowMilliseconds: nowMilliseconds)
        self.cells[column].replacement = .blank(
            attributes: replacement.attributes,
            hyperlink: replacement.hyperlink
        )
    }

    func apply(
        to rows: inout [[MoshTerminalCell]],
        confirmedEpoch: UInt64,
        underlinePredictions: Bool
    ) {
        guard rows.indices.contains(self.rowNumber) else {
            return
        }

        for cell in self.cells {
            cell.apply(
                to: &rows[self.rowNumber],
                confirmedEpoch: confirmedEpoch,
                underlinePredictions: underlinePredictions
            )
        }
    }

    mutating func updateReplacementAttributes(
        from startIndex: Int,
        attributes: MoshTerminalTextAttributes
    ) {
        guard self.cells.indices.contains(startIndex) else {
            return
        }

        for index in startIndex..<self.cells.count {
            guard self.cells[index].active,
                  self.cells[index].unknown == false,
                  let replacement = self.cells[index].replacement else {
                continue
            }

            self.cells[index].replacement = MoshTerminalCell(
                contents: replacement.contents,
                attributes: attributes,
                hyperlink: replacement.hyperlink
            )
        }
    }
}

private struct PredictedCell: Equatable, Sendable {
    var expirationFrame: UInt64
    var column: Int
    var active: Bool
    var tentativeUntilEpoch: UInt64
    var predictionTimeMilliseconds: UInt64?
    var replacement: MoshTerminalCell?
    var unknown: Bool
    var originalContents: [MoshTerminalCell]

    init(column: Int) {
        self.expirationFrame = 0
        self.column = column
        self.active = false
        self.tentativeUntilEpoch = 0
        self.predictionTimeMilliseconds = nil
        self.replacement = nil
        self.unknown = false
        self.originalContents = []
    }

    mutating func reset() {
        self.expirationFrame = 0
        self.active = false
        self.tentativeUntilEpoch = 0
        self.predictionTimeMilliseconds = nil
        self.replacement = nil
        self.unknown = false
        self.originalContents.removeAll(keepingCapacity: true)
    }

    mutating func resetKeepingReplacementAsOriginal() {
        guard self.active, self.unknown == false, let replacement else {
            self.reset()
            return
        }

        self.expirationFrame = 0
        self.active = false
        self.tentativeUntilEpoch = 0
        self.predictionTimeMilliseconds = nil
        self.replacement = nil
        self.unknown = false
        self.originalContents.append(replacement)
    }

    mutating func expire(frame: UInt64, nowMilliseconds: UInt64) {
        self.expirationFrame = frame
        self.predictionTimeMilliseconds = nowMilliseconds
    }

    func tentative(confirmedEpoch: UInt64) -> Bool {
        self.tentativeUntilEpoch > confirmedEpoch
    }

    func apply(
        to row: inout [MoshTerminalCell],
        confirmedEpoch: UInt64,
        underlinePredictions: Bool
    ) {
        guard self.active,
              self.tentative(confirmedEpoch: confirmedEpoch) == false,
              row.indices.contains(self.column) else {
            return
        }

        if self.unknown {
            if underlinePredictions, self.column != row.count - 1 {
                row[self.column] = row[self.column].underlinedForPrediction()
            }
            return
        }

        guard let replacement else {
            return
        }

        let shouldUnderline = underlinePredictions
            && (replacement.isPredictionBlank == false || row[self.column].isPredictionBlank == false)
        row[self.column] = shouldUnderline
            ? replacement.underlinedForPrediction()
            : replacement
    }

    func validity(
        baseSnapshot: MoshTerminalScreenSnapshot,
        row: Int,
        lateAcknowledgedFrame: UInt64
    ) -> PredictionValidity {
        guard self.active else {
            return .inactive
        }
        guard baseSnapshot.rows.indices.contains(row),
              baseSnapshot.rows[row].indices.contains(self.column) else {
            return .incorrectOrExpired
        }
        guard lateAcknowledgedFrame >= self.expirationFrame else {
            return .pending
        }
        guard self.unknown == false, let replacement else {
            return .correctNoCredit
        }
        guard replacement.isPredictionBlank == false else {
            return .correctNoCredit
        }

        let current = baseSnapshot.rows[row][self.column]
        guard current.contents == replacement.contents else {
            return .incorrectOrExpired
        }
        if self.originalContents.contains(where: { $0.contents == replacement.contents }) {
            return .correctNoCredit
        }
        return .correct
    }
}

private struct PredictedCursor: Equatable, Sendable {
    var expirationFrame: UInt64
    var row: Int
    var column: Int
    var active: Bool
    var tentativeUntilEpoch: UInt64
    var predictionTimeMilliseconds: UInt64?

    func tentative(confirmedEpoch: UInt64) -> Bool {
        self.tentativeUntilEpoch > confirmedEpoch
    }

    mutating func expire(frame: UInt64, nowMilliseconds: UInt64) {
        self.expirationFrame = frame
        self.predictionTimeMilliseconds = nowMilliseconds
    }

    func apply(to cursor: inout MoshTerminalCursor, confirmedEpoch: UInt64) {
        guard self.active,
              self.tentative(confirmedEpoch: confirmedEpoch) == false else {
            return
        }
        cursor = MoshTerminalCursor(row: self.row, column: self.column)
    }

    func validity(
        baseSnapshot: MoshTerminalScreenSnapshot,
        lateAcknowledgedFrame: UInt64
    ) -> PredictionValidity {
        guard self.active else {
            return .inactive
        }
        guard self.row >= 0,
              self.row < baseSnapshot.dimensions.rowCount,
              self.column >= 0,
              self.column < baseSnapshot.dimensions.columnCount else {
            return .incorrectOrExpired
        }
        guard lateAcknowledgedFrame >= self.expirationFrame else {
            return .pending
        }
        return baseSnapshot.cursor == MoshTerminalCursor(row: self.row, column: self.column)
            ? .correct
            : .incorrectOrExpired
    }
}

private enum PredictionValidity: Equatable, Sendable {
    case inactive
    case pending
    case correct
    case correctNoCredit
    case incorrectOrExpired
}

private extension MoshTerminalDimensions {
    var columnCount: Int {
        Int(self.columns)
    }

    var rowCount: Int {
        Int(self.rows)
    }
}

private extension MoshTerminalCell {
    var isPredictionBlank: Bool {
        self.contents.isEmpty || self.contents == " " || self.contents == "\u{00a0}"
    }

    func underlinedForPrediction() -> MoshTerminalCell {
        var attributes = self.attributes
        attributes.isUnderlined = true
        return MoshTerminalCell(
            contents: self.contents,
            attributes: attributes,
            hyperlink: self.hyperlink
        )
    }
}
