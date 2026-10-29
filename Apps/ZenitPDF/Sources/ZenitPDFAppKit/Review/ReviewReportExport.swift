import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFExport
import ZPDFUIPresentation

/// The review summary report (NL-COLLAB-16): every markup the Review List shows — page, kind,
/// author, status, assignee, and the whole thread — as a PDF to send or a CSV to sort.
///
/// Drawn with Core Text into a PDF context, each markup with a cropped snapshot of itself on its
/// sheet (``ReviewReportSnapshots``); the same rows as a CSV or an Excel workbook, the workbook
/// with the snapshot beside each row. CSV and workbook cells go through the formula guard, so a
/// note typed as `=HYPERLINK(…)` is text in every spreadsheet.
@MainActor
enum ReviewReportExport {

    static let panelIdentifier = "reviewReport.destination"

    /// One markup, as the report prints it.
    struct Entry: Equatable {
        var row: ReviewListRow
        var thread: [ReviewThreadItem]
        /// The markup's snapshot, PNG bytes; `nil` when none could be made.
        var snapshot: Data?
    }

    static func entries(for markupIDs: [UUID], review: any ReviewThreadPresenting) -> [Entry] {
        let markups = Dictionary(review.reviewMarkups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = Dictionary(ReviewList.rows(markups: review.reviewMarkups, threads: review).map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        return markupIDs.compactMap { id in
            guard let row = rows[id], let markup = markups[id] else { return nil }
            return Entry(row: row, thread: review.thread(for: markup).items)
        }
    }

    static func present(document: ZenitPDFProjectDocument, markupIDs: [UUID], window: NSWindow?) {
        guard let review = document.shell?.review else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf, .commaSeparatedText, UTType(filenameExtension: "xlsx", conformingTo: .data) ?? .spreadsheet]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "\(document.displayName ?? "Review") — Review.pdf"
        panel.message = NSLocalizedString(
            "Save as PDF to send, or change the name to .csv or .xlsx for a spreadsheet.",
            comment: "Review report save panel message"
        )
        let chosen = entries(for: markupIDs, review: review)
        ZenitModalPresenter.runSavePanel(panel, identifier: panelIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in
                // CSV carries no pictures, so it needs none rendered.
                var entries = chosen
                if url.pathExtension.lowercased() != "csv" {
                    let pictures = await ReviewReportSnapshots.snapshots(for: entries, document: document)
                    for index in entries.indices { entries[index].snapshot = pictures[entries[index].row.id] }
                }
                do {
                    try export(entries, document: document, to: url)
                } catch {
                    ZenitErrorPresenter.present(error, in: window)
                }
            }
        }
    }

    /// Writes the report the save panel asked for and remembers it for Share Last Export… — the
    /// report was the one export that left an older file to be shared (R-028).
    static func export(_ entries: [Entry], document: ZenitPDFProjectDocument, to url: URL) throws {
        // The panel allows any name, the drawing's included (U-017).
        try DerivedCopyGuard.refuseIfDocumentFile(url, document: document)
        try write(entries, title: document.displayName ?? "", to: url)
        ExportCompletion.remember(url, document: document)
    }

    static func write(_ entries: [Entry], title: String, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "csv":
            try csv(entries).write(to: url, options: .atomic)
        case "xlsx":
            try XLSXTextTableExporter.export(workbook(entries), to: url)
        default:
            try pdf(entries, title: title).write(to: url, options: .atomic)
        }
    }

    // MARK: - CSV and workbook

    /// The Excel form: the CSV's columns, one row per markup, and its snapshot beside it.
    static func workbook(_ entries: [Entry]) -> XLSXTextTable {
        XLSXTextTable(
            sheetName: NSLocalizedString("Review", comment: "Review report workbook sheet name"),
            header: header,
            rows: entries.map(cells(for:)),
            images: entries.map(\.snapshot),
            imageColumnTitle: NSLocalizedString("Snapshot", comment: "Review report column: a picture of the markup on its sheet")
        )
    }

    /// One markup's cells, in ``header`` order — the same for the CSV and the workbook.
    static func cells(for entry: Entry) -> [String] {
        let row = entry.row
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withFullDate]
        return [
            row.pageLabel, row.kindName, row.subject, row.note, row.author, row.status.displayName,
            row.assignee, row.due.map(date.string(from:)) ?? "", String(row.replyCount),
            ISO8601DateFormatter().string(from: row.lastActivity),
            threadText(entry.thread)
        ]
    }

    static var header: [String] {
        [
            NSLocalizedString("Page", comment: "Review List column"),
            NSLocalizedString("Kind", comment: "Review List column"),
            NSLocalizedString("Subject", comment: "Review List column"),
            NSLocalizedString("Note", comment: "Review List column: the markup's note, first line"),
            NSLocalizedString("Author", comment: "Review List column"),
            NSLocalizedString("Status", comment: "Review List column"),
            NSLocalizedString("Assignee", comment: "Review List column"),
            NSLocalizedString("Due", comment: "Review List assign form: the due date"),
            NSLocalizedString("Replies", comment: "Review List column"),
            NSLocalizedString("Last Activity", comment: "Review List column"),
            NSLocalizedString("Thread", comment: "Review report column: every reply and status change")
        ]
    }

    static func csv(_ entries: [Entry], delimiter: Character = LedgerCSVExport.delimiter(for: .current)) -> Data {
        var lines = [header.map { LedgerCSVExport.field($0, delimiter: delimiter) }.joined(separator: String(delimiter))]
        for entry in entries {
            let cells = cells(for: entry)
            lines.append(cells.map { LedgerCSVExport.field($0, delimiter: delimiter) }.joined(separator: String(delimiter)))
        }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(lines.joined(separator: "\r\n").utf8))
        data.append(Data("\r\n".utf8))
        return data
    }

    /// "Ada (23 Sep 2026): Check the edge" per line, status changes in words.
    static func threadText(_ items: [ReviewThreadItem]) -> String {
        items.map { item in
            let who = item.author.isEmpty ? NSLocalizedString("Author not recorded", comment: "Comments tab: a note written before review history existed") : item.author
            let when = item.date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""
            let what: String
            switch item.kind {
            case .note, .reply:
                what = item.isRetracted ? NSLocalizedString("Reply withdrawn", comment: "Comments tab: a reply its author withdrew") : item.text
            case let .statusChange(from, to, reverted):
                let before = (from ?? MarkupStatus.none).displayName, after = (to ?? MarkupStatus.none).displayName
                what = reverted
                    ? String(format: NSLocalizedString("reverted status %1$@ → %2$@", comment: "Review report: an undone status change; from, to"), before, after)
                    : String(format: NSLocalizedString("status %1$@ → %2$@", comment: "Review report: a status change; from, to"), before, after)
            case let .assignment(assignee, due):
                what = assignee.isEmpty
                    ? NSLocalizedString("cleared the assignment", comment: "Review report: an assignment cleared")
                    : String(format: NSLocalizedString("assigned to %@", comment: "Review report: an assignment; to whom"), assignee)
                        + (due.map { " (" + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) + ")" } ?? "")
            }
            return when.isEmpty ? "\(who): \(what)" : "\(who) (\(when)): \(what)"
        }
        .joined(separator: "\n")
    }

    // MARK: - PDF

    /// A4 portrait, 40 pt margins, one block per markup — its heading, author and thread, then
    /// its snapshot — paged so a block and its picture stay together. A thread longer than a page
    /// flows on across pages.
    static func pdf(_ entries: [Entry], title: String) -> Data { renderPDF(entries, title: title).data }

    /// The report and how many snapshots it drew (the number a test asserts).
    static func renderPDF(_ entries: [Entry], title: String) -> (data: Data, drawnSnapshots: Int, pageCount: Int) {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: title] as CFDictionary)
        else { return (Data(), 0, 0) }
        let heading = NSFont.boldSystemFont(ofSize: 14)
        let bold = NSFont.boldSystemFont(ofSize: 10)
        let body = NSFont.systemFont(ofSize: 9.5)
        let black = NSColor.black
        func attributed(_ parts: [(String, NSFont)]) -> NSAttributedString {
            let text = NSMutableAttributedString()
            for (string, font) in parts {
                text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: black]))
            }
            return text
        }
        let content = box.insetBy(dx: 40, dy: 40)
        var cursor = content.maxY
        var pageOpen = false
        var pages = 0
        var drawn = 0
        func newPage() {
            if pageOpen { context.endPDFPage() }
            context.beginPDFPage(nil)
            pageOpen = true
            pages += 1
            cursor = content.maxY
        }
        func height(_ text: NSAttributedString) -> CGFloat {
            let setter = CTFramesetterCreateWithAttributedString(text)
            return ceil(CTFramesetterSuggestFrameSizeWithConstraints(
                setter, CFRange(location: 0, length: 0), nil,
                CGSize(width: content.width, height: .greatestFiniteMagnitude), nil
            ).height)
        }
        /// Draws `text` from the cursor down, flowing onto new pages when it is longer than what
        /// is left.
        func flow(_ text: NSAttributedString) {
            let setter = CTFramesetterCreateWithAttributedString(text)
            var location = 0
            while location < text.length {
                let rect = CGRect(x: content.minX, y: content.minY, width: content.width, height: cursor - content.minY)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0), CGPath(rect: rect, transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                let used = CTFramesetterSuggestFrameSizeWithConstraints(
                    setter, visible, nil, CGSize(width: content.width, height: .greatestFiniteMagnitude), nil
                ).height
                CTFrameDraw(frame, context)
                location += visible.length
                cursor -= ceil(used)
                if location < text.length { newPage() }
                if visible.length == 0 { break }
            }
        }

        newPage()
        flow(attributed([
            (String(format: NSLocalizedString("Review report — %@", comment: "Review report title; the document name"), title) + "\n", heading),
            (String(format: NSLocalizedString("%lld markups · %@", comment: "Review report subtitle; count, date"),
                    entries.count, DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)) + "\n", body)
        ]))
        cursor -= 10
        for entry in entries {
            let row = entry.row
            var line = "\(row.pageLabel) · \(row.kindName)"
            if !row.subject.isEmpty { line += " · \(row.subject)" }
            line += " — \(row.status.displayName)"
            var meta = row.author
            if !row.assignee.isEmpty {
                meta += " · " + String(format: NSLocalizedString("assigned to %@", comment: "Review report: an assignment; to whom"), row.assignee)
            }
            var parts: [(String, NSFont)] = [(line + "\n", bold), (meta + "\n", body)]
            let thread = threadText(entry.thread)
            if !thread.isEmpty { parts.append((thread + "\n", body)) }
            let block = attributed(parts)
            let image = entry.snapshot.flatMap { data -> CGImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            var imageSize = CGSize.zero
            if let image {
                let scale = min(1, content.width / CGFloat(image.width), 200 / CGFloat(image.height))
                imageSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            }
            let needed = height(block) + (image == nil ? 0 : imageSize.height + 6) + 12
            if needed > cursor - content.minY, cursor < content.maxY { newPage() }
            flow(block)
            if let image {
                if imageSize.height + 6 > cursor - content.minY { newPage() }
                cursor -= 4
                let rect = CGRect(x: content.minX, y: cursor - imageSize.height, width: imageSize.width, height: imageSize.height)
                context.saveGState()
                context.interpolationQuality = .high
                context.draw(image, in: rect)
                context.setStrokeColor(NSColor.gray.cgColor)
                context.setLineWidth(0.5)
                context.stroke(rect)
                context.restoreGState()
                cursor -= imageSize.height + 2
                drawn += 1
            }
            cursor -= 12
        }
        if pageOpen { context.endPDFPage() }
        context.closePDF()
        return (data as Data, drawn, pages)
    }
}
