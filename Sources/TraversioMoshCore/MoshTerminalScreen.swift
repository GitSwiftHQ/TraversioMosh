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

    public init(
        contents: String,
        attributes: MoshTerminalTextAttributes = .default
    ) {
        self.contents = contents
        self.attributes = attributes
    }

    init(
        scalar: Unicode.Scalar,
        attributes: MoshTerminalTextAttributes
    ) {
        self.contents = String(scalar)
        self.attributes = attributes
    }

    func appending(_ scalar: Unicode.Scalar) -> MoshTerminalCell {
        MoshTerminalCell(
            contents: self.contents + String(scalar),
            attributes: self.attributes
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
    private var currentAttributes: MoshTerminalTextAttributes
    private var escapeState: EscapeState?
    private var wrapPending: Bool

    public init(dimensions: MoshTerminalDimensions) {
        self.dimensions = dimensions
        self.cursor = MoshTerminalCursor(row: 0, column: 0)
        self.parser = MoshTerminalInputParser()
        self.rows = Self.blankRows(dimensions: dimensions)
        self.currentAttributes = .default
        self.escapeState = nil
        self.wrapPending = false
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
        let oldRows = self.rows
        var newRows = Self.blankRows(dimensions: dimensions)
        let copiedRows = min(oldRows.count, newRows.count)
        let copiedColumns = min(oldRows.first?.count ?? 0, newRows.first?.count ?? 0)

        for row in 0..<copiedRows {
            for column in 0..<copiedColumns {
                newRows[row][column] = oldRows[row][column]
            }
        }

        self.dimensions = dimensions
        self.rows = newRows
        self.cursor = MoshTerminalCursor(
            row: min(self.cursor.row, self.maximumRow),
            column: min(self.cursor.column, self.maximumColumn)
        )
        self.wrapPending = false
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
            self.cursor = MoshTerminalCursor(
                row: self.cursor.row,
                column: max(0, self.cursor.column - 1)
            )
        case .horizontalTab:
            self.wrapPending = false
            let nextTabColumn = ((self.cursor.column / 8) + 1) * 8
            self.cursor = MoshTerminalCursor(
                row: self.cursor.row,
                column: min(nextTabColumn, self.maximumColumn)
            )
        case .lineFeed:
            self.wrapPending = false
            self.moveDownOneLine()
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
            if byte == 0x9b {
                self.escapeState = .csi("")
                self.wrapPending = false
            }
        }
    }

    private mutating func place(_ scalar: Unicode.Scalar) {
        if Self.isCombiningScalar(scalar) {
            let column = self.cursor.column > 0 ? self.cursor.column - 1 : self.cursor.column
            self.rows[self.cursor.row][column] = self.rows[self.cursor.row][column].appending(scalar)
            return
        }

        if self.wrapPending {
            self.moveDownOneLine()
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
            self.wrapPending = false
        }

        self.rows[self.cursor.row][self.cursor.column] = MoshTerminalCell(
            scalar: scalar,
            attributes: self.currentAttributes
        )
        if self.cursor.column == self.maximumColumn {
            self.wrapPending = true
        } else {
            self.cursor = MoshTerminalCursor(
                row: self.cursor.row,
                column: self.cursor.column + 1
            )
        }
    }

    private mutating func moveDownOneLine() {
        if self.cursor.row == self.maximumRow {
            self.rows.removeFirst()
            self.rows.append(Self.blankRow(columnCount: self.maximumColumn + 1))
        } else {
            self.cursor = MoshTerminalCursor(
                row: self.cursor.row + 1,
                column: self.cursor.column
            )
        }
    }

    private mutating func consumeEscapeToken(_ token: MoshTerminalInputToken) {
        guard let state = self.escapeState else {
            return
        }

        switch (state, token) {
        case (.escape, .scalar("[")):
            self.escapeState = .csi("")
        case (.escape, .scalar("c")):
            self.reset()
        case (.escape, .control(.c1(0x9b))):
            self.escapeState = .csi("")
        case (.escape, _):
            self.escapeState = nil
        case (.csi(let parameters), .scalar(let scalar)):
            self.consumeCSI(scalar: scalar, parameters: parameters)
        case (.csi, .control(.escape)):
            self.escapeState = .escape
        case (.csi, _):
            break
        }
    }

    private mutating func consumeCSI(scalar: Unicode.Scalar, parameters: String) {
        guard let byte = UInt8(exactly: scalar.value) else {
            self.escapeState = nil
            return
        }

        if (0x30...0x3f).contains(byte) {
            guard parameters.count < 64 else {
                self.escapeState = nil
                return
            }
            self.escapeState = .csi(parameters + String(scalar))
            return
        }

        if (0x20...0x2f).contains(byte) {
            return
        }

        if (0x40...0x7e).contains(byte) {
            self.executeCSI(finalByte: byte, parameters: parameters)
            self.escapeState = nil
            return
        }

        self.escapeState = nil
    }

    private mutating func executeCSI(finalByte: UInt8, parameters: String) {
        let values = Self.parseCSIParameters(parameters)

        switch finalByte {
        case UInt8(ascii: "A"):
            self.moveCursor(rowDelta: -Self.parameter(values, at: 0, default: 1), columnDelta: 0)
        case UInt8(ascii: "B"):
            self.moveCursor(rowDelta: Self.parameter(values, at: 0, default: 1), columnDelta: 0)
        case UInt8(ascii: "C"):
            self.moveCursor(rowDelta: 0, columnDelta: Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "D"):
            self.moveCursor(rowDelta: 0, columnDelta: -Self.parameter(values, at: 0, default: 1))
        case UInt8(ascii: "G"):
            self.setCursor(
                row: self.cursor.row,
                column: Self.parameter(values, at: 0, default: 1) - 1
            )
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            self.setCursor(
                row: Self.parameter(values, at: 0, default: 1) - 1,
                column: Self.parameter(values, at: 1, default: 1) - 1
            )
        case UInt8(ascii: "J"):
            self.eraseScreen(mode: Self.parameter(values, at: 0, default: 0))
        case UInt8(ascii: "K"):
            self.eraseLine(mode: Self.parameter(values, at: 0, default: 0))
        case UInt8(ascii: "m"):
            self.applySGR(parameters: values)
        default:
            break
        }
    }

    private mutating func reset() {
        self.rows = Self.blankRows(dimensions: self.dimensions)
        self.cursor = MoshTerminalCursor(row: 0, column: 0)
        self.currentAttributes = .default
        self.escapeState = nil
        self.wrapPending = false
    }

    private mutating func moveCursor(rowDelta: Int, columnDelta: Int) {
        self.setCursor(
            row: self.cursor.row + rowDelta,
            column: self.cursor.column + columnDelta
        )
    }

    private mutating func setCursor(row: Int, column: Int) {
        self.cursor = MoshTerminalCursor(
            row: min(max(row, 0), self.maximumRow),
            column: min(max(column, 0), self.maximumColumn)
        )
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

    private mutating func blankCells(row: Int, columns: ClosedRange<Int>) {
        for column in columns {
            self.rows[row][column] = .blank
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

    private static func blankRows(dimensions: MoshTerminalDimensions) -> [[MoshTerminalCell]] {
        let rowCount = Int(dimensions.rows)
        let columnCount = Int(dimensions.columns)
        return (0..<rowCount).map { _ in
            self.blankRow(columnCount: columnCount)
        }
    }

    private static func blankRow(columnCount: Int) -> [MoshTerminalCell] {
        Array(repeating: .blank, count: columnCount)
    }

    private static func isCombiningScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0300...0x036f,
             0x1ab0...0x1aff,
             0x1dc0...0x1dff,
             0x20d0...0x20ff,
             0xfe20...0xfe2f:
            return true
        default:
            return false
        }
    }
}

private enum EscapeState: Equatable, Sendable {
    case escape
    case csi(String)
}
