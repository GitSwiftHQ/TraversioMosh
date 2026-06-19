// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public struct MoshTerminalCursor: Equatable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

public struct MoshTerminalCell: Equatable, Sendable {
    public static let blank = MoshTerminalCell(contents: " ")

    public let contents: String
    public let attributes: MoshTerminalTextAttributes
    public let displayWidth: Int
    public let isContinuation: Bool

    public init(
        contents: String,
        attributes: MoshTerminalTextAttributes = .default
    ) {
        self.contents = contents
        self.attributes = attributes
        self.displayWidth = 1
        self.isContinuation = false
    }

    init(
        scalar: Unicode.Scalar,
        attributes: MoshTerminalTextAttributes,
        displayWidth: Int
    ) {
        self.contents = String(scalar)
        self.attributes = attributes
        self.displayWidth = displayWidth
        self.isContinuation = false
    }

    private init(
        contents: String,
        attributes: MoshTerminalTextAttributes,
        displayWidth: Int,
        isContinuation: Bool
    ) {
        self.contents = contents
        self.attributes = attributes
        self.displayWidth = displayWidth
        self.isContinuation = isContinuation
    }

    static func continuation(attributes: MoshTerminalTextAttributes) -> MoshTerminalCell {
        MoshTerminalCell(
            contents: " ",
            attributes: attributes,
            displayWidth: 0,
            isContinuation: true
        )
    }

    func appending(_ scalar: Unicode.Scalar) -> MoshTerminalCell {
        MoshTerminalCell(
            contents: self.contents + String(scalar),
            attributes: self.attributes,
            displayWidth: self.displayWidth,
            isContinuation: self.isContinuation
        )
    }
}

public struct MoshTerminalScreenSnapshot: Equatable, Sendable {
    public let dimensions: MoshTerminalDimensions
    public let cursor: MoshTerminalCursor
    public let rows: [[MoshTerminalCell]]

    public init(
        dimensions: MoshTerminalDimensions,
        cursor: MoshTerminalCursor,
        rows: [[MoshTerminalCell]]
    ) {
        self.dimensions = dimensions
        self.cursor = cursor
        self.rows = rows
    }

    public var lineStrings: [String] {
        self.rows.map { row in
            row.map(\.contents).joined()
        }
    }
}

public struct MoshTerminalScreen: Sendable {
    public private(set) var dimensions: MoshTerminalDimensions
    public private(set) var cursor: MoshTerminalCursor

    private var parser: MoshTerminalInputParser
    private var rows: [[MoshTerminalCell]]
    private var scrollRegion: MoshTerminalScrollRegion
    private var currentAttributes: MoshTerminalTextAttributes
    private var alternateBuffer: MoshTerminalScreenBuffer?
    private var normalBuffer: MoshTerminalScreenBuffer?
    private var savedCursorState: MoshTerminalSavedCursorState?
    private var escapeState: EscapeState?
    private var wrapPending: Bool
    private var tabStops: Set<Int>
    private var originMode: Bool
    private var autoWrapMode: Bool

    public init(dimensions: MoshTerminalDimensions) {
        self.dimensions = dimensions
        self.cursor = MoshTerminalCursor(row: 0, column: 0)
        self.parser = MoshTerminalInputParser()
        self.rows = Self.blankRows(dimensions: dimensions)
        self.scrollRegion = .full(rowCount: Int(dimensions.rows))
        self.currentAttributes = .default
        self.alternateBuffer = nil
        self.normalBuffer = nil
        self.savedCursorState = nil
        self.escapeState = nil
        self.wrapPending = false
        self.tabStops = Self.defaultTabStops(columnCount: Int(dimensions.columns))
        self.originMode = false
        self.autoWrapMode = true
    }

    public var snapshot: MoshTerminalScreenSnapshot {
        MoshTerminalScreenSnapshot(
            dimensions: self.dimensions,
            cursor: self.cursor,
            rows: self.rows
        )
    }

    public mutating func apply(_ operation: MoshTerminalRenderOperation) throws {
        switch operation {
        case .write(let output):
            try self.apply(output)
        case .resize(let dimensions):
            self.resize(dimensions)
        }
    }

    public mutating func apply(_ operations: [MoshTerminalRenderOperation]) throws {
        for operation in operations {
            try self.apply(operation)
        }
    }

    public mutating func apply(_ output: MoshTerminalOutput) throws {
        let tokens = try self.parser.parse(output.bytes)
        for token in tokens {
            self.apply(token)
        }
    }

    public mutating func apply(_ token: MoshTerminalInputToken) {
        if self.escapeState != nil {
            self.consumeEscapeToken(token)
            return
        }

        switch token {
        case .scalar(let scalar):
            self.place(scalar)
        case .control(let control):
            self.apply(control)
        }
    }

    public mutating func finishPendingInput() throws {
        try self.parser.finish()
    }

    public mutating func resize(_ dimensions: MoshTerminalDimensions) {
        self.dimensions = dimensions
        self.rows = Self.resizedRows(self.rows, dimensions: dimensions)
        self.cursor = Self.clampedCursor(
            self.cursor,
            maximumRow: self.maximumRow,
            maximumColumn: self.maximumColumn
        )
        self.scrollRegion = .full(rowCount: self.rows.count)
        self.wrapPending = false
        self.tabStops = self.tabStops.filter { $0 <= self.maximumColumn }
        self.alternateBuffer = self.alternateBuffer?.resized(to: dimensions)
        self.normalBuffer = self.normalBuffer?.resized(to: dimensions)
        self.savedCursorState = self.savedCursorState?.clamped(
            maximumRow: self.maximumRow,
            maximumColumn: self.maximumColumn
        )
    }

    private var maximumRow: Int {
        self.rows.count - 1
    }

    private var maximumColumn: Int {
        (self.rows.first?.count ?? 1) - 1
    }

    private mutating func apply(_ control: MoshTerminalControl) {
        switch control {
        case .null, .bell:
            break
        case .backspace:
            self.wrapPending = false
            let column = self.previousCursorColumn()
            self.cursor = MoshTerminalCursor(
                row: self.cursor.row,
                column: column
            )
        case .horizontalTab:
            self.wrapPending = false
            self.moveForwardTabStops(count: 1)
        case .lineFeed:
            self.wrapPending = false
            self.index()
        case .carriageReturn:
            self.wrapPending = false
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
        case .escape:
            self.escapeState = .escape
            self.wrapPending = false
        case .delete:
            break
        case .c0:
            break
        case .c1(let byte):
            switch byte {
            case 0x84:
                self.index()
            case 0x85:
                self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
                self.index()
            case 0x8d:
                self.reverseIndex()
            case 0x88:
                self.setTabStop()
            case 0x9b:
                self.escapeState = .csi(CSIState())
                self.wrapPending = false
            default:
                break
            }
        }
    }

    private mutating func place(_ scalar: Unicode.Scalar) {
        let scalarWidth = MoshTerminalCharacterWidth.width(of: scalar)
        if scalarWidth == .zero {
            self.appendZeroWidthScalar(scalar)
            return
        }

        if self.wrapPending {
            self.index()
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
            self.wrapPending = false
        }

        var displayWidth = min(scalarWidth.rawValue, self.maximumColumn + 1)
        if displayWidth > self.availableColumnsFromCursor {
            if self.autoWrapMode {
                self.index()
                self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
                self.wrapPending = false
            } else {
                displayWidth = self.availableColumnsFromCursor
            }
        }

        self.clearCellForWrite(row: self.cursor.row, column: self.cursor.column)
        self.rows[self.cursor.row][self.cursor.column] = MoshTerminalCell(
            scalar: scalar,
            attributes: self.currentAttributes,
            displayWidth: displayWidth
        )
        if displayWidth == 2 {
            self.clearCellForWrite(row: self.cursor.row, column: self.cursor.column + 1)
            self.rows[self.cursor.row][self.cursor.column + 1] = .continuation(
                attributes: self.currentAttributes
            )
        }

        let lastColumn = self.cursor.column + displayWidth - 1
        if lastColumn == self.maximumColumn {
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: self.maximumColumn)
            self.wrapPending = self.autoWrapMode
        } else {
            self.cursor = MoshTerminalCursor(
                row: self.cursor.row,
                column: lastColumn + 1
            )
        }
    }

    private var availableColumnsFromCursor: Int {
        self.maximumColumn - self.cursor.column + 1
    }

    private mutating func appendZeroWidthScalar(_ scalar: Unicode.Scalar) {
        let targetColumn: Int
        if self.wrapPending {
            targetColumn = self.cursor.column
        } else if self.cursor.column > 0 {
            targetColumn = self.cursor.column - 1
        } else {
            targetColumn = self.cursor.column
        }

        let column = self.leadingColumn(row: self.cursor.row, column: targetColumn)
        self.rows[self.cursor.row][column] = self.rows[self.cursor.row][column].appending(scalar)
    }

    private mutating func clearCellForWrite(row: Int, column: Int) {
        guard self.rows.indices.contains(row),
              self.rows[row].indices.contains(column) else {
            return
        }

        let leadingColumn = self.leadingColumn(row: row, column: column)
        let displayWidth = max(self.rows[row][leadingColumn].displayWidth, 1)
        for clearedColumn in leadingColumn..<min(leadingColumn + displayWidth, self.rows[row].count) {
            self.rows[row][clearedColumn] = .blank
        }
    }

    private func leadingColumn(row: Int, column: Int) -> Int {
        var leadingColumn = column
        while leadingColumn > 0, self.rows[row][leadingColumn].isContinuation {
            leadingColumn -= 1
        }
        return leadingColumn
    }

    private func previousCursorColumn() -> Int {
        let column = max(0, self.cursor.column - 1)
        return self.leadingColumn(row: self.cursor.row, column: column)
    }

    private mutating func index() {
        if self.cursor.row == self.scrollRegion.bottom {
            self.scrollUp(count: 1)
        } else if self.cursor.row < self.maximumRow {
            self.cursor = MoshTerminalCursor(
                row: self.cursor.row + 1,
                column: self.cursor.column
            )
        }
    }

    private mutating func reverseIndex() {
        if self.cursor.row == self.scrollRegion.top {
            self.scrollDown(count: 1)
        } else if self.cursor.row > 0 {
            self.cursor = MoshTerminalCursor(
                row: self.cursor.row - 1,
                column: self.cursor.column
            )
        }
        self.wrapPending = false
    }

    private mutating func scrollUp(count: Int) {
        self.scrollRowsUp(count: count, region: self.scrollRegion)
        self.wrapPending = false
    }

    private mutating func scrollDown(count: Int) {
        self.scrollRowsDown(count: count, region: self.scrollRegion)
        self.wrapPending = false
    }

    private mutating func scrollRowsUp(count: Int, region: MoshTerminalScrollRegion) {
        let amount = min(max(count, 0), region.height)
        guard amount > 0 else {
            return
        }

        let activeRows = Array(self.rows[region.range])
        let replacement = Array(activeRows.dropFirst(amount))
            + Self.blankRows(rowCount: amount, columnCount: self.maximumColumn + 1)
        self.replaceRows(in: region.range, with: replacement)
    }

    private mutating func scrollRowsDown(count: Int, region: MoshTerminalScrollRegion) {
        let amount = min(max(count, 0), region.height)
        guard amount > 0 else {
            return
        }

        let activeRows = Array(self.rows[region.range])
        let replacement = Self.blankRows(rowCount: amount, columnCount: self.maximumColumn + 1)
            + Array(activeRows.dropLast(amount))
        self.replaceRows(in: region.range, with: replacement)
    }

    private mutating func insertLines(count: Int) {
        guard self.scrollRegion.contains(row: self.cursor.row) else {
            return
        }

        let amount = min(max(count, 0), self.scrollRegion.bottom - self.cursor.row + 1)
        guard amount > 0 else {
            return
        }

        let range = self.cursor.row...self.scrollRegion.bottom
        let activeRows = Array(self.rows[range])
        let replacement = Self.blankRows(rowCount: amount, columnCount: self.maximumColumn + 1)
            + Array(activeRows.dropLast(amount))
        self.replaceRows(in: range, with: replacement)
        self.wrapPending = false
    }

    private mutating func deleteLines(count: Int) {
        guard self.scrollRegion.contains(row: self.cursor.row) else {
            return
        }

        let amount = min(max(count, 0), self.scrollRegion.bottom - self.cursor.row + 1)
        guard amount > 0 else {
            return
        }

        let range = self.cursor.row...self.scrollRegion.bottom
        let activeRows = Array(self.rows[range])
        let replacement = Array(activeRows.dropFirst(amount))
            + Self.blankRows(rowCount: amount, columnCount: self.maximumColumn + 1)
        self.replaceRows(in: range, with: replacement)
        self.wrapPending = false
    }

    private mutating func insertCharacters(count: Int) {
        let amount = min(max(count, 0), self.availableColumnsFromCursor)
        guard amount > 0 else {
            return
        }

        if self.rows[self.cursor.row][self.cursor.column].isContinuation {
            self.clearCellForWrite(row: self.cursor.row, column: self.cursor.column)
        }

        var row = self.rows[self.cursor.row]
        if self.cursor.column + amount <= self.maximumColumn {
            for column in stride(
                from: self.maximumColumn,
                through: self.cursor.column + amount,
                by: -1
            ) {
                row[column] = row[column - amount]
            }
        }
        for column in self.cursor.column..<(self.cursor.column + amount) {
            row[column] = .blank
        }
        Self.normalizeContinuations(in: &row)
        self.rows[self.cursor.row] = row
        self.wrapPending = false
    }

    private mutating func deleteCharacters(count: Int) {
        let amount = min(max(count, 0), self.availableColumnsFromCursor)
        guard amount > 0 else {
            return
        }

        self.clearCellForWrite(row: self.cursor.row, column: self.cursor.column)

        var row = self.rows[self.cursor.row]
        let tailStart = self.cursor.column + amount
        if tailStart <= self.maximumColumn {
            for column in self.cursor.column...(self.maximumColumn - amount) {
                row[column] = row[column + amount]
            }
        }
        for column in (self.maximumColumn - amount + 1)...self.maximumColumn {
            row[column] = .blank
        }
        Self.normalizeContinuations(in: &row)
        self.rows[self.cursor.row] = row
        self.wrapPending = false
    }

    private mutating func replaceRows(
        in range: ClosedRange<Int>,
        with replacement: [[MoshTerminalCell]]
    ) {
        for offset in replacement.indices {
            self.rows[range.lowerBound + offset] = replacement[offset]
        }
    }

    private mutating func setScrollRegion(parameters: [Int?]) {
        let top = min(
            max(Self.parameter(parameters, at: 0, default: 1) - 1, 0),
            self.maximumRow
        )
        let bottom = min(
            max(Self.parameter(parameters, at: 1, default: self.maximumRow + 1) - 1, 0),
            self.maximumRow
        )

        guard top < bottom else {
            return
        }

        self.scrollRegion = MoshTerminalScrollRegion(top: top, bottom: bottom)
        self.homeCursor()
        self.wrapPending = false
    }

    private mutating func saveCursorState() {
        self.savedCursorState = MoshTerminalSavedCursorState(
            cursor: self.cursor,
            attributes: self.currentAttributes
        )
    }

    private mutating func restoreCursorState() {
        guard let savedCursorState else {
            return
        }

        self.cursor = Self.clampedCursor(
            savedCursorState.cursor,
            maximumRow: self.maximumRow,
            maximumColumn: self.maximumColumn
        )
        self.currentAttributes = savedCursorState.attributes
        self.wrapPending = false
    }

    private mutating func setPrivateMode(_ mode: Int, enabled: Bool) {
        switch mode {
        case 6:
            self.originMode = enabled
            self.homeCursor()
        case 7:
            self.autoWrapMode = enabled
            if enabled == false {
                self.wrapPending = false
            }
        case 47, 1047:
            if enabled {
                self.activateAlternateScreen(clear: false, saveCursor: false)
            } else {
                self.restoreNormalScreen(clearAlternate: true, restoreCursor: false)
            }
        case 1048:
            if enabled {
                self.saveCursorState()
            } else {
                self.restoreCursorState()
            }
        case 1049:
            if enabled {
                self.activateAlternateScreen(clear: true, saveCursor: true)
            } else {
                self.restoreNormalScreen(clearAlternate: true, restoreCursor: true)
            }
        default:
            break
        }
    }

    private mutating func activateAlternateScreen(clear: Bool, saveCursor: Bool) {
        if saveCursor {
            self.saveCursorState()
        }

        if self.normalBuffer == nil {
            self.normalBuffer = self.activeBuffer
            let nextBuffer: MoshTerminalScreenBuffer
            if clear {
                nextBuffer = .blank(dimensions: self.dimensions)
            } else {
                nextBuffer = self.alternateBuffer ?? .blank(dimensions: self.dimensions)
            }
            self.restoreScreenBuffer(nextBuffer)
        } else {
            if clear {
                self.restoreScreenBuffer(.blank(dimensions: self.dimensions))
            }
        }
    }

    private mutating func restoreNormalScreen(
        clearAlternate: Bool,
        restoreCursor: Bool
    ) {
        if let normalBuffer {
            self.alternateBuffer = clearAlternate ? .blank(dimensions: self.dimensions) : self.activeBuffer
            self.restoreScreenBuffer(normalBuffer)
            self.normalBuffer = nil
        }

        if restoreCursor {
            self.restoreCursorState()
        }
    }

    private var activeBuffer: MoshTerminalScreenBuffer {
        MoshTerminalScreenBuffer(
            rows: self.rows,
            cursor: self.cursor,
            scrollRegion: self.scrollRegion,
            wrapPending: self.wrapPending
        )
    }

    private mutating func restoreScreenBuffer(_ buffer: MoshTerminalScreenBuffer) {
        self.rows = Self.resizedRows(buffer.rows, dimensions: self.dimensions)
        self.cursor = Self.clampedCursor(
            buffer.cursor,
            maximumRow: self.maximumRow,
            maximumColumn: self.maximumColumn
        )
        self.scrollRegion = buffer.scrollRegion.clamped(rowCount: self.rows.count)
        self.wrapPending = buffer.wrapPending
    }

    private mutating func consumeEscapeToken(_ token: MoshTerminalInputToken) {
        guard let state = self.escapeState else {
            return
        }

        switch (state, token) {
        case (.escape, .scalar("[")):
            self.escapeState = .csi(CSIState())
        case (.escape, .scalar("7")):
            self.saveCursorState()
            self.escapeState = nil
        case (.escape, .scalar("8")):
            self.restoreCursorState()
            self.escapeState = nil
        case (.escape, .scalar("H")):
            self.setTabStop()
            self.escapeState = nil
        case (.escape, .scalar("D")):
            self.index()
            self.escapeState = nil
        case (.escape, .scalar("E")):
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
            self.index()
            self.escapeState = nil
        case (.escape, .scalar("M")):
            self.reverseIndex()
            self.escapeState = nil
        case (.escape, .scalar("c")):
            self.reset()
        case (.escape, .control(.c1(0x9b))):
            self.escapeState = .csi(CSIState())
        case (.escape, _):
            self.escapeState = nil
        case (.csi(let csiState), .scalar(let scalar)):
            self.consumeCSI(scalar: scalar, state: csiState)
        case (.csi, .control(.escape)):
            self.escapeState = .escape
        case (.csi, _):
            break
        }
    }

    private mutating func consumeCSI(scalar: Unicode.Scalar, state: CSIState) {
        guard let byte = UInt8(exactly: scalar.value) else {
            self.escapeState = nil
            return
        }

        if (0x30...0x3f).contains(byte) {
            guard state.intermediates.isEmpty, state.parameters.count < 64 else {
                self.escapeState = nil
                return
            }
            var nextState = state
            nextState.parameters += String(scalar)
            self.escapeState = .csi(nextState)
            return
        }

        if (0x20...0x2f).contains(byte) {
            guard state.intermediates.count < 4 else {
                self.escapeState = nil
                return
            }
            var nextState = state
            nextState.intermediates += String(scalar)
            self.escapeState = .csi(nextState)
            return
        }

        if (0x40...0x7e).contains(byte) {
            self.executeCSI(
                finalByte: byte,
                parameters: state.parameters,
                intermediates: state.intermediates
            )
            self.escapeState = nil
            return
        }

        self.escapeState = nil
    }

    private mutating func executeCSI(finalByte: UInt8, parameters: String, intermediates: String) {
        guard intermediates.isEmpty else {
            return
        }

        let values = Self.parseCSIParameters(parameters)
        let isPrivate = parameters.first == "?"

        switch finalByte {
        case UInt8(ascii: "@"):
            self.insertCharacters(count: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "A"):
            self.moveCursor(rowDelta: -Self.parameter(values, at: 0, default: 1), columnDelta: 0)
        case UInt8(ascii: "B"):
            self.moveCursor(rowDelta: Self.parameter(values, at: 0, default: 1), columnDelta: 0)
        case UInt8(ascii: "C"):
            self.moveCursor(rowDelta: 0, columnDelta: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "D"):
            self.moveCursor(rowDelta: 0, columnDelta: -Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "E"):
            self.moveCursor(rowDelta: Self.parameter(values, at: 0, default: 1), columnDelta: 0)
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
        case UInt8(ascii: "F"):
            self.moveCursor(rowDelta: -Self.parameter(values, at: 0, default: 1), columnDelta: 0)
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
        case UInt8(ascii: "G"):
            self.setCursor(
                row: self.cursor.row,
                column: Self.parameter(values, at: 0, default: 1) - 1
            )
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            self.setPositionedCursor(
                row: Self.parameter(values, at: 0, default: 1) - 1,
                column: Self.parameter(values, at: 1, default: 1) - 1
            )
        case UInt8(ascii: "I"):
            self.moveForwardTabStops(count: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "J"):
            self.eraseScreen(mode: Self.parameter(values, at: 0, default: 0))
        case UInt8(ascii: "K"):
            self.eraseLine(mode: Self.parameter(values, at: 0, default: 0))
        case UInt8(ascii: "L"):
            self.insertLines(count: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "M"):
            self.deleteLines(count: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "P"):
            self.deleteCharacters(count: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "S"):
            self.scrollUp(count: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "T"):
            self.scrollDown(count: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "X"):
            self.eraseCharacters(count: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "Z"):
            self.moveBackwardTabStops(count: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "`"):
            self.setCursor(
                row: self.cursor.row,
                column: Self.parameter(values, at: 0, default: 1) - 1
            )
        case UInt8(ascii: "a"):
            self.moveCursor(rowDelta: 0, columnDelta: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "d"):
            self.setPositionedCursor(
                row: Self.parameter(values, at: 0, default: 1) - 1,
                column: self.cursor.column
            )
        case UInt8(ascii: "e"):
            self.moveCursor(rowDelta: Self.parameter(values, at: 0, default: 1), columnDelta: 0)
        case UInt8(ascii: "g"):
            self.clearTabStops(mode: Self.parameter(values, at: 0, default: 0))
        case UInt8(ascii: "h"):
            if isPrivate {
                values.compactMap { $0 }.forEach { self.setPrivateMode($0, enabled: true) }
            }
        case UInt8(ascii: "l"):
            if isPrivate {
                values.compactMap { $0 }.forEach { self.setPrivateMode($0, enabled: false) }
            }
        case UInt8(ascii: "m"):
            self.applySGR(parameters: values)
        case UInt8(ascii: "r"):
            self.setScrollRegion(parameters: values)
        default:
            break
        }
    }

    private mutating func reset() {
        self.rows = Self.blankRows(dimensions: self.dimensions)
        self.cursor = MoshTerminalCursor(row: 0, column: 0)
        self.scrollRegion = .full(rowCount: self.rows.count)
        self.currentAttributes = .default
        self.alternateBuffer = nil
        self.normalBuffer = nil
        self.savedCursorState = nil
        self.escapeState = nil
        self.wrapPending = false
        self.tabStops = Self.defaultTabStops(columnCount: Int(self.dimensions.columns))
        self.originMode = false
        self.autoWrapMode = true
    }

    private mutating func moveCursor(rowDelta: Int, columnDelta: Int) {
        let rowBounds = self.relativeCursorRowBounds
        self.cursor = MoshTerminalCursor(
            row: min(max(self.cursor.row + rowDelta, rowBounds.lowerBound), rowBounds.upperBound),
            column: min(max(self.cursor.column + columnDelta, 0), self.maximumColumn)
        )
        self.wrapPending = false
    }

    private mutating func setCursor(row: Int, column: Int) {
        self.cursor = MoshTerminalCursor(
            row: min(max(row, 0), self.maximumRow),
            column: min(max(column, 0), self.maximumColumn)
        )
        self.wrapPending = false
    }

    private mutating func setPositionedCursor(row: Int, column: Int) {
        let rowBounds = self.absoluteCursorRowBounds
        let absoluteRow = self.originMode ? self.scrollRegion.top + row : row
        self.cursor = MoshTerminalCursor(
            row: min(max(absoluteRow, rowBounds.lowerBound), rowBounds.upperBound),
            column: min(max(column, 0), self.maximumColumn)
        )
        self.wrapPending = false
    }

    private mutating func homeCursor() {
        self.cursor = MoshTerminalCursor(
            row: self.originMode ? self.scrollRegion.top : 0,
            column: 0
        )
        self.wrapPending = false
    }

    private var absoluteCursorRowBounds: ClosedRange<Int> {
        if self.originMode {
            return self.scrollRegion.range
        }
        return 0...self.maximumRow
    }

    private var relativeCursorRowBounds: ClosedRange<Int> {
        if self.scrollRegion.contains(row: self.cursor.row) {
            return self.scrollRegion.range
        }
        return 0...self.maximumRow
    }

    private mutating func moveForwardTabStops(count: Int) {
        let amount = max(count, 0)
        guard amount > 0 else {
            return
        }

        var column = self.cursor.column
        for _ in 0..<amount {
            let nextColumn = self.nextTabStop(after: column)
            guard nextColumn != column else {
                break
            }
            column = nextColumn
        }
        self.setCursor(row: self.cursor.row, column: column)
    }

    private mutating func moveBackwardTabStops(count: Int) {
        let amount = max(count, 0)
        guard amount > 0 else {
            return
        }

        var column = self.cursor.column
        for _ in 0..<amount {
            let previousColumn = self.previousTabStop(before: column)
            guard previousColumn != column else {
                break
            }
            column = previousColumn
        }
        self.setCursor(row: self.cursor.row, column: column)
    }

    private func nextTabStop(after column: Int) -> Int {
        self.tabStops.filter { $0 > column }.min() ?? self.maximumColumn
    }

    private func previousTabStop(before column: Int) -> Int {
        self.tabStops.filter { $0 < column }.max() ?? 0
    }

    private mutating func setTabStop() {
        self.tabStops.insert(self.cursor.column)
        self.wrapPending = false
    }

    private mutating func clearTabStops(mode: Int) {
        switch mode {
        case 0:
            self.tabStops.remove(self.cursor.column)
        case 3:
            self.tabStops.removeAll()
        default:
            break
        }
        self.wrapPending = false
    }

    private mutating func eraseScreen(mode: Int) {
        switch mode {
        case 0:
            for row in self.cursor.row...self.maximumRow {
                let startColumn = row == self.cursor.row ? self.cursor.column : 0
                self.blankCells(row: row, columns: startColumn...self.maximumColumn)
            }
        case 1:
            for row in 0...self.cursor.row {
                let endColumn = row == self.cursor.row ? self.cursor.column : self.maximumColumn
                self.blankCells(row: row, columns: 0...endColumn)
            }
        case 2, 3:
            self.rows = Self.blankRows(dimensions: self.dimensions)
        default:
            break
        }
        self.wrapPending = false
    }

    private mutating func eraseLine(mode: Int) {
        switch mode {
        case 0:
            self.blankCells(row: self.cursor.row, columns: self.cursor.column...self.maximumColumn)
        case 1:
            self.blankCells(row: self.cursor.row, columns: 0...self.cursor.column)
        case 2:
            self.blankCells(row: self.cursor.row, columns: 0...self.maximumColumn)
        default:
            break
        }
        self.wrapPending = false
    }

    private mutating func eraseCharacters(count: Int) {
        let amount = min(max(count, 0), self.availableColumnsFromCursor)
        guard amount > 0 else {
            return
        }

        self.blankCells(
            row: self.cursor.row,
            columns: self.cursor.column...(self.cursor.column + amount - 1)
        )
        self.wrapPending = false
    }

    private mutating func blankCells(row: Int, columns: ClosedRange<Int>) {
        for column in columns {
            self.clearCellForWrite(row: row, column: column)
        }
    }

    private mutating func applySGR(parameters: [Int?]) {
        let values = parameters.isEmpty ? [0] : parameters.map { $0 ?? 0 }
        var index = 0

        while index < values.count {
            let value = values[index]

            switch value {
            case 0:
                self.currentAttributes = .default
            case 1:
                self.currentAttributes.intensity = .bold
            case 2:
                self.currentAttributes.intensity = .faint
            case 22:
                self.currentAttributes.intensity = .normal
            case 3:
                self.currentAttributes.isItalic = true
            case 23:
                self.currentAttributes.isItalic = false
            case 4:
                self.currentAttributes.isUnderlined = true
            case 24:
                self.currentAttributes.isUnderlined = false
            case 7:
                self.currentAttributes.isInverse = true
            case 27:
                self.currentAttributes.isInverse = false
            case 30...37:
                self.currentAttributes.foregroundColor = Self.ansiColor(
                    code: value - 30,
                    isBright: false
                )
            case 39:
                self.currentAttributes.foregroundColor = nil
            case 40...47:
                self.currentAttributes.backgroundColor = Self.ansiColor(
                    code: value - 40,
                    isBright: false
                )
            case 49:
                self.currentAttributes.backgroundColor = nil
            case 90...97:
                self.currentAttributes.foregroundColor = Self.ansiColor(
                    code: value - 90,
                    isBright: true
                )
            case 100...107:
                self.currentAttributes.backgroundColor = Self.ansiColor(
                    code: value - 100,
                    isBright: true
                )
            case 38:
                if let result = Self.extendedColor(values: values, startIndex: index + 1) {
                    self.currentAttributes.foregroundColor = result.color
                    index = result.nextIndex
                    continue
                }
            case 48:
                if let result = Self.extendedColor(values: values, startIndex: index + 1) {
                    self.currentAttributes.backgroundColor = result.color
                    index = result.nextIndex
                    continue
                }
            default:
                break
            }

            index += 1
        }
    }

    private static func ansiColor(code: Int, isBright: Bool) -> MoshTerminalColor? {
        guard let color = MoshTerminalANSIColor(rawValue: code) else {
            return nil
        }
        return .ansi(color, isBright: isBright)
    }

    private static func extendedColor(
        values: [Int],
        startIndex: Int
    ) -> (color: MoshTerminalColor, nextIndex: Int)? {
        guard startIndex < values.count else {
            return nil
        }

        switch values[startIndex] {
        case 5:
            guard startIndex + 1 < values.count,
                  let index = UInt8(exactly: values[startIndex + 1]) else {
                return nil
            }
            return (.indexed(index), startIndex + 2)
        case 2:
            guard startIndex + 3 < values.count,
                  let red = UInt8(exactly: values[startIndex + 1]),
                  let green = UInt8(exactly: values[startIndex + 2]),
                  let blue = UInt8(exactly: values[startIndex + 3]) else {
                return nil
            }
            return (.rgb(red: red, green: green, blue: blue), startIndex + 4)
        default:
            return nil
        }
    }

    private static func parseCSIParameters(_ parameters: String) -> [Int?] {
        let normalized = parameters.first == "?" ? parameters.dropFirst() : Substring(parameters)
        return normalized.split(separator: ";", omittingEmptySubsequences: false).map { field in
            field.isEmpty ? nil : Int(field)
        }
    }

    private static func parameter(_ parameters: [Int?], at index: Int, default defaultValue: Int) -> Int {
        guard index < parameters.count, let value = parameters[index], value > 0 else {
            return defaultValue
        }
        return value
    }

    fileprivate static func blankRows(dimensions: MoshTerminalDimensions) -> [[MoshTerminalCell]] {
        self.blankRows(rowCount: Int(dimensions.rows), columnCount: Int(dimensions.columns))
    }

    fileprivate static func blankRows(rowCount: Int, columnCount: Int) -> [[MoshTerminalCell]] {
        return (0..<rowCount).map { _ in
            self.blankRow(columnCount: columnCount)
        }
    }

    fileprivate static func blankRow(columnCount: Int) -> [MoshTerminalCell] {
        Array(repeating: .blank, count: columnCount)
    }

    private static func defaultTabStops(columnCount: Int) -> Set<Int> {
        guard columnCount > 0 else {
            return []
        }
        return Set(stride(from: 8, to: columnCount, by: 8))
    }

    fileprivate static func resizedRows(
        _ oldRows: [[MoshTerminalCell]],
        dimensions: MoshTerminalDimensions
    ) -> [[MoshTerminalCell]] {
        var newRows = Self.blankRows(dimensions: dimensions)
        let copiedRows = min(oldRows.count, newRows.count)
        let copiedColumns = min(oldRows.first?.count ?? 0, newRows.first?.count ?? 0)

        for row in 0..<copiedRows {
            for column in 0..<copiedColumns {
                newRows[row][column] = oldRows[row][column]
            }
        }

        for row in newRows.indices {
            self.normalizeContinuations(in: &newRows[row])
        }

        return newRows
    }

    fileprivate static func clampedCursor(
        _ cursor: MoshTerminalCursor,
        maximumRow: Int,
        maximumColumn: Int
    ) -> MoshTerminalCursor {
        MoshTerminalCursor(
            row: min(max(cursor.row, 0), maximumRow),
            column: min(max(cursor.column, 0), maximumColumn)
        )
    }

    private static func normalizeContinuations(in row: inout [MoshTerminalCell]) {
        for column in row.indices {
            if row[column].isContinuation {
                if column == 0 || row[column - 1].displayWidth < 2 {
                    row[column] = .blank
                }
                continue
            }

            guard row[column].displayWidth > 1 else {
                continue
            }

            if column + row[column].displayWidth > row.count {
                row[column] = .blank
            } else {
                for continuationColumn in (column + 1)..<(column + row[column].displayWidth) {
                    row[continuationColumn] = .continuation(attributes: row[column].attributes)
                }
            }
        }
    }
}

private enum EscapeState: Equatable, Sendable {
    case escape
    case csi(CSIState)
}

private struct CSIState: Equatable, Sendable {
    var parameters: String = ""
    var intermediates: String = ""
}

private struct MoshTerminalScrollRegion: Equatable, Sendable {
    let top: Int
    let bottom: Int

    var range: ClosedRange<Int> {
        self.top...self.bottom
    }

    var height: Int {
        self.bottom - self.top + 1
    }

    static func full(rowCount: Int) -> MoshTerminalScrollRegion {
        MoshTerminalScrollRegion(top: 0, bottom: max(rowCount - 1, 0))
    }

    func contains(row: Int) -> Bool {
        self.range.contains(row)
    }

    func clamped(rowCount: Int) -> MoshTerminalScrollRegion {
        let maximumRow = max(rowCount - 1, 0)
        let top = min(max(self.top, 0), maximumRow)
        let bottom = min(max(self.bottom, top), maximumRow)
        return MoshTerminalScrollRegion(top: top, bottom: bottom)
    }
}

private struct MoshTerminalScreenBuffer: Equatable, Sendable {
    var rows: [[MoshTerminalCell]]
    var cursor: MoshTerminalCursor
    var scrollRegion: MoshTerminalScrollRegion
    var wrapPending: Bool

    static func blank(dimensions: MoshTerminalDimensions) -> MoshTerminalScreenBuffer {
        let rows = MoshTerminalScreen.blankRows(dimensions: dimensions)
        return MoshTerminalScreenBuffer(
            rows: rows,
            cursor: MoshTerminalCursor(row: 0, column: 0),
            scrollRegion: .full(rowCount: rows.count),
            wrapPending: false
        )
    }

    func resized(to dimensions: MoshTerminalDimensions) -> MoshTerminalScreenBuffer {
        let rows = MoshTerminalScreen.resizedRows(self.rows, dimensions: dimensions)
        return MoshTerminalScreenBuffer(
            rows: rows,
            cursor: MoshTerminalScreen.clampedCursor(
                self.cursor,
                maximumRow: rows.count - 1,
                maximumColumn: (rows.first?.count ?? 1) - 1
            ),
            scrollRegion: self.scrollRegion.clamped(rowCount: rows.count),
            wrapPending: false
        )
    }
}

private struct MoshTerminalSavedCursorState: Equatable, Sendable {
    var cursor: MoshTerminalCursor
    var attributes: MoshTerminalTextAttributes

    func clamped(
        maximumRow: Int,
        maximumColumn: Int
    ) -> MoshTerminalSavedCursorState {
        MoshTerminalSavedCursorState(
            cursor: MoshTerminalScreen.clampedCursor(
                self.cursor,
                maximumRow: maximumRow,
                maximumColumn: maximumColumn
            ),
            attributes: self.attributes
        )
    }
}
