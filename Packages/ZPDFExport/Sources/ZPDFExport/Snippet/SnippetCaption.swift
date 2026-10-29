import Foundation
import ZPDFContracts

/// The caption band's content: finished lines, ready to draw or to paste as plain text.
public struct SnippetCaption: Sendable, Hashable {
    public let lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }

    public var text: String { lines.joined(separator: "\n") }
    public var isEmpty: Bool { lines.isEmpty }

    public static let empty = SnippetCaption(lines: [])
}

/// Knobs the caption honours. None of them touch a number.
public struct SnippetCaptionOptions: Sendable, Hashable {
    /// The column whose value the caption quotes, by key. `nil` lets
    /// ``SnippetCaptionBuilder/quantityIndex(row:columns:)`` choose each row's headline
    /// quantity — see that method for why "the first numeric column" is the wrong rule.
    public var valueColumnKey: String?
    /// `.full` prints this as the calibration source ("Calibrated from title block", "Page
    /// scale 1:100"). The ledger does not know it; the document layer does.
    public var calibrationDescription: String?
    /// At most this many value lines; further markups are summarised as a count.
    public var maximumValueLines: Int

    public init(
        valueColumnKey: String? = nil,
        calibrationDescription: String? = nil,
        maximumValueLines: Int = 6
    ) {
        self.valueColumnKey = valueColumnKey
        self.calibrationDescription = calibrationDescription
        self.maximumValueLines = maximumValueLines
    }
}

/// Builds the caption from the same ``ExportProjection`` every other exporter reads.
///
/// This is the load-bearing decision of ADR-0006 §2: the caption's digits are
/// ``ExportCell/text`` — the string the CSV writes, the XLSX formats to, the PDF report
/// prints. There is no second formatting path, no re-rounding and no `Double` in sight, so a
/// snippet **cannot** disagree with the ledger; the digit-for-digit test demonstrates the
/// property rather than establishing it.
public enum SnippetCaptionBuilder {

    public static func build(
        detail: SnippetCaptionDetail,
        markupIDs: [MarkupID],
        projection: ExportProjection,
        source: SnippetSource,
        options: SnippetCaptionOptions = SnippetCaptionOptions()
    ) -> SnippetCaption {
        guard detail != .none else { return .empty }

        let table = projection.table
        let columns = table.columns
        let subjectIndex = columns.firstIndex { $0.key == StandardLedgerColumn.subject.rawValue }
        let labelIndex = columns.firstIndex { $0.key == StandardLedgerColumn.label.rawValue }
        let planAreaIndex = columns.firstIndex { $0.key == StandardLedgerColumn.planArea.rawValue }
        let trueAreaIndex = columns.firstIndex { $0.key == StandardLedgerColumn.trueArea.rawValue }
        let forcedValueIndex = options.valueColumnKey.flatMap { key in
            columns.firstIndex { $0.key == key }
        }

        let wanted = markupIDs.map { $0.rawValue.uuidString }
        var rowsByID: [String: ExportRow] = [:]
        for row in table.allRows() where rowsByID[row.markupID] == nil {
            rowsByID[row.markupID] = row
        }

        var lines: [String] = []
        var shown = 0
        var missing = 0
        for id in wanted {
            guard let row = rowsByID[id] else {
                missing += 1
                continue
            }
            if shown >= Swift.max(1, options.maximumValueLines) {
                shown += 1
                continue
            }
            lines.append(valueLine(
                row: row,
                columns: columns,
                subjectIndex: subjectIndex,
                labelIndex: labelIndex,
                forcedValueIndex: forcedValueIndex,
                planAreaIndex: planAreaIndex,
                trueAreaIndex: trueAreaIndex
            ))
            shown += 1
        }
        let overflow = shown - Swift.max(1, options.maximumValueLines)
        if overflow > 0 {
            lines.append("… and \(overflow) more measurement\(overflow == 1 ? "" : "s")")
        }
        if missing > 0 {
            // A named markup with no ledger row is said out loud, never papered over: the
            // picture may show it, but no number can be quoted for it.
            lines.append("\(missing) markup\(missing == 1 ? "" : "s") without a ledger row")
        }

        if detail == .full {
            lines.append(contentsOf: contextLines(
                projection: projection,
                source: source,
                options: options
            ))
        }
        return SnippetCaption(lines: lines)
    }

    // MARK: - Lines

    private static func valueLine(
        row: ExportRow,
        columns: [ExportColumn],
        subjectIndex: Int?,
        labelIndex: Int?,
        forcedValueIndex: Int?,
        planAreaIndex: Int? = nil,
        trueAreaIndex: Int? = nil
    ) -> String {
        var name: [String] = []
        if let labelIndex, labelIndex < row.cells.count {
            let label = row.cells[labelIndex].text
            if !label.isEmpty { name.append(label) }
        }
        if let subjectIndex, subjectIndex < row.cells.count {
            let subject = row.cells[subjectIndex].text
            if !subject.isEmpty { name.append(subject) }
        }

        var valueText: String?
        let valueIndex = forcedValueIndex ?? quantityIndex(row: row, columns: columns)
        // ADR-0004: a markup with a slope applied carries BOTH a plan area and a true area.
        // When the quoted value is one of them and the row holds numbers in both, the caption
        // must say which one it quotes — an unlabelled area under a slope reads as whichever
        // one the reader assumes, which is the silent wrongness the ADR forbids.
        var slopeLabel: String?
        if let planAreaIndex, let trueAreaIndex,
           let valueIndex, valueIndex == planAreaIndex || valueIndex == trueAreaIndex,
           planAreaIndex < row.cells.count, trueAreaIndex < row.cells.count,
           row.cells[planAreaIndex].number != nil, row.cells[trueAreaIndex].number != nil {
            slopeLabel = columns[valueIndex].title
        }
        if let valueIndex, valueIndex < row.cells.count, valueIndex < columns.count {
            let cell = row.cells[valueIndex]
            switch cell {
            case .number(let number):
                // The one unit-naming rule: a feet-and-inches spelling names its units already,
                // and used to read `3'-4 13/16" ft` (U-054).
                var text = number.textNamingUnit
                if let slopeLabel { text = "\(slopeLabel) \(text)" }
                valueText = text
            case .refusal(let token):
                valueText = token
            case .blank, .text, .date, .boolean:
                let text = cell.text
                valueText = text.isEmpty ? nil : text
            }
        }

        let identity = name.joined(separator: " · ")
        switch (identity.isEmpty, valueText) {
        case (false, .some(let value)): return "\(identity): \(value)"
        case (false, .none): return identity
        case (true, .some(let value)): return value
        case (true, .none): return "(no value)"
        }
    }

    /// The column whose number the caption quotes, when the caller has not named one.
    ///
    /// # Why this is a preference list and not "the first numeric column"
    ///
    /// It *was* "the first numeric column that holds a number", and on the golden export
    /// fixture that happened to be the measured value. In the application it is **`pageIndex`**:
    /// the standard ledger declares it as a number, it is column 5, and every measurement column
    /// is column 14 or later. So the first snippet ever taken through the application captioned
    /// a 20-metre wall as *"Length A · Length: 0 1"* — the page index, with the dimensionless SI
    /// unit symbol after it. A caption that states a wrong quantity is worse than no caption, and
    /// it is precisely the failure ADR-0006 §2 exists to prevent, so the choice is now explicit.
    ///
    /// The order is the headline quantity of each markup family, most specific first: a volume
    /// markup carries a plan area too and is not an area; an area markup carries a perimeter and
    /// is not a length. Below the named list, any column the contract says reads a
    /// ``ZPDFContracts/MeasurementField`` — that is what makes a number a *quantity* rather than
    /// an identifier that happens to be numeric — and only then, as a last resort, any number at
    /// all, so a project with a formula column and no standard quantity still says something.
    static func quantityIndex(row: ExportRow, columns: [ExportColumn]) -> Int? {
        func index(of column: StandardLedgerColumn) -> Int? {
            guard let index = columns.firstIndex(where: { $0.key == column.rawValue }),
                  index < row.cells.count, row.cells[index].number != nil
            else { return nil }
            return index
        }
        let preferred: [StandardLedgerColumn] = [
            .count, .volume, .planArea, .trueArea, .wallArea,
            .planLength, .trueLength, .perimeter,
            .height, .depth, .diameter, .radius, .rise, .run
        ]
        for column in preferred {
            if let found = index(of: column) { return found }
        }
        let measurement = row.cells.indices.first { index in
            guard index < columns.count, row.cells[index].number != nil else { return false }
            return StandardLedgerColumn(rawValue: columns[index].key)?.measurementField != nil
        }
        if let measurement { return measurement }
        return row.cells.indices.first { index in
            index < columns.count && columns[index].isNumeric && row.cells[index].number != nil
        }
    }

    private static func contextLines(
        projection: ExportProjection,
        source: SnippetSource,
        options: SnippetCaptionOptions
    ) -> [String] {
        let document = projection.table.metadata.document
        var lines: [String] = []
        var origin: [String] = []
        if let project = document.projectName, !project.isEmpty { origin.append(project) }
        let drawing = document.documentName ?? source.documentName
        if !drawing.isEmpty { origin.append(drawing) }
        if let pageLabel = source.pageLabel, !pageLabel.isEmpty {
            origin.append("page \(pageLabel)")
        } else {
            origin.append("page \(source.pageIndex + 1)")
        }
        if let revision = source.revision ?? document.revision, !revision.isEmpty {
            origin.append("rev \(revision)")
        }
        lines.append(origin.joined(separator: " · "))

        var scale: [String] = []
        if let description = document.scaleDescription, !description.isEmpty {
            scale.append("scale \(description)")
        }
        if let calibration = options.calibrationDescription, !calibration.isEmpty {
            scale.append(calibration)
        }
        if !scale.isEmpty { lines.append(scale.joined(separator: " · ")) }

        lines.append("exported \(projection.table.metadata.generatedAt.iso8601)")
        return lines
    }
}
