import Foundation

/// How the CSV is spelled. Everything here is about *syntax*; nothing here is about *values*,
/// because the values were finished by ``ExportProjector``.
public struct CSVExportOptions: Hashable, Sendable {

    public enum LineEnding: String, Hashable, Sendable {
        /// RFC 4180 §2.1: records are terminated by CRLF. The default, because it is the standard
        /// and because Excel on both platforms reads it.
        case crlf
        case lf

        var text: String { self == .crlf ? "\r\n" : "\n" }
    }

    public enum Quoting: Hashable, Sendable {
        /// Quote only fields that need it (RFC 4180 §2.6). Smallest file, still correct.
        case minimal
        /// Quote every field. Costs bytes; makes the file trivially machine-checkable.
        case all
    }

    /// What Excel does to a *text* field that starts with `=`, `+`, `-`, `@`, tab or CR: it
    /// evaluates it. `=1+1` becomes 2, and `=HYPERLINK(...)` becomes a click target.
    public enum FormulaInjectionGuard: Hashable, Sendable {
        /// Prefix the field with an apostrophe, which Excel eats and treats the rest as text.
        case apostrophe
        /// Leave the field exactly as it is. Correct for a pipeline that is not a spreadsheet,
        /// and a hazard for one that is.
        case none
    }

    public var delimiter: Character
    public var lineEnding: LineEnding
    /// A UTF-8 BOM. Excel on Windows needs it to recognise UTF-8; most other readers do not
    /// mind it. Off by default, on in ``excelSwedish``.
    public var byteOrderMark: Bool
    public var quoting: Quoting
    public var formulaInjectionGuard: FormulaInjectionGuard
    /// Emit the exact, unrounded value beside the displayed one (spec 15.8: "raw and display
    /// values"). The raw column is always written in the invariant locale — a period separator
    /// and no grouping — because it exists to be parsed, not read.
    public var includeRawColumns: Bool
    /// Emit a unit column beside each numeric column (spec 15.8: "separate unit columns").
    public var includeUnitColumns: Bool
    /// Emit one leading column per grouping level.
    public var includeGroupColumns: Bool
    public var includeSubtotalRows: Bool
    public var includeGrandTotalRows: Bool
    public var rawColumnSuffix: String
    public var unitColumnSuffix: String
    /// Header of the leading column that says whether a record is a row, a subtotal or a total.
    /// Written whenever subtotal or total rows are included, because a CSV with unlabelled total
    /// rows silently doubles every sum a downstream tool computes.
    public var recordTypeColumnTitle: String
    /// Append ``ExportRowTrace/columnTitles`` after every other column (feature 16). On by
    /// default and inert unless the projection actually carries traces, so a file exported from a
    /// projection built without them is unchanged.
    public var includeTraceColumns: Bool

    public init(
        delimiter: Character = ",",
        lineEnding: LineEnding = .crlf,
        byteOrderMark: Bool = false,
        quoting: Quoting = .minimal,
        formulaInjectionGuard: FormulaInjectionGuard = .apostrophe,
        includeRawColumns: Bool = true,
        includeUnitColumns: Bool = true,
        includeGroupColumns: Bool = true,
        includeSubtotalRows: Bool = true,
        includeGrandTotalRows: Bool = true,
        rawColumnSuffix: String = " (raw)",
        unitColumnSuffix: String = " (unit)",
        recordTypeColumnTitle: String = "Record",
        includeTraceColumns: Bool = true
    ) {
        self.delimiter = delimiter
        self.lineEnding = lineEnding
        self.byteOrderMark = byteOrderMark
        self.quoting = quoting
        self.formulaInjectionGuard = formulaInjectionGuard
        self.includeRawColumns = includeRawColumns
        self.includeUnitColumns = includeUnitColumns
        self.includeGroupColumns = includeGroupColumns
        self.includeSubtotalRows = includeSubtotalRows
        self.includeGrandTotalRows = includeGrandTotalRows
        self.rawColumnSuffix = rawColumnSuffix
        self.unitColumnSuffix = unitColumnSuffix
        self.recordTypeColumnTitle = recordTypeColumnTitle
        self.includeTraceColumns = includeTraceColumns
    }

    /// What a Swedish Excel expects: semicolon delimiter and a BOM. Pair it with
    /// ``ExportNumberLocale/svSE`` on the projection, which supplies the comma decimal separator.
    public static let excelSwedish = CSVExportOptions(delimiter: ";", byteOrderMark: true)
}

/// RFC 4180 CSV over an ``ExportProjection``.
///
/// # What "correct" means here
///
/// - A field containing the delimiter, a double quote, CR or LF is enclosed in double quotes
///   (§2.6), and an embedded double quote is written as two double quotes (§2.7). A field with
///   leading or trailing whitespace is quoted too, because trimming is a common reader
///   behaviour and losing a space is a data change.
/// - Records end with CRLF by default (§2.1); the last record may or may not — it does, here,
///   because a trailing terminator is what every reader handles identically.
/// - The header is derived from the visible column set (§2.3) and never from the store.
///
/// # What it does not do
///
/// It does not round, convert, group, sort or total. Every string it writes is
/// ``ExportCell/text``, already produced by ``ExportProjector``.
public struct CSVExporter: Sendable {

    public init() {}

    /// - Throws: ``ExportError/delimiterCollides(delimiter:with:)`` when the delimiter is the
    ///   decimal separator, the quote character or a line terminator. A semicolon file with a
    ///   comma decimal separator is fine; a comma file with a comma decimal separator is not a
    ///   file, and producing it and hoping is worse than refusing.
    public func export(
        _ projection: ExportProjection,
        options: CSVExportOptions = CSVExportOptions()
    ) throws -> Data {
        try validate(options, locale: projection.numberLocale)
        var sink = DataSink()
        try write(projection, options: options, into: &sink)
        return sink.data
    }

    /// Streams the file to `url` instead of building it in memory (IM-061).
    ///
    /// Records go through the same writer as ``export(_:options:)``, so the two produce the same
    /// bytes, but here they are flushed to disk every ``streamFlushThreshold`` bytes: a 100 000-row
    /// ledger is never held as one `String` and then copied into a second `Data`. The file is
    /// written beside `url` under a temporary name and moved into place only once it is
    /// complete, so a failed export never leaves a half-written file where the old one was.
    ///
    /// - Throws: the delimiter errors of ``export(_:options:)``, or
    ///   ``ExportError/fileWriteFailed(path:reason:)``.
    public func export(
        _ projection: ExportProjection,
        options: CSVExportOptions = CSVExportOptions(),
        to url: URL
    ) throws {
        try validate(options, locale: projection.numberLocale)
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).partial"
        )
        let path = url.path(percentEncoded: false)
        guard fileManager.createFile(atPath: staging.path(percentEncoded: false), contents: nil) else {
            throw ExportError.fileWriteFailed(path: path, reason: "cannot create a file in \(directory.path(percentEncoded: false))")
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            var sink = FileSink(handle: handle, threshold: Self.streamFlushThreshold)
            do {
                try write(projection, options: options, into: &sink)
                try sink.flush()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if fileManager.fileExists(atPath: path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: url)
            }
        } catch let error as ExportError {
            try? fileManager.removeItem(at: staging)
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw ExportError.fileWriteFailed(path: path, reason: error.localizedDescription)
        }
    }

    /// How many bytes the streaming writer buffers before it writes them to the file.
    static let streamFlushThreshold = 256 * 1024

    /// The one record writer both entry points use.
    func write<Sink: CSVRecordSink>(
        _ projection: ExportProjection,
        options: CSVExportOptions,
        into sink: inout Sink
    ) throws {
        let table = projection.table
        if options.byteOrderMark { try sink.append("\u{FEFF}") }

        let layout = Layout(table: table, options: options)
        // The header is text a user can type — a custom column's title — so it is guarded like
        // any other text field. It used to be written with the guard off, and a column titled
        // `=HYPERLINK(...)` reached the spreadsheet as a live formula (BH-508).
        try appendRecord(layout.header.map(Field.text), to: &sink, options: options)

        if table.groups.isEmpty {
            for row in table.rows {
                try appendRecord(layout.fields(row: row), to: &sink, options: options)
            }
        } else {
            for group in table.groups {
                try append(group, layout: layout, to: &sink, options: options)
            }
        }
        if options.includeGrandTotalRows {
            for total in table.grandTotals {
                try appendRecord(
                    layout.fields(total: total, kind: "Total", label: table.metadata.title),
                    to: &sink,
                    options: options
                )
            }
        }
    }

    private func append<Sink: CSVRecordSink>(
        _ group: ExportGroup,
        layout: Layout,
        to sink: inout Sink,
        options: CSVExportOptions
    ) throws {
        for row in group.rows {
            try appendRecord(layout.fields(row: row), to: &sink, options: options)
        }
        for subgroup in group.subgroups {
            try append(subgroup, layout: layout, to: &sink, options: options)
        }
        guard options.includeSubtotalRows else { return }
        for total in group.subtotals {
            try appendRecord(
                layout.fields(total: total, kind: "Subtotal", label: group.label, group: group),
                to: &sink,
                options: options
            )
        }
    }

    private func validate(_ options: CSVExportOptions, locale: ExportNumberLocale) throws {
        let delimiter = String(options.delimiter)
        if delimiter == locale.decimalSeparator {
            throw ExportError.delimiterCollides(delimiter: delimiter, with: "the decimal separator")
        }
        if let grouping = locale.groupingSeparator, delimiter == grouping {
            throw ExportError.delimiterCollides(delimiter: delimiter, with: "the grouping separator")
        }
        if options.delimiter == "\"" {
            throw ExportError.delimiterCollides(delimiter: delimiter, with: "the quote character")
        }
        if options.delimiter == "\r" || options.delimiter == "\n" {
            throw ExportError.delimiterCollides(delimiter: delimiter, with: "a line terminator")
        }
    }

    // MARK: - Records

    /// One field of a record, typed so the formula guard knows what it is looking at.
    ///
    /// The guard exists for *text* — a comment reading `=1+1` that a spreadsheet would
    /// evaluate. It used to run over every field, numbers included, and so wrote `'-50.00`
    /// for a negative display value and `'-0.004` for a negative raw value: a spreadsheet then
    /// imported the whole column as text, and a locale whose minus is U+2212 got the guard on
    /// some rows and not others (CR-57). A number the projector rendered is never guarded.
    enum Field {
        /// Free text: a subject, a comment, a group label, a unit symbol, a refusal token.
        case text(String)
        /// A number the projector rendered — the display text or the invariant raw value.
        case number(String)

        var text: String {
            switch self {
            case .text(let value), .number(let value): value
            }
        }

        var isNumber: Bool {
            if case .number = self { return true }
            return false
        }
    }

    private func appendRecord<Sink: CSVRecordSink>(
        _ fields: [Field],
        to sink: inout Sink,
        options: CSVExportOptions
    ) throws {
        var record = ""
        var first = true
        for field in fields {
            if !first { record.append(options.delimiter) }
            first = false
            record += Self.escape(
                field.text,
                delimiter: options.delimiter,
                quoting: options.quoting,
                guardFormulas: field.isNumber ? .none : options.formulaInjectionGuard
            )
        }
        record += options.lineEnding.text
        try sink.append(record)
    }

    /// RFC 4180 §2.6 and §2.7 quoting, plus the spreadsheet formula guard.
    static func escape(
        _ field: String,
        delimiter: Character,
        quoting: CSVExportOptions.Quoting,
        guardFormulas: CSVExportOptions.FormulaInjectionGuard
    ) -> String {
        var value = field
        if guardFormulas == .apostrophe, let first = value.first,
           "=+-@\t\r".contains(first) {
            value = "'" + value
        }
        // Checked on unicode scalars, not on characters: Swift folds CRLF into one `Character`,
        // so `value.contains("\r")` misses a field that ends with a carriage return before a
        // line feed — which is exactly the field that must be quoted.
        let breaksLine = value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }
        let mustQuote = quoting == .all
            || value.contains(delimiter)
            || value.contains("\"")
            || breaksLine
            || value.first == " "
            || value.last == " "
        guard mustQuote else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Layout

    /// The header and the field order, computed once.
    private struct Layout {
        let table: ExportTable
        let options: CSVExportOptions
        let header: [String]
        let hasRecordTypeColumn: Bool
        let groupLevelCount: Int
        /// The provenance column (ADR-0012 rule 4) is appended after every data column, so a
        /// reader built against the old header keeps reading the old fields at the old indices.
        /// It appears exactly when the table carries a derived or read row — a pure-measured
        /// export is byte for byte the file this exporter always wrote — and it is not
        /// optional: the moment the three claims can mix, the labels are there by construction.
        let hasProvenanceColumn: Bool
        /// Trace columns are appended **after** every existing column, never inserted among them,
        /// so a reader built against the old header keeps reading the old fields at the old
        /// indices (feature 16). They stay the conditional tail: the provenance column, when
        /// present, precedes them.
        let hasTraceColumns: Bool
        /// The scale-status column (K-04) is the last of all, present only when some row holds a
        /// value kept under an older scale — the one way a CSV, which has no metadata block, can
        /// say so. Every other export is unchanged.
        let hasScaleStatusColumn: Bool
        /// Token to label, built once. A tree search per row would be O(rows x groups), which at
        /// 10 000 rows is the difference between a CSV export and a coffee break.
        let labelsByToken: [String: String]

        init(table: ExportTable, options: CSVExportOptions) {
            self.table = table
            self.options = options
            self.hasRecordTypeColumn = options.includeSubtotalRows || options.includeGrandTotalRows
            self.groupLevelCount = options.includeGroupColumns
                ? table.metadata.groupingColumnKeys.count
                : 0
            self.hasProvenanceColumn = table.carriesProvenanceLabels
            self.hasTraceColumns = options.includeTraceColumns && table.carriesRowTraces
            self.hasScaleStatusColumn = table.carriesScaleStatus
            var header: [String] = []
            if hasRecordTypeColumn { header.append(options.recordTypeColumnTitle) }
            // The grouping column named as the ledger titles it, as the workbook does (L-46).
            for title in table.metadata.groupingColumnTitles.prefix(groupLevelCount) {
                header.append("Group: \(title)")
            }
            for column in table.columns {
                header.append(column.title)
                if options.includeRawColumns, column.isNumeric {
                    header.append(column.title + options.rawColumnSuffix)
                }
                if options.includeUnitColumns, column.isNumeric {
                    header.append(column.title + options.unitColumnSuffix)
                }
            }
            if hasProvenanceColumn { header.append(ExportRow.provenanceColumnTitle) }
            if hasTraceColumns { header.append(contentsOf: ExportRowTrace.columnTitles) }
            if hasScaleStatusColumn { header.append(ExportRow.scaleStatusColumnTitle) }
            self.header = header
            var labels: [String: String] = [:]
            func collect(_ groups: [ExportGroup]) {
                for group in groups {
                    labels[group.token] = group.label
                    collect(group.subgroups)
                }
            }
            collect(table.groups)
            self.labelsByToken = labels
        }

        func fields(row: ExportRow) -> [Field] {
            var fields: [Field] = []
            fields.reserveCapacity(header.count)
            if hasRecordTypeColumn { fields.append(.text("Row")) }
            for level in 0..<groupLevelCount {
                fields.append(.text(level < row.groupPath.count ? label(forToken: row.groupPath[level]) : ""))
            }
            for (index, column) in table.columns.enumerated() {
                let cell = index < row.cells.count ? row.cells[index] : .blank
                append(cell, column: column, to: &fields)
            }
            // Every row is labelled, the measured ones included: in a file that mixes the
            // claims, an unlabelled row is exactly the ambiguity ADR-0012 rule 4 forbids.
            if hasProvenanceColumn { fields.append(.text(row.provenance)) }
            // A traced export with an untraced row still writes the scale as "unknown" rather
            // than leaving it blank, which a reader would fill in with the document scale.
            if hasTraceColumns {
                fields.append(contentsOf: (row.trace ?? .unknown).fieldTexts.map(Field.text))
            }
            if hasScaleStatusColumn { fields.append(.text(row.scaleStatusText)) }
            return fields
        }

        func fields(
            total: ExportTotalRow,
            kind: String,
            label: String,
            group: ExportGroup? = nil
        ) -> [Field] {
            var fields: [Field] = []
            fields.reserveCapacity(header.count)
            if hasRecordTypeColumn { fields.append(.text("\(kind): \(total.function)")) }
            for level in 0..<groupLevelCount {
                if let group, level < group.path.count {
                    fields.append(.text(self.label(forToken: group.path[level])))
                } else if group == nil, level == 0 {
                    fields.append(.text(label))
                } else {
                    fields.append(.text(""))
                }
            }
            for (index, column) in table.columns.enumerated() {
                let cell = index < total.cells.count ? total.cells[index] : .blank
                append(cell, column: column, to: &fields)
            }
            // A subtotal or grand total aggregates rows whose claims may differ; giving the
            // aggregate a provenance of its own would invent one. It writes nothing, the same
            // answer the trace columns give.
            if hasProvenanceColumn { fields.append(.text("")) }
            if hasTraceColumns {
                fields.append(contentsOf: ExportRowTrace.totalFieldTexts.map(Field.text))
            }
            if hasScaleStatusColumn { fields.append(.text("")) }
            return fields
        }

        private func append(_ cell: ExportCell, column: ExportColumn, to fields: inout [Field]) {
            if let number = cell.number {
                fields.append(.number(number.text))
            } else {
                fields.append(.text(cell.text))
            }
            guard column.isNumeric else { return }
            if options.includeRawColumns {
                // Invariant, unrounded, unconverted: the audit value.
                if let number = cell.number {
                    fields.append(.number(number.invariantRawText))
                } else {
                    fields.append(.text(cell.isRefusal ? cell.text : ""))
                }
            }
            if options.includeUnitColumns {
                fields.append(.text(cell.number?.unitSymbol ?? (cell.isRefusal ? "" : column.unitSymbol)))
            }
        }

        /// Group tokens are stable identities, not labels. Where the projection carried a label
        /// for a token, use it; otherwise print the token, which is at least unambiguous.
        private func label(forToken token: String) -> String {
            labelsByToken[token] ?? token
        }
    }
}


// MARK: - Sinks

/// Where the record writer puts its bytes: memory for ``CSVExporter/export(_:options:)``, a file
/// for ``CSVExporter/export(_:options:to:)``. One writer, two destinations, one set of bytes.
protocol CSVRecordSink {
    mutating func append(_ text: String) throws
}

/// The whole file in memory, as UTF-8 — appended straight into `Data`, never through a second
/// full-size `String`.
struct DataSink: CSVRecordSink {
    private(set) var data = Data()

    mutating func append(_ text: String) {
        data.append(contentsOf: text.utf8)
    }
}

/// A buffered file writer that flushes every `threshold` bytes.
struct FileSink: CSVRecordSink {
    let handle: FileHandle
    let threshold: Int
    private var buffer = Data()
    /// The most bytes the buffer ever held, for the test that bounds it.
    private(set) var peakBufferedBytes = 0

    init(handle: FileHandle, threshold: Int) {
        self.handle = handle
        self.threshold = max(1, threshold)
        buffer.reserveCapacity(self.threshold + 4_096)
    }

    mutating func append(_ text: String) throws {
        buffer.append(contentsOf: text.utf8)
        peakBufferedBytes = max(peakBufferedBytes, buffer.count)
        if buffer.count >= threshold { try flush() }
    }

    mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
