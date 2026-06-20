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
    private static let maximumGraphemeByteCount = 32

    public static let blank = MoshTerminalCell(
        contents: " ",
        attributes: .default,
        hyperlink: nil,
        displayWidth: 1,
        isContinuation: false,
        isImplicitBlank: true,
        isFallback: false
    )

    public let contents: String
    public let attributes: MoshTerminalTextAttributes
    public let hyperlink: MoshTerminalHyperlink?
    public let displayWidth: Int
    public let isContinuation: Bool
    fileprivate let isImplicitBlank: Bool
    private let isFallback: Bool

    public init(
        contents: String,
        attributes: MoshTerminalTextAttributes = .default,
        hyperlink: MoshTerminalHyperlink? = nil
    ) {
        self.init(
            contents: contents,
            attributes: attributes,
            hyperlink: hyperlink,
            displayWidth: 1,
            isContinuation: false,
            isImplicitBlank: false,
            isFallback: false
        )
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
        self.isImplicitBlank = false
        self.isFallback = false
    }

    private init(
        contents: String,
        attributes: MoshTerminalTextAttributes,
        hyperlink: MoshTerminalHyperlink?,
        displayWidth: Int,
        isContinuation: Bool,
        isImplicitBlank: Bool,
        isFallback: Bool
    ) {
        self.contents = contents
        self.attributes = attributes
        self.hyperlink = hyperlink
        self.displayWidth = displayWidth
        self.isContinuation = isContinuation
        self.isImplicitBlank = isImplicitBlank
        self.isFallback = isFallback
    }

    public static func == (lhs: MoshTerminalCell, rhs: MoshTerminalCell) -> Bool {
        lhs.contents == rhs.contents
            && lhs.attributes == rhs.attributes
            && lhs.hyperlink == rhs.hyperlink
            && lhs.displayWidth == rhs.displayWidth
            && lhs.isContinuation == rhs.isContinuation
    }

    static func blank(
        attributes: MoshTerminalTextAttributes,
        hyperlink: MoshTerminalHyperlink? = nil
    ) -> MoshTerminalCell {
        MoshTerminalCell(
            contents: " ",
            attributes: attributes,
            hyperlink: hyperlink,
            displayWidth: 1,
            isContinuation: false,
            isImplicitBlank: true,
            isFallback: false
        )
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
            isContinuation: true,
            isImplicitBlank: false,
            isFallback: false
        )
    }

    func appending(_ scalar: Unicode.Scalar) -> MoshTerminalCell {
        guard self.isFull == false else {
            return self
        }

        return MoshTerminalCell(
            contents: self.contents + String(scalar),
            attributes: self.attributes,
            hyperlink: self.hyperlink,
            displayWidth: self.displayWidth,
            isContinuation: self.isContinuation,
            isImplicitBlank: false,
            isFallback: self.isFallback
        )
    }

    func appendingWithFallback(_ scalar: Unicode.Scalar) -> MoshTerminalCell {
        MoshTerminalCell(
            contents: "\u{00a0}" + String(scalar),
            attributes: self.attributes,
            hyperlink: self.hyperlink,
            displayWidth: 1,
            isContinuation: false,
            isImplicitBlank: false,
            isFallback: true
        )
    }

    private var isFull: Bool {
        self.officialStoredByteCount >= Self.maximumGraphemeByteCount
    }

    private var officialStoredByteCount: Int {
        guard self.isFallback,
              self.contents.unicodeScalars.first?.value == 0x00a0 else {
            return self.contents.utf8.count
        }

        return self.contents.utf8.count - String("\u{00a0}").utf8.count
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
        rows: [[MoshTerminalCell]]
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
    }

    public var lineStrings: [String] {
        self.rows.map { row in
            row.map(\.contents).joined()
        }
    }
}

public struct MoshTerminalScreen: Sendable {
    private static let maximumCSIParameterScalars = 100
    private static let maximumCSIIntermediateScalars = 8
    private static let maximumEscapeIntermediateScalars = 8
    private static let maximumCSIParameterValue = 65_535
    private static let maximumStringControlPayloadScalars = 16 * 1024
    private static let maximumOSCTitleScalars = 256
    private static let primaryDeviceAttributesReply = Array("\u{1b}[?62c".utf8)
    private static let secondaryDeviceAttributesReply = Array("\u{1b}[>1;10;0c".utf8)
    private static let deviceStatusOKReply = Array("\u{1b}[0n".utf8)

    public private(set) var dimensions: MoshTerminalDimensions
    public private(set) var cursor: MoshTerminalCursor

    private var parser: MoshTerminalInputParser
    private var rows: [[MoshTerminalCell]]
    private var activeGraphemeCursor: MoshTerminalCursor?
    private var scrollRegion: MoshTerminalScrollRegion
    private var currentAttributes: MoshTerminalTextAttributes
    private var normalSavedCursorState: MoshTerminalSavedCursorState?
    private var escapeState: EscapeState?
    private var wrapPending: Bool
    private var tabStops: Set<Int>
    private var defaultTabStopsEnabled: Bool
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
    private var terminalToHostBytes: [UInt8]

    public init(dimensions: MoshTerminalDimensions) {
        self.dimensions = dimensions
        self.cursor = MoshTerminalCursor(row: 0, column: 0)
        self.parser = MoshTerminalInputParser()
        self.rows = Self.blankRows(dimensions: dimensions)
        self.activeGraphemeCursor = self.cursor
        self.scrollRegion = .full(rowCount: Int(dimensions.rows))
        self.currentAttributes = .default
        self.normalSavedCursorState = nil
        self.escapeState = nil
        self.wrapPending = false
        self.tabStops = Self.defaultTabStops(columnCount: Int(dimensions.columns))
        self.defaultTabStopsEnabled = true
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
        self.terminalToHostBytes = []
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
            rows: self.rows
        )
    }

    @discardableResult
    public mutating func apply(_ operation: MoshTerminalRenderOperation) throws -> [UInt8] {
        switch operation {
        case .write(let output):
            return try self.apply(output)
        case .resize(let dimensions):
            self.resize(dimensions)
            return self.drainTerminalToHostBytes()
        }
    }

    @discardableResult
    public mutating func apply(_ operations: [MoshTerminalRenderOperation]) throws -> [UInt8] {
        var terminalToHostBytes: [UInt8] = []
        for operation in operations {
            terminalToHostBytes.append(contentsOf: try self.apply(operation))
        }
        return terminalToHostBytes
    }

    @discardableResult
    public mutating func apply(_ output: MoshTerminalOutput) throws -> [UInt8] {
        let tokens = try self.parser.parse(output.bytes)
        for token in tokens {
            self.applyToken(token)
        }
        return self.drainTerminalToHostBytes()
    }

    @discardableResult
    public mutating func apply(_ token: MoshTerminalInputToken) -> [UInt8] {
        self.applyToken(token)
        return self.drainTerminalToHostBytes()
    }

    private mutating func applyToken(_ token: MoshTerminalInputToken) {
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

    private mutating func appendTerminalToHostBytes(_ bytes: [UInt8]) {
        self.terminalToHostBytes.append(contentsOf: bytes)
    }

    private mutating func drainTerminalToHostBytes() -> [UInt8] {
        defer {
            self.terminalToHostBytes.removeAll(keepingCapacity: true)
        }
        return self.terminalToHostBytes
    }

    public mutating func finishPendingInput() throws {
        try self.parser.finish()
    }

    public mutating func resize(_ dimensions: MoshTerminalDimensions) {
        let oldColumnCount = self.maximumColumn + 1
        self.dimensions = dimensions
        self.rows = self.resizedRows(self.rows, dimensions: dimensions)
        self.cursor = Self.clampedCursor(
            self.cursor,
            maximumRow: self.maximumRow,
            maximumColumn: self.maximumColumn
        )
        if let activeGraphemeCursor,
           self.rows.indices.contains(activeGraphemeCursor.row),
           self.rows[activeGraphemeCursor.row].indices.contains(activeGraphemeCursor.column) {
            self.activeGraphemeCursor = activeGraphemeCursor
        } else {
            self.activeGraphemeCursor = nil
        }
        self.scrollRegion = .full(rowCount: self.rows.count)
        // Official Mosh preserves next_print_will_wrap across framebuffer resize.
        self.tabStops = self.tabStops.filter { $0 <= self.maximumColumn }
        if self.defaultTabStopsEnabled, oldColumnCount <= self.maximumColumn {
            for column in oldColumnCount...self.maximumColumn where column % 8 == 0 {
                self.tabStops.insert(column)
            }
        }
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
        self.maximumColumn
    }

    private var erasureAttributes: MoshTerminalTextAttributes {
        MoshTerminalTextAttributes(backgroundColor: self.currentAttributes.backgroundColor)
    }

    private var erasureCell: MoshTerminalCell {
        MoshTerminalCell.blank(attributes: self.erasureAttributes)
    }

    private mutating func apply(_ control: MoshTerminalControl) {
        switch control {
        case .null:
            self.wrapPending = false
        case .bell:
            self.wrapPending = false
            self.bellCount += 1
        case .backspace:
            self.wrapPending = false
            let column = self.previousCursorColumn()
            self.cursor = MoshTerminalCursor(
                row: self.cursor.row,
                column: column
            )
            self.markActiveGraphemeAtCursor()
        case .horizontalTab:
            self.moveForwardTabStops(count: 1, preservingPendingWrap: true)
        case .lineFeed:
            self.wrapPending = false
            self.index()
        case .carriageReturn:
            self.wrapPending = false
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
            self.markActiveGraphemeAtCursor()
        case .escape:
            self.escapeState = .escape
        case .delete:
            break
        case .c0(let byte):
            switch byte {
            case 0x0b, 0x0c:
                self.wrapPending = false
                self.index()
            case 0x18, 0x1a:
                self.wrapPending = false
            default:
                if Self.isC0PrimeControl(byte) {
                    self.wrapPending = false
                }
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
                self.markActiveGraphemeAtCursor()
                self.index()
            case 0x8d:
                self.wrapPending = false
                self.reverseIndex()
            case 0x90:
                self.escapeState = .stringControl(StringControlState(kind: .deviceControl))
            case 0x98:
                self.escapeState = .stringControl(StringControlState(kind: .startOfString))
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
                if Self.isExecuteAndGroundC1(byte) {
                    self.wrapPending = false
                }
                break
            }
        }
    }

    private mutating func place(_ rawScalar: Unicode.Scalar) {
        let scalarWidth = MoshTerminalCharacterWidth.width(of: rawScalar)
        if scalarWidth == .zero {
            self.appendZeroWidthScalar(rawScalar)
            return
        }

        if self.appendGraphemeClusterContinuation(rawScalar, width: scalarWidth) {
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
            scalar: rawScalar,
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

        self.activeGraphemeCursor = self.cursor
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

    private mutating func markActiveGraphemeAtCursor() {
        self.activeGraphemeCursor = self.cursor
    }

    private mutating func advanceCursorAfterImplicitPrint(width: Int) {
        self.activeGraphemeCursor = self.cursor
        let targetColumn = self.cursor.column + width
        if targetColumn >= self.currentMaximumColumn + 1 {
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: self.currentMaximumColumn)
            self.wrapPending = true
        } else {
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: targetColumn)
            self.wrapPending = false
        }
    }

    private mutating func appendZeroWidthScalar(_ scalar: Unicode.Scalar) {
        guard let target = self.activeGraphemeCursor,
              self.rows.indices.contains(target.row),
              self.rows[target.row].indices.contains(target.column) else {
            return
        }

        let column = self.leadingColumn(row: target.row, column: target.column)
        if self.rows[target.row][column].isImplicitBlank {
            self.rows[target.row][column] = self.rows[target.row][column].appendingWithFallback(scalar)
            self.advanceCursorAfterImplicitPrint(width: 1)
        } else {
            self.rows[target.row][column] = self.rows[target.row][column].appending(scalar)
        }
    }

    private mutating func appendGraphemeClusterContinuation(
        _ scalar: Unicode.Scalar,
        width: MoshTerminalScalarWidth
    ) -> Bool {
        guard width == .wide,
              let position = self.activeGraphemeCellPosition(),
              self.rows[position.row][position.column].contents.unicodeScalars.last?.value == 0x200d else {
            return false
        }

        self.rows[position.row][position.column] = self.rows[position.row][position.column].appending(scalar)
        return true
    }

    private func activeGraphemeCellPosition() -> MoshTerminalCursor? {
        guard let target = self.activeGraphemeCursor,
              self.rows.indices.contains(target.row),
              self.rows[target.row].indices.contains(target.column) else {
            return nil
        }

        return MoshTerminalCursor(
            row: target.row,
            column: self.leadingColumn(row: target.row, column: target.column)
        )
    }

    private mutating func clearCellForWrite(row: Int, column: Int) {
        guard self.rows.indices.contains(row),
              self.rows[row].indices.contains(column) else {
            return
        }

        let leadingColumn = self.leadingColumn(row: row, column: column)
        let displayWidth = max(self.rows[row][leadingColumn].displayWidth, 1)
        for clearedColumn in leadingColumn..<min(leadingColumn + displayWidth, self.rows[row].count) {
            self.rows[row][clearedColumn] = self.erasureCell
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
        self.markActiveGraphemeAtCursor()
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
        self.markActiveGraphemeAtCursor()
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
            + self.blankRows(rowCount: amount)
        self.replaceRows(in: region.range, with: replacement)
    }

    private mutating func scrollRowsDown(count: Int, region: MoshTerminalScrollRegion) {
        let amount = min(max(count, 0), region.height)
        guard amount > 0 else {
            return
        }

        let activeRows = Array(self.rows[region.range])
        let replacement = self.blankRows(rowCount: amount)
            + Array(activeRows.dropLast(amount))
        self.replaceRows(in: region.range, with: replacement)
    }

    private mutating func insertLines(count: Int) {
        defer {
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
            self.markActiveGraphemeAtCursor()
            self.wrapPending = false
        }

        guard self.scrollRegion.contains(row: self.cursor.row) else {
            return
        }

        let amount = min(max(count, 0), self.scrollRegion.bottom - self.cursor.row + 1)
        guard amount > 0 else {
            return
        }

        let range = self.cursor.row...self.scrollRegion.bottom
        let activeRows = Array(self.rows[range])
        let replacement = self.blankRows(rowCount: amount)
            + Array(activeRows.dropLast(amount))
        self.replaceRows(in: range, with: replacement)
    }

    private mutating func deleteLines(count: Int) {
        defer {
            self.cursor = MoshTerminalCursor(row: self.cursor.row, column: 0)
            self.markActiveGraphemeAtCursor()
            self.wrapPending = false
        }

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
            + self.blankRows(rowCount: amount)
        self.replaceRows(in: range, with: replacement)
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
            row[column] = self.erasureCell
        }
        Self.normalizeContinuations(in: &row, replacementCell: self.erasureCell)
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
            row[column] = self.erasureCell
        }
        Self.normalizeContinuations(in: &row, replacementCell: self.erasureCell)
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
            self.wrapPending = false
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

        self.cursor = Self.clampedCursor(
            savedCursorState.cursor,
            maximumRow: self.maximumRow,
            maximumColumn: self.maximumColumn
        )
        self.markActiveGraphemeAtCursor()
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
            self.homeCursor()
            self.originMode = enabled
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
        self.rows = self.blankRows(dimensions: self.dimensions)
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

        switch state {
        case .escape:
            self.consumeEscapeEntryToken(token)
        case .escapeIntermediate(let intermediates):
            self.consumeEscapeIntermediateToken(token, intermediates: intermediates)
        case .csi(let csiState):
            switch token {
            case .scalar(let scalar):
                self.consumeCSI(scalar: scalar, state: csiState)
            case .control(let control):
                self.consumeCSIControl(control)
            }
        case .stringControl(let stringState):
            self.consumeStringControl(token: token, state: stringState)
        }
    }

    private mutating func consumeEscapeEntryToken(_ token: MoshTerminalInputToken) {
        switch token {
        case .scalar(let scalar):
            self.consumeEscapeEntryScalar(scalar)
        case .control(let control):
            self.consumeEscapeControl(control, continuing: .escape)
        }
    }

    private mutating func consumeEscapeEntryScalar(_ scalar: Unicode.Scalar) {
        guard let byte = UInt8(exactly: scalar.value) else {
            self.wrapPending = false
            self.escapeState = nil
            return
        }

        switch byte {
        case 0x20...0x2f:
            self.escapeState = .escapeIntermediate(String(scalar))
        case 0x5b:
            self.escapeState = .csi(CSIState())
        case 0x50:
            self.escapeState = .stringControl(StringControlState(kind: .deviceControl))
        case 0x58:
            self.escapeState = .stringControl(StringControlState(kind: .startOfString))
        case 0x5d:
            self.escapeState = .stringControl(StringControlState(kind: .operatingSystemCommand))
        case 0x5e:
            self.escapeState = .stringControl(StringControlState(kind: .privacyMessage))
        case 0x5f:
            self.escapeState = .stringControl(StringControlState(kind: .applicationProgramCommand))
        case 0x30...0x4f, 0x51...0x57, 0x59, 0x5a, 0x5c, 0x60...0x7e:
            self.dispatchEscape(finalByte: byte, intermediates: "")
        default:
            self.wrapPending = false
            self.escapeState = nil
        }
    }

    private mutating func consumeEscapeIntermediateToken(
        _ token: MoshTerminalInputToken,
        intermediates: String
    ) {
        switch token {
        case .scalar(let scalar):
            if Self.isHighUnicodeParserScalar(scalar) {
                self.wrapPending = false
                self.escapeState = nil
                return
            }

            guard let byte = UInt8(exactly: scalar.value) else {
                self.escapeState = .escapeIntermediate(intermediates)
                return
            }

            if (0x20...0x2f).contains(byte) {
                var nextIntermediates = intermediates
                if nextIntermediates.unicodeScalars.count < Self.maximumEscapeIntermediateScalars {
                    nextIntermediates.unicodeScalars.append(scalar)
                }
                self.escapeState = .escapeIntermediate(nextIntermediates)
            } else if (0x30...0x7e).contains(byte) {
                self.dispatchEscape(finalByte: byte, intermediates: intermediates)
            } else {
                self.escapeState = .escapeIntermediate(intermediates)
            }
        case .control(let control):
            self.consumeEscapeControl(control, continuing: .escapeIntermediate(intermediates))
        }
    }

    private mutating func consumeEscapeControl(_ control: MoshTerminalControl, continuing state: EscapeState) {
        switch control {
        case .escape:
            self.escapeState = .escape
        case .bell, .backspace, .horizontalTab, .lineFeed, .carriageReturn:
            self.apply(control)
            self.escapeState = state
        case .null:
            self.wrapPending = false
            self.escapeState = state
        case .c0(let byte):
            if byte == 0x18 || byte == 0x1a {
                self.wrapPending = false
                self.escapeState = nil
            } else if Self.isC0PrimeControl(byte) {
                self.apply(control)
                if byte != 0x0e, byte != 0x0f {
                    self.wrapPending = false
                }
                self.escapeState = state
            }
        case .c1(let byte):
            self.consumeCSIAnywhereC1(byte)
        case .delete:
            self.escapeState = state
        }
    }

    private mutating func dispatchEscape(finalByte byte: UInt8, intermediates: String) {
        if intermediates.isEmpty {
            if self.dispatchBareEscapedC1(finalByte: byte) {
                return
            }

            switch byte {
            case UInt8(ascii: "7"):
                self.wrapPending = false
                self.saveCursorState()
            case UInt8(ascii: "8"):
                self.wrapPending = false
                self.restoreCursorState()
            case UInt8(ascii: "c"):
                self.reset()
                return
            default:
                self.wrapPending = false
            }
            self.escapeState = nil
            return
        }

        if intermediates == "#", byte == UInt8(ascii: "8") {
            self.screenAlignmentTest()
            self.escapeState = nil
            return
        }

        self.wrapPending = false
        self.escapeState = nil
    }

    private mutating func dispatchBareEscapedC1(finalByte byte: UInt8) -> Bool {
        guard (0x40...0x5f).contains(byte) else {
            return false
        }

        let controlByte = byte + 0x40
        switch controlByte {
        case 0x84, 0x85, 0x88, 0x8d:
            self.apply(.c1(controlByte))
        default:
            self.wrapPending = false
        }
        self.escapeState = nil
        return true
    }

    private mutating func screenAlignmentTest() {
        self.rows = self.alignmentRows(dimensions: self.dimensions)
        self.wrapPending = false
    }

    private mutating func consumeStringControl(
        token: MoshTerminalInputToken,
        state: StringControlState
    ) {
        if self.consumeStringControlAnywhere(token: token, state: state) {
            return
        }

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

    private mutating func consumeStringControlAnywhere(
        token: MoshTerminalInputToken,
        state: StringControlState
    ) -> Bool {
        switch token {
        case .control(.escape):
            self.finishStringControl(state)
            self.escapeState = .escape
            return true
        case .control(.c0(let byte)) where byte == 0x18 || byte == 0x1a:
            self.finishStringControl(state)
            self.wrapPending = false
            self.escapeState = nil
            return true
        case .control(.c1(let byte)):
            self.finishStringControl(state)
            return self.consumeStringControlAnywhereC1(byte)
        default:
            return false
        }
    }

    private mutating func consumeStringControlAnywhereC1(_ byte: UInt8) -> Bool {
        if Self.isExecuteAndGroundC1(byte) {
            self.apply(.c1(byte))
            self.escapeState = nil
            return true
        }

        switch byte {
        case 0x90:
            self.escapeState = .stringControl(StringControlState(kind: .deviceControl))
        case 0x98:
            self.escapeState = .stringControl(StringControlState(kind: .startOfString))
        case 0x9b:
            self.escapeState = .csi(CSIState())
        case 0x9c:
            self.escapeState = nil
        case 0x9d:
            self.escapeState = .stringControl(StringControlState(kind: .operatingSystemCommand))
        case 0x9e:
            self.escapeState = .stringControl(StringControlState(kind: .privacyMessage))
        case 0x9f:
            self.escapeState = .stringControl(StringControlState(kind: .applicationProgramCommand))
        default:
            return false
        }
        return true
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
              state.payload.unicodeScalars.count < Self.maximumStringControlPayloadScalars else {
            return state
        }

        let payloadScalar: Unicode.Scalar
        switch token {
        case .scalar(let scalar):
            payloadScalar = scalar
        case .control(.delete):
            payloadScalar = Unicode.Scalar(0x7f)!
        default:
            return state
        }

        var nextState = state
        nextState.payload.unicodeScalars.append(payloadScalar)
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
        if Self.isHighUnicodeParserScalar(scalar) {
            if state.isIgnoring == false {
                self.wrapPending = false
            }
            self.escapeState = nil
            return
        }

        guard let byte = UInt8(exactly: scalar.value) else {
            self.escapeState = nil
            return
        }

        if state.isIgnoring {
            self.escapeState = (0x40...0x7e).contains(byte) ? nil : .csi(state)
            return
        }

        if byte == 0x3a {
            self.escapeState = .csi(state.ignoring())
            return
        }

        if (0x30...0x39).contains(byte) || byte == 0x3b {
            guard state.intermediates.isEmpty else {
                self.escapeState = .csi(state.ignoring())
                return
            }
            var nextState = state
            if nextState.parameters.count < Self.maximumCSIParameterScalars {
                nextState.parameters += String(scalar)
            }
            self.escapeState = .csi(nextState)
            return
        }

        if (0x3c...0x3f).contains(byte) {
            guard state.parameters.isEmpty, state.intermediates.isEmpty else {
                self.escapeState = .csi(state.ignoring())
                return
            }
            var nextState = state
            if nextState.parameters.count < Self.maximumCSIParameterScalars {
                nextState.parameters += String(scalar)
            }
            self.escapeState = .csi(nextState)
            return
        }

        if (0x20...0x2f).contains(byte) {
            var nextState = state
            if nextState.intermediates.count < Self.maximumCSIIntermediateScalars {
                nextState.intermediates += String(scalar)
            }
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

    private mutating func consumeCSIControl(_ control: MoshTerminalControl) {
        switch control {
        case .escape:
            self.escapeState = .escape
        case .bell, .backspace, .horizontalTab, .lineFeed, .carriageReturn:
            self.apply(control)
        case .null:
            self.wrapPending = false
        case .c0(let byte):
            if byte == 0x18 || byte == 0x1a {
                self.wrapPending = false
                self.escapeState = nil
            } else if Self.isExecutableC0InCSI(byte) {
                self.wrapPending = false
            }
        case .c1(let byte):
            self.consumeCSIAnywhereC1(byte)
        case .delete:
            break
        }
    }

    private mutating func consumeCSIAnywhereC1(_ byte: UInt8) {
        if Self.isExecuteAndGroundC1(byte) {
            let before = self.wrapPending
            self.apply(.c1(byte))
            if before == self.wrapPending {
                self.wrapPending = false
            }
            self.escapeState = nil
            return
        }

        switch byte {
        case 0x90:
            self.escapeState = .stringControl(StringControlState(kind: .deviceControl))
        case 0x98:
            self.escapeState = .stringControl(StringControlState(kind: .startOfString))
        case 0x9b:
            self.escapeState = .csi(CSIState())
        case 0x9c:
            self.escapeState = nil
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
        let privateDispatchPrefix = Self.csiPrivateDispatchPrefix(parameters)
        let isDECPrivate = privateDispatchPrefix == "?"

        if let privateDispatchPrefix,
           Self.isRegisteredPrivateCSIDispatch(prefix: privateDispatchPrefix, finalByte: finalByte) == false {
            self.wrapPending = false
            return
        }

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
        case UInt8(ascii: "c"):
            self.reportDeviceAttributes(parameters: parameters)
        case UInt8(ascii: "d"):
            self.setPositionedCursor(
                row: Self.parameter(values, at: 0, default: 1) - 1,
                column: self.cursor.column
            )
        case UInt8(ascii: "g"):
            self.clearTabStops(
                mode: Self.parameter(values, at: 0, default: 0),
                preservingPendingWrap: true
            )
        case UInt8(ascii: "h"):
            if isDECPrivate {
                values.compactMap { $0 }.forEach { self.setPrivateMode($0, enabled: true) }
            } else {
                values.compactMap { $0 }.forEach { self.setMode($0, enabled: true) }
                self.wrapPending = false
            }
        case UInt8(ascii: "l"):
            if isDECPrivate {
                values.compactMap { $0 }.forEach { self.setPrivateMode($0, enabled: false) }
            } else {
                values.compactMap { $0 }.forEach { self.setMode($0, enabled: false) }
                self.wrapPending = false
            }
        case UInt8(ascii: "m"):
            self.applySGR(parameters: values)
        case UInt8(ascii: "n"):
            self.reportDeviceStatus(parameters: parameters, values: values)
        case UInt8(ascii: "r"):
            self.setScrollRegion(parameters: values)
        default:
            self.wrapPending = false
            break
        }
    }

    private mutating func reset() {
        self.rows = Self.blankRows(dimensions: self.dimensions)
        self.cursor = MoshTerminalCursor(row: 0, column: 0)
        self.activeGraphemeCursor = self.cursor
        self.scrollRegion = .full(rowCount: self.rows.count)
        self.currentAttributes = .default
        self.normalSavedCursorState = nil
        self.escapeState = nil
        self.wrapPending = false
        self.tabStops = Self.defaultTabStops(columnCount: Int(self.dimensions.columns))
        self.defaultTabStopsEnabled = true
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
    }

    private mutating func reportDeviceAttributes(parameters: String) {
        self.wrapPending = false
        if parameters.first == ">" {
            self.appendTerminalToHostBytes(Self.secondaryDeviceAttributesReply)
        } else if Self.hasPrivateCSIParameterPrefix(parameters) == false {
            self.appendTerminalToHostBytes(Self.primaryDeviceAttributesReply)
        }
    }

    private mutating func reportDeviceStatus(parameters: String, values: [Int?]) {
        self.wrapPending = false
        guard Self.hasPrivateCSIParameterPrefix(parameters) == false else {
            return
        }

        switch Self.parameter(values, at: 0, default: 0) {
        case 5:
            self.appendTerminalToHostBytes(Self.deviceStatusOKReply)
        case 6:
            self.appendTerminalToHostBytes(
                Array("\u{1b}[\(self.cursor.row + 1);\(self.cursor.column + 1)R".utf8)
            )
        default:
            break
        }
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
            column: min(max(self.cursor.column + columnDelta, 0), self.maximumColumn)
        )
        self.markActiveGraphemeAtCursor()
        self.wrapPending = false
    }

    private mutating func setCursor(row: Int, column: Int) {
        let targetRow = min(max(row, 0), self.maximumRow)
        self.cursor = MoshTerminalCursor(
            row: targetRow,
            column: min(max(column, 0), self.maximumColumn)
        )
        self.markActiveGraphemeAtCursor()
        self.wrapPending = false
    }

    private mutating func setPositionedCursor(row: Int, column: Int) {
        let rowBounds = self.absoluteCursorRowBounds
        let absoluteRow = self.originMode ? self.scrollRegion.top + row : row
        let targetRow = min(max(absoluteRow, rowBounds.lowerBound), rowBounds.upperBound)
        self.cursor = MoshTerminalCursor(
            row: targetRow,
            column: min(max(column, 0), self.maximumColumn)
        )
        self.markActiveGraphemeAtCursor()
        self.wrapPending = false
    }

    private mutating func homeCursor() {
        self.cursor = MoshTerminalCursor(
            row: self.originMode ? self.scrollRegion.top : 0,
            column: 0
        )
        self.markActiveGraphemeAtCursor()
        self.wrapPending = false
    }

    private var absoluteCursorRowBounds: ClosedRange<Int> {
        if self.originMode {
            return self.scrollRegion.range
        }
        return 0...self.maximumRow
    }

    private var relativeCursorRowBounds: ClosedRange<Int> {
        if self.originMode {
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
            self.defaultTabStopsEnabled = false
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
            self.rows = self.blankRows(dimensions: self.dimensions)
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
                    if let color = result.color {
                        self.currentAttributes.foregroundColor = color
                    }
                    index = result.nextIndex
                    continue
                }
            case 48:
                if let result = Self.extendedColor(values: values, startIndex: index + 1) {
                    if let color = result.color {
                        self.currentAttributes.backgroundColor = color
                    }
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

    private static func indexedColor(_ index: UInt8) -> MoshTerminalColor {
        switch index {
        case 0...7:
            return Self.ansiColor(code: Int(index), isBright: false) ?? .indexed(index)
        case 8...15:
            return Self.ansiColor(code: Int(index) - 8, isBright: true) ?? .indexed(index)
        default:
            return .indexed(index)
        }
    }

    private static func extendedColor(
        values: [Int],
        startIndex: Int
    ) -> (color: MoshTerminalColor?, nextIndex: Int)? {
        guard startIndex < values.count else {
            return nil
        }

        switch values[startIndex] {
        case 5:
            guard startIndex + 1 < values.count else {
                return nil
            }
            guard let index = UInt8(exactly: values[startIndex + 1]) else {
                return (nil, startIndex + 2)
            }
            return (Self.indexedColor(index), startIndex + 2)
        case 2:
            guard startIndex + 3 < values.count else {
                return nil
            }
            let color = Self.trueColor(
                red: values[startIndex + 1],
                green: values[startIndex + 2],
                blue: values[startIndex + 3]
            )
            return (color, startIndex + 4)
        default:
            return nil
        }
    }

    private static func trueColor(red: Int, green: Int, blue: Int) -> MoshTerminalColor {
        // Official Mosh packs unmasked RGB parameters into a 25-bit rendition field.
        let trueColorMask = 0x01_00_00_00
        let storageMask = 0x01_ff_ff_ff
        let packed = (trueColorMask | (red << 16) | (green << 8) | blue) & storageMask
        return .rgb(
            red: UInt8(truncatingIfNeeded: packed >> 16),
            green: UInt8(truncatingIfNeeded: packed >> 8),
            blue: UInt8(truncatingIfNeeded: packed)
        )
    }

    private static func parseCSIParameters(_ parameters: String) -> [Int?] {
        let normalized = parameters.first == "?" ? parameters.dropFirst() : Substring(parameters)
        return normalized.split(separator: ";", omittingEmptySubsequences: false).map { field in
            guard field.isEmpty == false,
                  let value = Int(field),
                  value <= Self.maximumCSIParameterValue else {
                return nil
            }
            return value
        }
    }

    private static func hasPrivateCSIParameterPrefix(_ parameters: String) -> Bool {
        Self.csiPrivateDispatchPrefix(parameters) != nil
    }

    private static func csiPrivateDispatchPrefix(_ parameters: String) -> Character? {
        guard let first = parameters.first, "?<=>".contains(first) else {
            return nil
        }
        return first
    }

    private static func isRegisteredPrivateCSIDispatch(prefix: Character, finalByte: UInt8) -> Bool {
        switch (prefix, finalByte) {
        case ("?", UInt8(ascii: "h")), ("?", UInt8(ascii: "l")):
            true
        case (">", UInt8(ascii: "c")):
            true
        default:
            false
        }
    }

    private static func isExecutableC0InCSI(_ byte: UInt8) -> Bool {
        Self.isC0PrimeControl(byte)
    }

    private static func isC0PrimeControl(_ byte: UInt8) -> Bool {
        byte <= 0x17 || byte == 0x19 || (0x1c...0x1f).contains(byte)
    }

    private static func isExecuteAndGroundC1(_ byte: UInt8) -> Bool {
        (0x80...0x8f).contains(byte)
            || (0x91...0x97).contains(byte)
            || byte == 0x99
            || byte == 0x9a
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

    private static func isHighUnicodeParserScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0xa0
    }

    private static func string<C: Collection>(from scalars: C) -> String where C.Element == Unicode.Scalar {
        var string = ""
        for scalar in scalars {
            string.unicodeScalars.append(scalar)
        }
        return string
    }

    fileprivate static func blankRows(dimensions: MoshTerminalDimensions) -> [[MoshTerminalCell]] {
        self.blankRows(rowCount: Int(dimensions.rows), columnCount: Int(dimensions.columns), cell: .blank)
    }

    fileprivate static func blankRows(rowCount: Int, columnCount: Int) -> [[MoshTerminalCell]] {
        self.blankRows(rowCount: rowCount, columnCount: columnCount, cell: .blank)
    }

    private static func blankRows(
        rowCount: Int,
        columnCount: Int,
        cell: MoshTerminalCell
    ) -> [[MoshTerminalCell]] {
        return (0..<rowCount).map { _ in
            self.blankRow(columnCount: columnCount, cell: cell)
        }
    }

    private func blankRows(dimensions: MoshTerminalDimensions) -> [[MoshTerminalCell]] {
        Self.blankRows(
            rowCount: Int(dimensions.rows),
            columnCount: Int(dimensions.columns),
            cell: self.erasureCell
        )
    }

    private func blankRows(rowCount: Int) -> [[MoshTerminalCell]] {
        Self.blankRows(
            rowCount: rowCount,
            columnCount: self.maximumColumn + 1,
            cell: self.erasureCell
        )
    }

    private func alignmentRows(dimensions: MoshTerminalDimensions) -> [[MoshTerminalCell]] {
        let cell = MoshTerminalCell(
            scalar: "E",
            attributes: self.erasureAttributes,
            hyperlink: nil,
            displayWidth: 1
        )
        return (0..<Int(dimensions.rows)).map { _ in
            Array(repeating: cell, count: Int(dimensions.columns))
        }
    }

    fileprivate static func blankRow(columnCount: Int) -> [MoshTerminalCell] {
        self.blankRow(columnCount: columnCount, cell: .blank)
    }

    private static func blankRow(columnCount: Int, cell: MoshTerminalCell) -> [MoshTerminalCell] {
        Array(repeating: cell, count: columnCount)
    }

    private static func defaultTabStops(columnCount: Int) -> Set<Int> {
        guard columnCount > 0 else {
            return []
        }
        return Set(stride(from: 8, to: columnCount, by: 8))
    }

    fileprivate func resizedRows(
        _ oldRows: [[MoshTerminalCell]],
        dimensions: MoshTerminalDimensions
    ) -> [[MoshTerminalCell]] {
        var newRows = self.blankRows(dimensions: dimensions)
        let copiedRows = min(oldRows.count, newRows.count)
        let copiedColumns = min(oldRows.first?.count ?? 0, newRows.first?.count ?? 0)

        for row in 0..<copiedRows {
            for column in 0..<copiedColumns {
                newRows[row][column] = oldRows[row][column]
            }
        }

        for row in newRows.indices {
            Self.normalizeContinuations(in: &newRows[row], replacementCell: self.erasureCell)
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

    private static func normalizeContinuations(
        in row: inout [MoshTerminalCell],
        replacementCell: MoshTerminalCell
    ) {
        for column in row.indices {
            if row[column].isContinuation {
                if column == 0 || row[column - 1].displayWidth < 2 {
                    row[column] = replacementCell
                }
                continue
            }

            guard row[column].displayWidth > 1 else {
                continue
            }

            if column + row[column].displayWidth > row.count {
                row[column] = replacementCell
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
    case escapeIntermediate(String)
    case stringControl(StringControlState)
}

private struct CSIState: Equatable, Sendable {
    var parameters: String = ""
    var intermediates: String = ""
    var isIgnoring = false

    func ignoring() -> CSIState {
        var nextState = self
        nextState.isIgnoring = true
        return nextState
    }
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
