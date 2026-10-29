import Foundation
import CXlsxWriter

/// Document properties written into the XLSX core properties part.
public struct XlsxDocumentProperties: Hashable, Sendable {
    public var title: String?
    public var subject: String?
    public var author: String?
    public var manager: String?
    public var company: String?
    public var category: String?
    public var keywords: String?
    public var comments: String?
    public var status: String?

    public init(
        title: String? = nil,
        subject: String? = nil,
        author: String? = nil,
        manager: String? = nil,
        company: String? = nil,
        category: String? = nil,
        keywords: String? = nil,
        comments: String? = nil,
        status: String? = nil
    ) {
        self.title = title
        self.subject = subject
        self.author = author
        self.manager = manager
        self.company = company
        self.category = category
        self.keywords = keywords
        self.comments = comments
        self.status = status
    }

    public var isEmpty: Bool {
        title == nil && subject == nil && author == nil && manager == nil && company == nil
            && category == nil && keywords == nil && comments == nil && status == nil
    }
}

/// The libxlsxwriter switches this build can honour.
///
/// There is deliberately no temporary-directory option. libxlsxwriter's `tmpdir` is consumed
/// only by the MPL-2.0 `tmpfileplus` component, which this bridge excludes with
/// `USE_STANDARD_TMPFILE` (see `Package.swift`), so every temporary file comes from the C
/// standard `tmpfile()` in the location the platform chooses; an option claiming otherwise
/// was inert and has been removed (CR-132). ``XlsxWriter/temporaryFileSupportIsAvailable()``
/// reports whether that mechanism works in the current process.
public struct XlsxWorkbookOptions: Hashable, Sendable {
    /// libxlsxwriter's constant-memory mode: a row is flushed to a temporary file as soon as the
    /// next row is started, so a 100 000-row sheet does not live in RAM. The cost is that rows
    /// must be written in strictly increasing order, which every exporter in this repository
    /// does anyway.
    public var constantMemory: Bool
    /// ZIP64 extensions, needed only past 4 GB.
    public var useZip64: Bool

    public init(constantMemory: Bool = false, useZip64: Bool = false) {
        self.constantMemory = constantMemory
        self.useZip64 = useZip64
    }
}

/// The XLSX grid limits, as constants rather than as a crash.
public enum XlsxLimits {
    public static let maximumRows = 1_048_576
    public static let maximumColumns = 16_384
}

/// One worksheet. Valid only inside the `write` closure that produced it. Used after that
/// closure has returned, every method throws ``XlsxError/workbookAlreadyClosed``: the workbook
/// is held weakly, so a sheet that outlives it can tell, instead of reading a dead reference
/// and trapping (CR-133).
public final class XlsxWorksheet {
    private let pointer: UnsafeMutablePointer<lxw_worksheet>
    private weak var owner: XlsxWorkbook?

    init(pointer: UnsafeMutablePointer<lxw_worksheet>, owner: XlsxWorkbook) {
        self.pointer = pointer
        self.owner = owner
    }

    /// The C pointer is only safe to touch while the workbook still exists and is still open:
    /// `workbook_close()` frees every worksheet with it. Every entry point checks this first.
    private func checkOwnerOpen() throws {
        guard let owner else { throw XlsxError.workbookAlreadyClosed }
        try owner.checkOpen()
    }

    private func validate(_ row: Int, _ column: Int) throws {
        try checkOwnerOpen()
        guard row >= 0, row < XlsxLimits.maximumRows,
              column >= 0, column < XlsxLimits.maximumColumns else {
            throw XlsxError.cellOutOfRange(row: row, column: column)
        }
    }

    private func validateColumn(_ column: Int) throws {
        guard column >= 0, column < XlsxLimits.maximumColumns else {
            throw XlsxError.cellOutOfRange(row: 0, column: column)
        }
    }

    /// Writes a real numeric cell. Never a string that looks like a number.
    ///
    /// - Throws: ``XlsxError/nonFiniteNumber(row:column:)`` for NaN or ±infinity, which the C
    ///   library would otherwise write as `NAN` / `INF` into a workbook Excel refuses (BH-081).
    public func writeNumber(row: Int, column: Int, _ value: Double, format: XlsxFormatHandle? = nil) throws {
        try validate(row, column)
        guard value.isFinite else { throw XlsxError.nonFiniteNumber(row: row, column: column) }
        try check(worksheet_write_number(pointer, lxw_row_t(row), lxw_col_t(column), value, format?.pointer))
    }

    /// Writes a live formula cell together with the value it currently evaluates to.
    ///
    /// The cached result is not decoration. `worksheet_write_formula` alone stores `0`, and a
    /// reader that does not recalculate on open — a preview pane, a converter, a script reading
    /// the XML — then shows every total as zero. `worksheet_write_formula_num` stores the answer
    /// the ledger already computed, so the workbook reads correctly whether or not anything
    /// recalculates, and recalculates correctly when something does.
    ///
    /// A leading `=` is optional; libxlsxwriter ignores one if it is there.
    public func writeFormula(
        row: Int,
        column: Int,
        _ formula: String,
        result: Double,
        format: XlsxFormatHandle? = nil
    ) throws {
        try validate(row, column)
        guard result.isFinite else { throw XlsxError.nonFiniteNumber(row: row, column: column) }
        try formula.withCString {
            try check(worksheet_write_formula_num(
                pointer, lxw_row_t(row), lxw_col_t(column), $0, format?.pointer, result
            ))
        }
    }

    public func writeString(row: Int, column: Int, _ text: String, format: XlsxFormatHandle? = nil) throws {
        try validate(row, column)
        try text.withCString {
            try check(worksheet_write_string(pointer, lxw_row_t(row), lxw_col_t(column), $0, format?.pointer))
        }
    }

    /// A hyperlink cell showing `text` (NL-PLAT-09: a ledger row that opens its markup in the app).
    public func writeURL(row: Int, column: Int, url: String, text: String, format: XlsxFormatHandle? = nil) throws {
        try validate(row, column)
        try url.withCString { urlPointer in
            try text.withCString { textPointer in
                try check(worksheet_write_url_opt(pointer, lxw_row_t(row), lxw_col_t(column), urlPointer, format?.pointer, textPointer, nil))
            }
        }
    }

    /// Places a PNG or JPEG image with its top-left corner in the cell, scaled by `scale`
    /// (NL-COLLAB-16: a markup's snapshot beside its row). libxlsxwriter copies the bytes, so
    /// `data` need not outlive the call. `description` is the image's alternative text.
    public func insertImage(row: Int, column: Int, data: Data, scale: Double = 1, description: String? = nil) throws {
        try validate(row, column)
        guard !data.isEmpty, scale.isFinite, scale > 0 else { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            if let description {
                try description.withCString { text in
                    var options = lxw_image_options()
                    options.x_scale = scale
                    options.y_scale = scale
                    options.description = text
                    try check(worksheet_insert_image_buffer_opt(pointer, lxw_row_t(row), lxw_col_t(column), base, raw.count, &options))
                }
            } else {
                var options = lxw_image_options()
                options.x_scale = scale
                options.y_scale = scale
                try check(worksheet_insert_image_buffer_opt(pointer, lxw_row_t(row), lxw_col_t(column), base, raw.count, &options))
            }
        }
    }

    public func writeBoolean(row: Int, column: Int, _ value: Bool, format: XlsxFormatHandle? = nil) throws {
        try validate(row, column)
        try check(worksheet_write_boolean(pointer, lxw_row_t(row), lxw_col_t(column), value ? 1 : 0, format?.pointer))
    }

    public func writeBlank(row: Int, column: Int, format: XlsxFormatHandle? = nil) throws {
        try validate(row, column)
        try check(worksheet_write_blank(pointer, lxw_row_t(row), lxw_col_t(column), format?.pointer))
    }

    /// Writes a date as an Excel serial number under the given format. A real number, so Excel
    /// can sort and filter it.
    ///
    /// - Throws: ``XlsxError/dateOutOfRange(row:column:)`` for a date whose Unix time is not
    ///   finite or does not fit in 64 bits; the unchecked `Int64(_:)` used to trap (BH-404).
    public func writeDate(row: Int, column: Int, _ date: Date, format: XlsxFormatHandle? = nil) throws {
        try validate(row, column)
        let seconds = date.timeIntervalSince1970.rounded()
        guard let unixTime = Int64(exactly: seconds) else {
            throw XlsxError.dateOutOfRange(row: row, column: column)
        }
        try check(worksheet_write_unixtime(
            pointer, lxw_row_t(row), lxw_col_t(column), unixTime, format?.pointer
        ))
    }

    /// - Throws: ``XlsxError/cellOutOfRange(row:column:)`` for a column outside the grid or a
    ///   reversed range; these used to trap in the `UInt16` conversion (BH-405).
    public func setColumnWidth(first: Int, last: Int, width: Double, format: XlsxFormatHandle? = nil) throws {
        try checkOwnerOpen()
        try validateColumn(first)
        try validateColumn(last)
        guard first <= last else { throw XlsxError.cellOutOfRange(row: 0, column: last) }
        guard width.isFinite else { throw XlsxError.nonFiniteNumber(row: 0, column: first) }
        try check(worksheet_set_column(pointer, lxw_col_t(first), lxw_col_t(last), width, format?.pointer))
    }

    public func setRowHeight(_ row: Int, height: Double, format: XlsxFormatHandle? = nil) throws {
        try validate(row, 0)
        guard height.isFinite else { throw XlsxError.nonFiniteNumber(row: row, column: 0) }
        try check(worksheet_set_row(pointer, lxw_row_t(row), height, format?.pointer))
    }

    /// Row height, format, visibility and outline grouping in one call
    /// (`worksheet_set_row_opt`). `level` is the outline level (Excel allows 0…7; larger
    /// values are clamped), `collapsed` marks the row that carries a collapsed group's
    /// symbol. In constant-memory mode call it before the row's first cell.
    ///
    /// - Throws: ``XlsxError/cellOutOfRange(row:column:)`` for a row outside the grid,
    ///   ``XlsxError/nonFiniteNumber(row:column:)`` for a non-finite height.
    public func setRowOptions(
        _ row: Int,
        height: Double? = nil,
        format: XlsxFormatHandle? = nil,
        hidden: Bool = false,
        level: UInt8 = 0,
        collapsed: Bool = false
    ) throws {
        try validate(row, 0)
        let resolvedHeight = height ?? LXW_DEF_ROW_HEIGHT
        guard resolvedHeight.isFinite else { throw XlsxError.nonFiniteNumber(row: row, column: 0) }
        var options = lxw_row_col_options(
            hidden: hidden ? 1 : 0,
            level: Swift.min(level, 7),
            collapsed: collapsed ? 1 : 0
        )
        try check(worksheet_set_row_opt(pointer, lxw_row_t(row), resolvedHeight, format?.pointer, &options))
    }

    /// Freezes everything above `row` and left of `column`.
    public func freezePanes(row: Int, column: Int) throws {
        try validate(row, column)
        worksheet_freeze_panes(pointer, lxw_row_t(row), lxw_col_t(column))
    }

    public func autofilter(firstRow: Int, firstColumn: Int, lastRow: Int, lastColumn: Int) throws {
        try validate(firstRow, firstColumn)
        try validate(lastRow, lastColumn)
        try check(worksheet_autofilter(
            pointer, lxw_row_t(firstRow), lxw_col_t(firstColumn), lxw_row_t(lastRow), lxw_col_t(lastColumn)
        ))
    }
}

/// The workbook handed to the `write` closure.
public final class XlsxWorkbook {
    private var pointer: UnsafeMutablePointer<lxw_workbook>?
    private var formats: [XlsxFormatSpec: UnsafeMutablePointer<lxw_format>] = [:]

    init(pointer: UnsafeMutablePointer<lxw_workbook>) { self.pointer = pointer }

    func checkOpen() throws {
        guard pointer != nil else { throw XlsxError.workbookAlreadyClosed }
    }

    public func addWorksheet(name: String? = nil) throws -> XlsxWorksheet {
        try checkOpen()
        guard let pointer else { throw XlsxError.workbookAlreadyClosed }
        let handle: UnsafeMutablePointer<lxw_worksheet>? = if let name {
            name.withCString { workbook_add_worksheet(pointer, $0) }
        } else {
            workbook_add_worksheet(pointer, nil)
        }
        guard let handle else { throw XlsxError.worksheetCreationFailed(name: name ?? "(default)") }
        return XlsxWorksheet(pointer: handle, owner: self)
    }

    /// Resolves a format spec to a handle, allocating at most one `lxw_format` per distinct spec.
    public func format(_ spec: XlsxFormatSpec) throws -> XlsxFormatHandle {
        try checkOpen()
        guard let pointer else { throw XlsxError.workbookAlreadyClosed }
        if let existing = formats[spec] { return XlsxFormatHandle(pointer: existing) }
        guard let handle = workbook_add_format(pointer) else { throw XlsxError.formatCreationFailed }
        spec.apply(to: handle)
        formats[spec] = handle
        return XlsxFormatHandle(pointer: handle)
    }

    func setProperties(_ properties: XlsxDocumentProperties) throws {
        guard let pointer, !properties.isEmpty else { return }
        try properties.title.withOptionalCString { title in
            try properties.subject.withOptionalCString { subject in
                try properties.author.withOptionalCString { author in
                    try properties.manager.withOptionalCString { manager in
                        try properties.company.withOptionalCString { company in
                            try properties.category.withOptionalCString { category in
                                try properties.keywords.withOptionalCString { keywords in
                                    try properties.comments.withOptionalCString { comments in
                                        try properties.status.withOptionalCString { status in
                                            var doc = lxw_doc_properties(
                                                title: title,
                                                subject: subject,
                                                author: author,
                                                manager: manager,
                                                company: company,
                                                category: category,
                                                keywords: keywords,
                                                comments: comments,
                                                status: status,
                                                hyperlink_base: nil,
                                                created: time_t(0)
                                            )
                                            try check(workbook_set_properties(pointer, &doc))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Closes and writes the file. Called exactly once, by ``XlsxWriter/write(to:options:properties:_:)``,
    /// inside its C numeric locale scope: number cells are serialised here with `%.16G`.
    func close() throws {
        guard let handle = pointer else { return }
        pointer = nil
        formats.removeAll()
        try check(workbook_close(handle))
    }

    /// Discards the workbook after a failure **without writing anything**.
    ///
    /// `workbook_close` is the *writing* path: it reaches `lxw_packager_new(filename)`, which
    /// opens and truncates the destination before assembling the package. Calling it here used
    /// to overwrite the file at the destination with a partial workbook (BH-001).
    /// `lxw_workbook_free` releases every worksheet, format and temporary file and never opens
    /// the output path.
    func abandon() {
        guard let handle = pointer else { return }
        pointer = nil
        formats.removeAll()
        lxw_workbook_free(handle)
    }
}

/// The C numeric locale, created once.
nonisolated(unsafe) private let cNumericLocale: locale_t? = newlocale(LC_NUMERIC_MASK, "C", nil)

/// Runs `body` with this thread's numeric locale pinned to "C".
///
/// Built without `USE_DTOA_LIBRARY`, libxlsxwriter formats every number with a bare
/// `%.16G`, which honours the thread's `LC_NUMERIC`. Under a Swedish numeric locale a cell
/// became `<v>1,5</v>` and the workbook was rejected (BH-403). `uselocale` is per-thread, so
/// nothing else in the process is affected.
///
/// One scope around the whole workbook (R-201), in ``XlsxWriter/write(to:options:properties:_:)``.
/// The per-call wrappers it replaced covered the number-writing calls but not the flush: in
/// constant-memory mode the *previous* row's numbers are formatted when a cell in a new row is
/// written, and a row that began with a string, a link, a boolean or a blank flushed its
/// predecessor unguarded. The body is synchronous, so it cannot leave the thread.
func withCNumericLocale<R>(_ body: () throws -> R) rethrows -> R {
    guard let cNumericLocale else { return try body() }
    let previous = uselocale(cNumericLocale)
    defer { uselocale(previous) }
    return try body()
}

extension Optional where Wrapped == String {
    func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {
        guard let self else { return try body(nil) }
        return try self.withCString { try body($0) }
    }
}

/// The entry point. Scoped, so `workbook_close()` runs exactly once and no C pointer outlives it.
public enum XlsxWriter {

    /// The libxlsxwriter version this bridge vendors.
    public static var libraryVersion: String { String(cString: lxw_version()) }

    /// True when the C standard `tmpfile()` works in this process.
    ///
    /// This bridge is built with `USE_STANDARD_TMPFILE` and therefore depends on it. Under the
    /// App Sandbox `tmpfile()` resolves through the container's `TMPDIR`; if that ever stops
    /// being true, this returns `false` and the caller must say so rather than degrade quietly.
    public static func temporaryFileSupportIsAvailable() -> Bool {
        guard let handle = tmpfile() else { return false }
        let wrote = fputs("zenit", handle)
        fclose(handle)
        return wrote >= 0
    }

    /// Writes a workbook to `url`.
    ///
    /// The workbook is assembled in a private staging file (an item-replacement directory on the
    /// destination's volume, as the system's own document saving does) and moved over `url`
    /// only after `workbook_close` has succeeded. A failure therefore never touches whatever
    /// already exists at `url`: neither the user's previous export (BH-001) nor an unrelated
    /// file of the same name (BH-082).
    ///
    /// - Throws: ``XlsxError``, or whatever `body` throws — in which case the workbook is
    ///   abandoned without being written, the staging file is removed, and `url` is untouched.
    public static func write(
        to url: URL,
        options: XlsxWorkbookOptions = XlsxWorkbookOptions(),
        properties: XlsxDocumentProperties = XlsxDocumentProperties(),
        _ body: (XlsxWorkbook) throws -> Void
    ) throws {
        let destinationPath = url.path(percentEncoded: false)
        let staging = try stagingURL(for: url)
        defer { try? FileManager.default.removeItem(at: staging.directory) }
        let path = staging.file.path(percentEncoded: false)

        let handle: UnsafeMutablePointer<lxw_workbook>? = path.withCString { cPath in
            var raw = lxw_workbook_options(
                constant_memory: options.constantMemory ? 1 : 0,
                // Never settable here: with USE_STANDARD_TMPFILE the library ignores it. See
                // `XlsxWorkbookOptions`.
                tmpdir: nil,
                use_zip64: options.useZip64 ? 1 : 0,
                output_buffer: nil,
                output_buffer_size: nil
            )
            return workbook_new_opt(cPath, &raw)
        }
        guard let handle else { throw XlsxError.workbookCreationFailed(path: destinationPath) }

        let workbook = XlsxWorkbook(pointer: handle)
        // Every place libxlsxwriter formats a number — a cell, a row flush in constant-memory
        // mode, the close — runs inside this one C numeric locale scope (R-201).
        try withCNumericLocale {
            do {
                try workbook.setProperties(properties)
                try body(workbook)
                try workbook.close()
            } catch {
                workbook.abandon()
                throw error
            }
        }
        try install(staging.file, at: url)
    }

    /// A fresh, private directory for the staging file. Prefers an item-replacement directory
    /// on the destination's volume (so the final move is a rename); falls back to the process
    /// temporary directory where that is unavailable.
    static func stagingURL(for destination: URL) throws -> (directory: URL, file: URL) {
        let fileManager = FileManager.default
        let directory: URL
        if let replacement = try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        ) {
            directory = replacement
        } else {
            directory = fileManager.temporaryDirectory
                .appendingPathComponent("zpdf-xlsx-\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw XlsxError.workbookCreationFailed(path: destination.path(percentEncoded: false))
            }
        }
        let name = destination.lastPathComponent.isEmpty ? "workbook.xlsx" : destination.lastPathComponent
        return (directory, directory.appendingPathComponent(name, isDirectory: false))
    }

    /// Moves the finished staging file over `destination`, replacing an existing file
    /// atomically, or placing it when nothing is there yet.
    static func install(_ staged: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            throw XlsxError.workbookCreationFailed(path: destination.path(percentEncoded: false))
        }
    }
}
