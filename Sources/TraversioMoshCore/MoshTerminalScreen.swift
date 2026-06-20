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

public enum MoshTerminalLineRendition: Equatable, Sendable {
    case singleWidth
    case doubleWidth
    case doubleHeightTop
    case doubleHeightBottom

    public var isDoubleWidth: Bool {
        self != .singleWidth
    }

    public var isDoubleHeight: Bool {
        switch self {
        case .doubleHeightTop, .doubleHeightBottom:
            return true
        case .singleWidth, .doubleWidth:
            return false
        }
    }
}

public struct MoshTerminalHyperlink: Equatable, Sendable {
    public let parameters: String
    public let url: String

    public init(parameters: String, url: String) {
        self.parameters = parameters
        self.url = url
    }
}

public enum MoshTerminalMouseReportingMode: Int, Equatable, Sendable {
    case none = 0
    case x10 = 9
    case vt220 = 1000
    case vt220Highlight = 1001
    case buttonEvent = 1002
    case anyEvent = 1003
}

public enum MoshTerminalMouseEncodingMode: Int, Equatable, Sendable {
    case defaultMode = 0
    case utf8 = 1005
    case sgr = 1006
    case urxvt = 1015
}

public struct MoshTerminalCell: Equatable, Sendable {
    public static let blank = MoshTerminalCell(contents: " ")

    public let contents: String
    public let attributes: MoshTerminalTextAttributes
    public let hyperlink: MoshTerminalHyperlink?
    public let displayWidth: Int
    public let isContinuation: Bool

    public init(
        contents: String,
        attributes: MoshTerminalTextAttributes = .default,
        hyperlink: MoshTerminalHyperlink? = nil
    ) {
        self.contents = contents
        self.attributes = attributes
        self.hyperlink = hyperlink
        self.displayWidth = 1
        self.isContinuation = false
    }

    init(
        scalar: Unicode.Scalar,
        attributes: MoshTerminalTextAttributes,
        hyperlink: MoshTerminalHyperlink?,
        displayWidth: Int
    ) {
        self.contents = String(scalar)
        self.attributes = attributes
        self.hyperlink = hyperlink
        self.displayWidth = displayWidth
        self.isContinuation = false
    }

    private init(
        contents: String,
        attributes: MoshTerminalTextAttributes,
        hyperlink: MoshTerminalHyperlink?,
        displayWidth: Int,
        isContinuation: Bool
    ) {
        self.contents = contents
        self.attributes = attributes
        self.hyperlink = hyperlink
        self.displayWidth = displayWidth
        self.isContinuation = isContinuation
    }

    static func continuation(
        attributes: MoshTerminalTextAttributes,
        hyperlink: MoshTerminalHyperlink?
    ) -> MoshTerminalCell {
        MoshTerminalCell(
            contents: " ",
            attributes: attributes,
            hyperlink: hyperlink,
            displayWidth: 0,
            isContinuation: true
        )
    }

    func appending(_ scalar: Unicode.Scalar) -> MoshTerminalCell {
        MoshTerminalCell(
            contents: self.contents + String(scalar),
            attributes: self.attributes,
            hyperlink: self.hyperlink,
            displayWidth: self.displayWidth,
            isContinuation: self.isContinuation
        )
    }
}

public struct MoshTerminalScreenSnapshot: Equatable, Sendable {
    public let dimensions: MoshTerminalDimensions
    public let cursor: MoshTerminalCursor
    public let isCursorVisible: Bool
    public let isReverseVideoEnabled: Bool
    public let isBracketedPasteEnabled: Bool
    public let mouseReportingMode: MoshTerminalMouseReportingMode
    public let isMouseFocusEventEnabled: Bool
    public let isMouseAlternateScrollEnabled: Bool
    public let mouseEncodingMode: MoshTerminalMouseEncodingMode
    public let isApplicationCursorKeysEnabled: Bool
    public let bellCount: UInt64
    public let titleInitialized: Bool
    public let iconName: String
    public let windowTitle: String
    public let clipboard: String
    public let currentHyperlink: MoshTerminalHyperlink?
    public let rows: [[MoshTerminalCell]]
    public let lineRenditions: [MoshTerminalLineRendition]

    public init(
        dimensions: MoshTerminalDimensions,
        cursor: MoshTerminalCursor,
        isCursorVisible: Bool = true,
        isReverseVideoEnabled: Bool = false,
        isBracketedPasteEnabled: Bool = false,
        mouseReportingMode: MoshTerminalMouseReportingMode = .none,
        isMouseFocusEventEnabled: Bool = false,
        isMouseAlternateScrollEnabled: Bool = false,
        mouseEncodingMode: MoshTerminalMouseEncodingMode = .defaultMode,
        isApplicationCursorKeysEnabled: Bool = false,
        bellCount: UInt64 = 0,
        titleInitialized: Bool = false,
        iconName: String = "",
        windowTitle: String = "",
        clipboard: String = "",
        currentHyperlink: MoshTerminalHyperlink? = nil,
        rows: [[MoshTerminalCell]],
        lineRenditions: [MoshTerminalLineRendition]? = nil
    ) {
        self.dimensions = dimensions
        self.cursor = cursor
        self.isCursorVisible = isCursorVisible
        self.isReverseVideoEnabled = isReverseVideoEnabled
        self.isBracketedPasteEnabled = isBracketedPasteEnabled
        self.mouseReportingMode = mouseReportingMode
        self.isMouseFocusEventEnabled = isMouseFocusEventEnabled
        self.isMouseAlternateScrollEnabled = isMouseAlternateScrollEnabled
        self.mouseEncodingMode = mouseEncodingMode
        self.isApplicationCursorKeysEnabled = isApplicationCursorKeysEnabled
        self.bellCount = bellCount
        self.titleInitialized = titleInitialized
        self.iconName = iconName
        self.windowTitle = windowTitle
        self.clipboard = clipboard
        self.currentHyperlink = currentHyperlink
        self.rows = rows
        self.lineRenditions = Self.normalizedLineRenditions(
            lineRenditions,
            rowCount: rows.count
        )
    }

    public var lineStrings: [String] {
        self.rows.map { row in
            row.map(\.contents).joined()
        }
    }

    private static func normalizedLineRenditions(
        _ lineRenditions: [MoshTerminalLineRendition]?,
        rowCount: Int
    ) -> [MoshTerminalLineRendition] {
        guard let lineRenditions else {
            return Array(repeating: .singleWidth, count: rowCount)
        }

        return Array(lineRenditions.prefix(rowCount))
            + Array(repeating: .singleWidth, count: max(rowCount - lineRenditions.count, 0))
    }
}

public struct MoshTerminalScreen: Sendable {
    private static let maximumStringControlPayloadScalars = 16 * 1024
    private static let maximumOSCTitleScalars = 256

    public private(set) var dimensions: MoshTerminalDimensions
    public private(set) var cursor: MoshTerminalCursor

    private var parser: MoshTerminalInputParser
    private var rows: [[MoshTerminalCell]]
    private var lineRenditions: [MoshTerminalLineRendition]
    private var scrollRegion: MoshTerminalScrollRegion
    private var currentAttributes: MoshTerminalTextAttributes
    private var normalSavedCursorState: MoshTerminalSavedCursorState?
    private var escapeState: EscapeState?
    private var wrapPending: Bool
    private var tabStops: Set<Int>
    private var originMode: Bool
    private var autoWrapMode: Bool
    private var insertMode: Bool
    private var isCursorVisible: Bool
    private var reverseVideo: Bool
    private var bracketedPaste: Bool
    private var mouseReportingMode: MoshTerminalMouseReportingMode
    private var mouseFocusEvent: Bool
    private var mouseAlternateScroll: Bool
    private var mouseEncodingMode: MoshTerminalMouseEncodingMode
    private var applicationCursorKeys: Bool
    private var bellCount: UInt64
    private var titleInitialized: Bool
    private var iconName: String
    private var windowTitle: String
    private var clipboard: String
    private var currentHyperlink: MoshTerminalHyperlink?
    private var g0CharacterSet: MoshTerminalCharacterSet
    private var g1CharacterSet: MoshTerminalCharacterSet
    private var activeCharacterSetSlot: MoshTerminalCharacterSetSlot

    public init(dimensions: MoshTerminalDimensions) {
        self.dimensions = dimensions
        self.cursor = MoshTerminalCursor(row: 0, column: 0)
        self.parser = MoshTerminalInputParser()
        self.rows = Self.blankRows(dimensions: dimensions)
        self.lineRenditions = Self.defaultLineRenditions(rowCount: Int(dimensions.rows))
        self.scrollRegion = .full(rowCount: Int(dimensions.rows))
        self.currentAttributes = .default
        self.normalSavedCursorState = nil
        self.escapeState = nil
        self.wrapPending = false
        self.tabStops = Self.defaultTabStops(columnCount: Int(dimensions.columns))
        self.originMode = false
        self.autoWrapMode = true
        self.insertMode = false
        self.isCursorVisible = true
        self.reverseVideo = false
        self.bracketedPaste = false
        self.mouseReportingMode = .none
        self.mouseFocusEvent = false
        self.mouseAlternateScroll = false
        self.mouseEncodingMode = .defaultMode
        self.applicationCursorKeys = false
        self.bellCount = 0
        self.titleInitialized = false
        self.iconName = ""
        self.windowTitle = ""
        self.clipboard = ""
        self.currentHyperlink = nil
        self.g0CharacterSet = .usASCII
        self.g1CharacterSet = .usASCII
        self.activeCharacterSetSlot = .g0
    }

    public var snapshot: MoshTerminalScreenSnapshot {
        MoshTerminalScreenSnapshot(
            dimensions: self.dimensions,
            cursor: self.cursor,
            isCursorVisible: self.isCursorVisible,
            isReverseVideoEnabled: self.reverseVideo,
            isBracketedPasteEnabled: self.bracketedPaste,
            mouseReportingMode: self.mouseReportingMode,
            isMouseFocusEventEnabled: self.mouseFocusEvent,
            isMouseAlternateScrollEnabled: self.mouseAlternateScroll,
            mouseEncodingMode: self.mouseEncodingMode,
            isApplicationCursorKeysEnabled: self.applicationCursorKeys,
            bellCount: self.bellCount,
            titleInitialized: self.titleInitialized,
            iconName: self.iconName,
            windowTitle: self.windowTitle,
            clipboard: self.clipboard,
            currentHyperlink: self.currentHyperlink,
            rows: self.rows,
            lineRenditions: self.lineRenditions
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
        self.lineRenditions = Self.resizedLineRenditions(
            self.lineRenditions,
            rowCount: self.rows.count
        )
        self.blankCellsPastEffectiveRightMargins()
        self.cursor = self.clampedCursorForLineRendition(self.cursor)
        self.scrollRegion = .full(rowCount: self.rows.count)
        self.wrapPending = false
        self.tabStops = self.tabStops.filter { $0 <= self.maximumColumn }
        self.normalSavedCursorState = self.normalSavedCursorState?.clamped(
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

    private var currentMaximumColumn: Int {
        self.effectiveMaximumColumn(row: self.cursor.row)
    }

    private func effectiveMaximumColumn(row: Int) -> Int {
        guard self.lineRenditions.indices.contains(row),
              self.lineRenditions[row].isDoubleWidth else {
            return self.maximumColumn
        }

        return max((self.maximumColumn + 1) / 2 - 1, 0)
    }

    private mutating func apply(_ control: MoshTerminalControl) {
        switch control {
        case .null:
            break
        case .bell:
            self.bellCount += 1
        case .backspace:
            self.wrapPending = false
            let column = self.previousCursorColumn()
            self.cursor = MoshTerminalCursor(
                row: self.cursor.row,
                column: column
            )
        case .horizontalTab:
            self.moveForwardTabStops(count: 1, preservingPendingWrap: true)
        case .lineFeed:
            self.wrapPending = false
            self.index()
        case .carriageReturn:
            self.wrapPending = false
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
        case .escape:
            self.escapeState = .escape
        case .delete:
            break
        case .c0(let byte):
            switch byte {
            case 0x0b, 0x0c:
                self.wrapPending = false
                self.index()
            case 0x0e:
                self.activeCharacterSetSlot = .g1
            case 0x0f:
                self.activeCharacterSetSlot = .g0
            default:
                break
            }
        case .c1(let byte):
            switch byte {
            case 0x84:
                self.wrapPending = false
                self.index()
            case 0x85:
                self.wrapPending = false
                self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
                self.index()
            case 0x8d:
                self.wrapPending = false
                self.reverseIndex()
            case 0x90:
                self.escapeState = .stringControl(StringControlState(kind: .deviceControl))
            case 0x88:
                self.wrapPending = false
                self.setTabStop()
            case 0x9b:
                self.escapeState = .csi(CSIState())
            case 0x9d:
                self.escapeState = .stringControl(StringControlState(kind: .operatingSystemCommand))
            case 0x9e:
                self.escapeState = .stringControl(StringControlState(kind: .privacyMessage))
            case 0x9f:
                self.escapeState = .stringControl(StringControlState(kind: .applicationProgramCommand))
            default:
                break
            }
        }
    }

    private mutating func place(_ rawScalar: Unicode.Scalar) {
        let scalar = self.activeCharacterSet.map(rawScalar)
        let scalarWidth = MoshTerminalCharacterWidth.width(of: scalar)
        if scalarWidth == .zero {
            self.appendZeroWidthScalar(scalar)
            return
        }

        if self.appendGraphemeClusterContinuation(scalar, width: scalarWidth) {
            return
        }

        if self.autoWrapMode && self.wrapPending {
            self.index()
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
            self.wrapPending = false
        }

        var displayWidth = min(scalarWidth.rawValue, self.currentMaximumColumn + 1)
        if displayWidth > self.availableColumnsFromCursor {
            if self.autoWrapMode {
                self.index()
                self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
                self.wrapPending = false
            } else {
                displayWidth = self.availableColumnsFromCursor
            }
        }

        if self.insertMode {
            self.insertCharacters(count: displayWidth)
        }

        self.clearCellForWrite(row: self.cursor.row, column: self.cursor.column)
        self.rows[self.cursor.row][self.cursor.column] = MoshTerminalCell(
            scalar: scalar,
            attributes: self.currentAttributes,
            hyperlink: self.currentHyperlink,
            displayWidth: displayWidth
        )
        if displayWidth == 2 {
            self.clearCellForWrite(row: self.cursor.row, column: self.cursor.column + 1)
            self.rows[self.cursor.row][self.cursor.column + 1] = .continuation(
                attributes: self.currentAttributes,
                hyperlink: self.currentHyperlink
            )
        }

        let lastColumn = self.cursor.column + displayWidth - 1
        if lastColumn == self.currentMaximumColumn {
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: self.currentMaximumColumn)
            self.wrapPending = true
        } else {
            self.cursor = MoshTerminalCursor(
                row: self.cursor.row,
                column: lastColumn + 1
            )
            self.wrapPending = false
        }
    }

    private var availableColumnsFromCursor: Int {
        self.currentMaximumColumn - self.cursor.column + 1
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

    private mutating func appendGraphemeClusterContinuation(
        _ scalar: Unicode.Scalar,
        width: MoshTerminalScalarWidth
    ) -> Bool {
        guard width == .wide,
              let column = self.activeGraphemeClusterColumn(),
              self.rows[self.cursor.row][column].contents.unicodeScalars.last?.value == 0x200d else {
            return false
        }

        self.rows[self.cursor.row][column] = self.rows[self.cursor.row][column].appending(scalar)
        return true
    }

    private func activeGraphemeClusterColumn() -> Int? {
        guard self.rows.indices.contains(self.cursor.row) else {
            return nil
        }

        let targetColumn: Int
        if self.wrapPending {
            targetColumn = self.cursor.column
        } else if self.cursor.column > 0 {
            targetColumn = self.cursor.column - 1
        } else {
            targetColumn = self.cursor.column
        }

        guard self.rows[self.cursor.row].indices.contains(targetColumn) else {
            return nil
        }

        return self.leadingColumn(row: self.cursor.row, column: targetColumn)
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
        self.clampCursorToCurrentLine()
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
        self.clampCursorToCurrentLine()
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
        let activeLineRenditions = Array(self.lineRenditions[region.range])
        let replacement = Array(activeRows.dropFirst(amount))
            + Self.blankRows(rowCount: amount, columnCount: self.maximumColumn + 1)
        let replacementLineRenditions = Array(activeLineRenditions.dropFirst(amount))
            + Self.defaultLineRenditions(rowCount: amount)
        self.replaceRows(
            in: region.range,
            with: replacement,
            lineRenditions: replacementLineRenditions
        )
    }

    private mutating func scrollRowsDown(count: Int, region: MoshTerminalScrollRegion) {
        let amount = min(max(count, 0), region.height)
        guard amount > 0 else {
            return
        }

        let activeRows = Array(self.rows[region.range])
        let activeLineRenditions = Array(self.lineRenditions[region.range])
        let replacement = Self.blankRows(rowCount: amount, columnCount: self.maximumColumn + 1)
            + Array(activeRows.dropLast(amount))
        let replacementLineRenditions = Self.defaultLineRenditions(rowCount: amount)
            + Array(activeLineRenditions.dropLast(amount))
        self.replaceRows(
            in: region.range,
            with: replacement,
            lineRenditions: replacementLineRenditions
        )
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
        let activeLineRenditions = Array(self.lineRenditions[range])
        let replacement = Self.blankRows(rowCount: amount, columnCount: self.maximumColumn + 1)
            + Array(activeRows.dropLast(amount))
        let replacementLineRenditions = Self.defaultLineRenditions(rowCount: amount)
            + Array(activeLineRenditions.dropLast(amount))
        self.replaceRows(
            in: range,
            with: replacement,
            lineRenditions: replacementLineRenditions
        )
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
        let activeLineRenditions = Array(self.lineRenditions[range])
        let replacement = Array(activeRows.dropFirst(amount))
            + Self.blankRows(rowCount: amount, columnCount: self.maximumColumn + 1)
        let replacementLineRenditions = Array(activeLineRenditions.dropFirst(amount))
            + Self.defaultLineRenditions(rowCount: amount)
        self.replaceRows(
            in: range,
            with: replacement,
            lineRenditions: replacementLineRenditions
        )
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
        let lineMaximumColumn = self.currentMaximumColumn
        if self.cursor.column + amount <= lineMaximumColumn {
            for column in stride(
                from: lineMaximumColumn,
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
        let lineMaximumColumn = self.currentMaximumColumn
        let tailStart = self.cursor.column + amount
        if tailStart <= lineMaximumColumn {
            for column in self.cursor.column...(lineMaximumColumn - amount) {
                row[column] = row[column + amount]
            }
        }
        for column in (lineMaximumColumn - amount + 1)...lineMaximumColumn {
            row[column] = .blank
        }
        Self.normalizeContinuations(in: &row)
        self.rows[self.cursor.row] = row
        self.wrapPending = false
    }

    private mutating func replaceRows(
        in range: ClosedRange<Int>,
        with replacement: [[MoshTerminalCell]],
        lineRenditions replacementLineRenditions: [MoshTerminalLineRendition]
    ) {
        for offset in replacement.indices {
            self.rows[range.lowerBound + offset] = replacement[offset]
            self.lineRenditions[range.lowerBound + offset] = replacementLineRenditions[offset]
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
        self.activeSavedCursorState = MoshTerminalSavedCursorState(
            cursor: self.cursor,
            attributes: self.currentAttributes,
            autoWrapMode: self.autoWrapMode,
            originMode: self.originMode
        )
    }

    private mutating func restoreCursorState() {
        let savedCursorState = self.activeSavedCursorState ?? .default

        self.cursor = self.clampedCursorForLineRendition(savedCursorState.cursor)
        self.currentAttributes = savedCursorState.attributes
        self.autoWrapMode = savedCursorState.autoWrapMode
        self.originMode = savedCursorState.originMode
    }

    private var activeSavedCursorState: MoshTerminalSavedCursorState? {
        get {
            self.normalSavedCursorState
        }
        set {
            self.normalSavedCursorState = newValue
        }
    }

    private mutating func setPrivateMode(_ mode: Int, enabled: Bool) {
        switch mode {
        case 1:
            self.applicationCursorKeys = enabled
        case 3:
            self.clearScreenForColumnMode()
        case 5:
            self.reverseVideo = enabled
        case 6:
            self.originMode = enabled
            self.homeCursor()
        case 7:
            self.autoWrapMode = enabled
        case 9, 1000...1003:
            self.mouseReportingMode = enabled
                ? (MoshTerminalMouseReportingMode(rawValue: mode) ?? .none)
                : .none
        case 25:
            self.isCursorVisible = enabled
        case 1004:
            self.mouseFocusEvent = enabled
        case 1005, 1006, 1015:
            self.mouseEncodingMode = enabled
                ? (MoshTerminalMouseEncodingMode(rawValue: mode) ?? .defaultMode)
                : .defaultMode
        case 1007:
            self.mouseAlternateScroll = enabled
        case 2004:
            self.bracketedPaste = enabled
        default:
            break
        }
    }

    private mutating func clearScreenForColumnMode() {
        self.rows = Self.blankRows(dimensions: self.dimensions)
        self.homeCursor()
    }

    private mutating func setMode(_ mode: Int, enabled: Bool) {
        switch mode {
        case 4:
            self.insertMode = enabled
        default:
            break
        }
    }

    private mutating func consumeEscapeToken(_ token: MoshTerminalInputToken) {
        guard let state = self.escapeState else {
            return
        }

        switch (state, token) {
        case (.escape, .scalar("[")):
            self.escapeState = .csi(CSIState())
        case (.escape, .scalar("(")):
            self.escapeState = .characterSetDesignation(.g0)
        case (.escape, .scalar(")")):
            self.escapeState = .characterSetDesignation(.g1)
        case (.escape, .scalar("#")):
            self.escapeState = .escapeHash
        case (.escape, .scalar("P")):
            self.escapeState = .stringControl(StringControlState(kind: .deviceControl))
        case (.escape, .scalar("X")):
            self.escapeState = .stringControl(StringControlState(kind: .startOfString))
        case (.escape, .scalar("]")):
            self.escapeState = .stringControl(StringControlState(kind: .operatingSystemCommand))
        case (.escape, .scalar("^")):
            self.escapeState = .stringControl(StringControlState(kind: .privacyMessage))
        case (.escape, .scalar("_")):
            self.escapeState = .stringControl(StringControlState(kind: .applicationProgramCommand))
        case (.escape, .scalar("7")):
            self.wrapPending = false
            self.saveCursorState()
            self.escapeState = nil
        case (.escape, .scalar("8")):
            self.wrapPending = false
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
        case (.escape, .control(.c1(0x90))):
            self.escapeState = .stringControl(StringControlState(kind: .deviceControl))
        case (.escape, .control(.c1(0x98))):
            self.escapeState = .stringControl(StringControlState(kind: .startOfString))
        case (.escape, .control(.c1(0x9d))):
            self.escapeState = .stringControl(StringControlState(kind: .operatingSystemCommand))
        case (.escape, .control(.c1(0x9e))):
            self.escapeState = .stringControl(StringControlState(kind: .privacyMessage))
        case (.escape, .control(.c1(0x9f))):
            self.escapeState = .stringControl(StringControlState(kind: .applicationProgramCommand))
        case (.escape, _):
            self.wrapPending = false
            self.escapeState = nil
        case (.csi(let csiState), .scalar(let scalar)):
            self.consumeCSI(scalar: scalar, state: csiState)
        case (.csi, .control(.escape)):
            self.escapeState = .escape
        case (.csi, _):
            break
        case (.characterSetDesignation(let slot), .scalar(let scalar)):
            self.designateCharacterSet(slot: slot, final: scalar)
            self.escapeState = nil
        case (.characterSetDesignation, .control(.escape)):
            self.escapeState = .escape
        case (.characterSetDesignation, _):
            self.escapeState = nil
        case (.escapeHash, .scalar("3")):
            self.setLineRendition(.doubleHeightTop)
            self.escapeState = nil
        case (.escapeHash, .scalar("4")):
            self.setLineRendition(.doubleHeightBottom)
            self.escapeState = nil
        case (.escapeHash, .scalar("5")):
            self.setLineRendition(.singleWidth)
            self.escapeState = nil
        case (.escapeHash, .scalar("6")):
            self.setLineRendition(.doubleWidth)
            self.escapeState = nil
        case (.escapeHash, .scalar("8")):
            self.screenAlignmentTest()
            self.escapeState = nil
        case (.escapeHash, .control(.escape)):
            self.escapeState = .escape
        case (.escapeHash, _):
            self.wrapPending = false
            self.escapeState = nil
        case (.stringControl(let stringState), _):
            self.consumeStringControl(token: token, state: stringState)
        }
    }

    private var activeCharacterSet: MoshTerminalCharacterSet {
        switch self.activeCharacterSetSlot {
        case .g0:
            return self.g0CharacterSet
        case .g1:
            return self.g1CharacterSet
        }
    }

    private mutating func designateCharacterSet(
        slot: MoshTerminalCharacterSetSlot,
        final scalar: Unicode.Scalar
    ) {
        guard let characterSet = MoshTerminalCharacterSet(designationFinal: scalar) else {
            return
        }

        switch slot {
        case .g0:
            self.g0CharacterSet = characterSet
        case .g1:
            self.g1CharacterSet = characterSet
        }
    }

    private mutating func screenAlignmentTest() {
        self.rows = Self.alignmentRows(dimensions: self.dimensions)
        self.lineRenditions = Self.defaultLineRenditions(rowCount: self.rows.count)
        self.cursor = MoshTerminalCursor(row: 0, column: 0)
        self.scrollRegion = .full(rowCount: self.rows.count)
        self.currentAttributes = .default
        self.wrapPending = false
        self.originMode = false
    }

    private mutating func setLineRendition(_ rendition: MoshTerminalLineRendition) {
        let row = self.cursor.row
        guard self.lineRenditions.indices.contains(row) else {
            return
        }

        let previousRendition = self.lineRenditions[row]
        self.lineRenditions[row] = rendition
        if rendition.isDoubleWidth, previousRendition.isDoubleWidth == false {
            self.blankCellsPastEffectiveRightMargin(row: row)
        }
        self.clampCursorToCurrentLine()
        self.wrapPending = false
    }

    private mutating func consumeStringControl(
        token: MoshTerminalInputToken,
        state: StringControlState
    ) {
        switch token {
        case .control(.bell) where state.kind == .operatingSystemCommand:
            self.finishStringControl(state)
            self.escapeState = nil
            return
        case .control(.c1(0x9c)):
            self.finishStringControl(state)
            self.escapeState = nil
            return
        default:
            break
        }

        if state.pendingEscape {
            if case .scalar("\\") = token {
                self.finishStringControl(state)
                self.escapeState = nil
                return
            }

            var nextState = self.appendingStringControlPayload(token, to: state)
            nextState.pendingEscape = token == .control(.escape)
            self.escapeState = .stringControl(nextState)
            return
        }

        switch token {
        case .control(.escape):
            var nextState = state
            nextState.pendingEscape = true
            self.escapeState = .stringControl(nextState)
        default:
            self.escapeState = .stringControl(
                self.appendingStringControlPayload(token, to: state)
            )
        }
    }

    private mutating func finishStringControl(_ state: StringControlState) {
        guard state.kind == .operatingSystemCommand else {
            return
        }

        self.dispatchOSC(state.payload)
    }

    private func appendingStringControlPayload(
        _ token: MoshTerminalInputToken,
        to state: StringControlState
    ) -> StringControlState {
        guard state.kind == .operatingSystemCommand,
              state.payload.unicodeScalars.count < Self.maximumStringControlPayloadScalars,
              case .scalar(let scalar) = token else {
            return state
        }

        var nextState = state
        nextState.payload.unicodeScalars.append(scalar)
        return nextState
    }

    private mutating func dispatchOSC(_ payload: String) {
        let scalars = Array(payload.unicodeScalars)

        if scalars.count >= 5,
           Self.isASCII(scalars[0], UInt8(ascii: "5")),
           Self.isASCII(scalars[1], UInt8(ascii: "2")),
           Self.isASCII(scalars[2], UInt8(ascii: ";")),
           Self.isASCII(scalars[3], UInt8(ascii: "c")),
           Self.isASCII(scalars[4], UInt8(ascii: ";")) {
            self.clipboard = Self.string(from: scalars.dropFirst(5))
            return
        }

        guard scalars.isEmpty == false else {
            return
        }

        let command: Int
        let offset: Int
        if Self.isASCII(scalars[0], UInt8(ascii: ";")) {
            command = 0
            offset = 1
        } else if scalars.count >= 2, Self.isASCII(scalars[1], UInt8(ascii: ";")) {
            command = Int(scalars[0].value) - Int(UInt8(ascii: "0"))
            offset = 2
        } else {
            return
        }

        if command == 8 {
            self.dispatchOSC8(scalars)
            return
        }

        let setIcon = command == 0 || command == 1
        let setTitle = command == 0 || command == 2
        guard setIcon || setTitle else {
            return
        }

        self.titleInitialized = true
        let end = min(scalars.count, Self.maximumOSCTitleScalars)
        let title = offset < end ? Self.string(from: scalars[offset..<end]) : ""
        if setIcon {
            self.iconName = title
        }
        if setTitle {
            self.windowTitle = title
        }
    }

    private mutating func dispatchOSC8(_ scalars: [Unicode.Scalar]) {
        guard scalars.allSatisfy({ (32...126).contains($0.value) }),
              scalars.count > 2,
              Self.isASCII(scalars[1], UInt8(ascii: ";")) else {
            return
        }

        guard let secondSemicolon = scalars.indices.dropFirst(2).first(where: {
            Self.isASCII(scalars[$0], UInt8(ascii: ";"))
        }) else {
            return
        }

        let parameters = Self.string(from: scalars[2..<secondSemicolon])
        let url = Self.string(from: scalars[(secondSemicolon + 1)..<scalars.endIndex])
        if url.isEmpty {
            self.currentHyperlink = nil
        } else {
            self.currentHyperlink = MoshTerminalHyperlink(parameters: parameters, url: url)
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
        if intermediates == "!", finalByte == UInt8(ascii: "p") {
            self.softReset()
            return
        }

        guard intermediates.isEmpty else {
            self.wrapPending = false
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
            self.moveForwardTabStops(
                count: Self.parameter(values, at: 0, default: 1),
                preservingPendingWrap: true
            )
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
            self.moveBackwardTabStops(
                count: Self.parameter(values, at: 0, default: 1),
                preservingPendingWrap: true
            )
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
            self.clearTabStops(
                mode: Self.parameter(values, at: 0, default: 0),
                preservingPendingWrap: true
            )
        case UInt8(ascii: "h"):
            if isPrivate {
                values.compactMap { $0 }.forEach { self.setPrivateMode($0, enabled: true) }
            } else {
                values.compactMap { $0 }.forEach { self.setMode($0, enabled: true) }
            }
        case UInt8(ascii: "l"):
            if isPrivate {
                values.compactMap { $0 }.forEach { self.setPrivateMode($0, enabled: false) }
            } else {
                values.compactMap { $0 }.forEach { self.setMode($0, enabled: false) }
            }
        case UInt8(ascii: "m"):
            self.applySGR(parameters: values)
        case UInt8(ascii: "r"):
            self.setScrollRegion(parameters: values)
        default:
            self.wrapPending = false
            break
        }
    }

    private mutating func reset() {
        self.rows = Self.blankRows(dimensions: self.dimensions)
        self.lineRenditions = Self.defaultLineRenditions(rowCount: self.rows.count)
        self.cursor = MoshTerminalCursor(row: 0, column: 0)
        self.scrollRegion = .full(rowCount: self.rows.count)
        self.currentAttributes = .default
        self.normalSavedCursorState = nil
        self.escapeState = nil
        self.wrapPending = false
        self.tabStops = Self.defaultTabStops(columnCount: Int(self.dimensions.columns))
        self.originMode = false
        self.autoWrapMode = true
        self.insertMode = false
        self.isCursorVisible = true
        self.reverseVideo = false
        self.bracketedPaste = false
        self.mouseReportingMode = .none
        self.mouseFocusEvent = false
        self.mouseAlternateScroll = false
        self.mouseEncodingMode = .defaultMode
        self.applicationCursorKeys = false
        self.windowTitle = ""
        self.clipboard = ""
        self.currentHyperlink = nil
        self.g0CharacterSet = .usASCII
        self.g1CharacterSet = .usASCII
        self.activeCharacterSetSlot = .g0
    }

    private mutating func softReset() {
        self.scrollRegion = .full(rowCount: self.rows.count)
        self.currentAttributes = .default
        self.normalSavedCursorState = nil
        self.wrapPending = false
        self.originMode = false
        self.insertMode = false
        self.isCursorVisible = true
        self.applicationCursorKeys = false
        self.currentHyperlink = nil
    }

    private mutating func moveCursor(rowDelta: Int, columnDelta: Int) {
        let rowBounds = self.relativeCursorRowBounds
        let targetRow = min(max(self.cursor.row + rowDelta, rowBounds.lowerBound), rowBounds.upperBound)
        self.cursor = MoshTerminalCursor(
            row: targetRow,
            column: min(max(self.cursor.column + columnDelta, 0), self.effectiveMaximumColumn(row: targetRow))
        )
        self.wrapPending = false
    }

    private mutating func setCursor(row: Int, column: Int) {
        let targetRow = min(max(row, 0), self.maximumRow)
        self.cursor = MoshTerminalCursor(
            row: targetRow,
            column: min(max(column, 0), self.effectiveMaximumColumn(row: targetRow))
        )
        self.wrapPending = false
    }

    private mutating func setPositionedCursor(row: Int, column: Int) {
        let rowBounds = self.absoluteCursorRowBounds
        let absoluteRow = self.originMode ? self.scrollRegion.top + row : row
        let targetRow = min(max(absoluteRow, rowBounds.lowerBound), rowBounds.upperBound)
        self.cursor = MoshTerminalCursor(
            row: targetRow,
            column: min(max(column, 0), self.effectiveMaximumColumn(row: targetRow))
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

    private mutating func moveForwardTabStops(
        count: Int,
        preservingPendingWrap: Bool = false
    ) {
        let pendingWrap = self.wrapPending
        defer {
            if preservingPendingWrap {
                self.wrapPending = pendingWrap
            }
        }

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

    private mutating func moveBackwardTabStops(
        count: Int,
        preservingPendingWrap: Bool = false
    ) {
        let pendingWrap = self.wrapPending
        defer {
            if preservingPendingWrap {
                self.wrapPending = pendingWrap
            }
        }

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
        self.tabStops.filter { $0 > column && $0 <= self.currentMaximumColumn }.min()
            ?? self.currentMaximumColumn
    }

    private func previousTabStop(before column: Int) -> Int {
        self.tabStops.filter { $0 < column }.max() ?? 0
    }

    private mutating func setTabStop() {
        self.tabStops.insert(self.cursor.column)
        self.wrapPending = false
    }

    private mutating func clearTabStops(
        mode: Int,
        preservingPendingWrap: Bool = false
    ) {
        let pendingWrap = self.wrapPending
        defer {
            if preservingPendingWrap {
                self.wrapPending = pendingWrap
            }
        }

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
        case 2:
            self.rows = Self.blankRows(dimensions: self.dimensions)
        default:
            break
        }
        self.wrapPending = false
    }

    private mutating func eraseLine(mode: Int) {
        let lineMaximumColumn = self.currentMaximumColumn
        switch mode {
        case 0:
            self.blankCells(row: self.cursor.row, columns: self.cursor.column...lineMaximumColumn)
        case 1:
            self.blankCells(row: self.cursor.row, columns: 0...self.cursor.column)
        case 2:
            self.blankCells(row: self.cursor.row, columns: 0...lineMaximumColumn)
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

    private mutating func blankCellsPastEffectiveRightMargins() {
        for row in self.rows.indices {
            self.blankCellsPastEffectiveRightMargin(row: row)
        }
    }

    private mutating func blankCellsPastEffectiveRightMargin(row: Int) {
        guard self.rows.indices.contains(row) else {
            return
        }

        let lineMaximumColumn = self.effectiveMaximumColumn(row: row)
        guard lineMaximumColumn < self.maximumColumn else {
            return
        }

        for column in (lineMaximumColumn + 1)...self.maximumColumn {
            self.clearCellForWrite(row: row, column: column)
        }
    }

    private mutating func clampCursorToCurrentLine() {
        self.cursor = self.clampedCursorForLineRendition(self.cursor)
    }

    private func clampedCursorForLineRendition(_ cursor: MoshTerminalCursor) -> MoshTerminalCursor {
        let row = min(max(cursor.row, 0), self.maximumRow)
        return MoshTerminalCursor(
            row: row,
            column: min(max(cursor.column, 0), self.effectiveMaximumColumn(row: row))
        )
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
            case 5:
                self.currentAttributes.isBlinking = true
            case 25:
                self.currentAttributes.isBlinking = false
            case 7:
                self.currentAttributes.isInverse = true
            case 27:
                self.currentAttributes.isInverse = false
            case 8:
                self.currentAttributes.isInvisible = true
            case 28:
                self.currentAttributes.isInvisible = false
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

    private static func isASCII(_ scalar: Unicode.Scalar, _ byte: UInt8) -> Bool {
        scalar.value == UInt32(byte)
    }

    private static func string<C: Collection>(from scalars: C) -> String where C.Element == Unicode.Scalar {
        var string = ""
        for scalar in scalars {
            string.unicodeScalars.append(scalar)
        }
        return string
    }

    fileprivate static func blankRows(dimensions: MoshTerminalDimensions) -> [[MoshTerminalCell]] {
        self.blankRows(rowCount: Int(dimensions.rows), columnCount: Int(dimensions.columns))
    }

    fileprivate static func blankRows(rowCount: Int, columnCount: Int) -> [[MoshTerminalCell]] {
        return (0..<rowCount).map { _ in
            self.blankRow(columnCount: columnCount)
        }
    }

    fileprivate static func defaultLineRenditions(rowCount: Int) -> [MoshTerminalLineRendition] {
        Array(repeating: .singleWidth, count: rowCount)
    }

    fileprivate static func resizedLineRenditions(
        _ oldLineRenditions: [MoshTerminalLineRendition],
        rowCount: Int
    ) -> [MoshTerminalLineRendition] {
        Array(oldLineRenditions.prefix(rowCount))
            + Self.defaultLineRenditions(rowCount: max(rowCount - oldLineRenditions.count, 0))
    }

    private static func alignmentRows(dimensions: MoshTerminalDimensions) -> [[MoshTerminalCell]] {
        let cell = MoshTerminalCell(
            scalar: "E",
            attributes: .default,
            hyperlink: nil,
            displayWidth: 1
        )
        return (0..<Int(dimensions.rows)).map { _ in
            Array(repeating: cell, count: Int(dimensions.columns))
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
                    row[continuationColumn] = .continuation(
                        attributes: row[column].attributes,
                        hyperlink: row[column].hyperlink
                    )
                }
            }
        }
    }
}

private enum EscapeState: Equatable, Sendable {
    case escape
    case csi(CSIState)
    case characterSetDesignation(MoshTerminalCharacterSetSlot)
    case escapeHash
    case stringControl(StringControlState)
}

private enum MoshTerminalCharacterSetSlot: Equatable, Sendable {
    case g0
    case g1
}

private enum MoshTerminalCharacterSet: Equatable, Sendable {
    case usASCII
    case decSpecialGraphics

    init?(designationFinal scalar: Unicode.Scalar) {
        switch scalar {
        case "0":
            self = .decSpecialGraphics
        case "B":
            self = .usASCII
        default:
            return nil
        }
    }

    func map(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch self {
        case .usASCII:
            return scalar
        case .decSpecialGraphics:
            return Self.decSpecialGraphicsScalar(for: scalar)
        }
    }

    private static func decSpecialGraphicsScalar(for scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0x5f:
            return Self.scalar(0x25ae)
        case 0x60:
            return Self.scalar(0x25c6)
        case 0x61:
            return Self.scalar(0x2592)
        case 0x62:
            return Self.scalar(0x2409)
        case 0x63:
            return Self.scalar(0x240c)
        case 0x64:
            return Self.scalar(0x240d)
        case 0x65:
            return Self.scalar(0x240a)
        case 0x66:
            return Self.scalar(0x00b0)
        case 0x67:
            return Self.scalar(0x00b1)
        case 0x68:
            return Self.scalar(0x2424)
        case 0x69:
            return Self.scalar(0x240b)
        case 0x6a:
            return Self.scalar(0x2518)
        case 0x6b:
            return Self.scalar(0x2510)
        case 0x6c:
            return Self.scalar(0x250c)
        case 0x6d:
            return Self.scalar(0x2514)
        case 0x6e:
            return Self.scalar(0x253c)
        case 0x6f:
            return Self.scalar(0x23ba)
        case 0x70:
            return Self.scalar(0x23bb)
        case 0x71:
            return Self.scalar(0x2500)
        case 0x72:
            return Self.scalar(0x23bc)
        case 0x73:
            return Self.scalar(0x23bd)
        case 0x74:
            return Self.scalar(0x251c)
        case 0x75:
            return Self.scalar(0x2524)
        case 0x76:
            return Self.scalar(0x2534)
        case 0x77:
            return Self.scalar(0x252c)
        case 0x78:
            return Self.scalar(0x2502)
        case 0x79:
            return Self.scalar(0x2264)
        case 0x7a:
            return Self.scalar(0x2265)
        case 0x7b:
            return Self.scalar(0x03c0)
        case 0x7c:
            return Self.scalar(0x2260)
        case 0x7d:
            return Self.scalar(0x00a3)
        case 0x7e:
            return Self.scalar(0x00b7)
        default:
            return scalar
        }
    }

    private static func scalar(_ value: UInt32) -> Unicode.Scalar {
        guard let scalar = Unicode.Scalar(value) else {
            preconditionFailure("Invalid Unicode scalar in DEC Special Graphics mapping")
        }
        return scalar
    }
}

private struct CSIState: Equatable, Sendable {
    var parameters: String = ""
    var intermediates: String = ""
}

private enum StringControlKind: Equatable, Sendable {
    case deviceControl
    case startOfString
    case operatingSystemCommand
    case privacyMessage
    case applicationProgramCommand
}

private struct StringControlState: Equatable, Sendable {
    var kind: StringControlKind
    var pendingEscape = false
    var payload = ""
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

private struct MoshTerminalSavedCursorState: Equatable, Sendable {
    static let `default` = MoshTerminalSavedCursorState(
        cursor: MoshTerminalCursor(row: 0, column: 0),
        attributes: .default,
        autoWrapMode: true,
        originMode: false
    )

    var cursor: MoshTerminalCursor
    var attributes: MoshTerminalTextAttributes
    var autoWrapMode: Bool
    var originMode: Bool

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
            attributes: self.attributes,
            autoWrapMode: self.autoWrapMode,
            originMode: self.originMode
        )
    }
}
