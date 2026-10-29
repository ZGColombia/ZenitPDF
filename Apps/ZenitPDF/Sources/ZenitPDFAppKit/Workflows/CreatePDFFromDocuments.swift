import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFUIPresentation

/// File ▸ New PDF from Documents… and File ▸ Set Up “Print to Zenit PDF”… (NL-PDF-18).
///
/// Word-processing documents — Word (.docx, .doc), OpenDocument text (.odt), rich text (.rtf,
/// .rtfd), web pages (.html) and plain text — are read by the text system that ships with macOS
/// and laid out onto pages on this Mac; the PDF carries real, selectable text. Nothing is sent
/// anywhere, and no other application is started.
///
/// Spreadsheets and presentations have no local renderer without the program that made them, so
/// they are refused with a sentence that says what does work: that program's own Print ▸ Save as
/// PDF, or the print route — the second command puts Zenit PDF into the system print dialog's
/// PDF menu, so any application's print job arrives here as a Quick PDF.
@MainActor
enum CreatePDFFromDocuments {

    static let openPanelIdentifier = "createPDF.chooseDocuments"
    static let savePanelIdentifier = "createPDF.savePDF"
    static let servicePanelIdentifier = "createPDF.printServiceAlias"
    static let refusalIdentifier = "createPDF.refused"
    static let resultNoteID = UUID(uuidString: "4C6D2E18-93A7-4B5F-A0D1-7E8F9A0B1C2D")!

    /// Opens the converted PDF. A test injects its own; the product opens a Quick PDF.
    static var opener: (@MainActor (URL) -> Void)?

    /// The extensions the text system reads.
    static let convertibleExtensions: Set<String> = ["docx", "doc", "odt", "rtf", "rtfd", "html", "htm", "txt", "text", "md"]
    /// Formats that need their own application.
    static let authoringOnlyExtensions: Set<String> = ["xlsx", "xls", "xlsm", "ods", "numbers", "csv", "pptx", "ppt", "odp", "key", "pages"]

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case needsAuthoringApp(String)
        case unreadable(String)
        case unknown(String)
        case empty(String)

        var description: String {
            switch self {
            case let .needsAuthoringApp(name):
                String(format: NSLocalizedString(
                    "“%@” is a spreadsheet or a presentation. Only the program that made it can lay it out faithfully: open it there and choose Print ▸ Save as PDF — or, after File ▸ Set Up “Print to Zenit PDF”…, choose Print ▸ PDF ▸ Zenit PDF, and it opens here.",
                    comment: "Create PDF refusal: spreadsheet or presentation; the file name"
                ), name)
            case let .unreadable(name):
                String(format: NSLocalizedString("“%@” could not be read as a text document.", comment: "Create PDF refusal: the text system could not read it; the file name"), name)
            case let .unknown(name):
                String(format: NSLocalizedString("“%@” is not a document type Zenit PDF can turn into a PDF.", comment: "Create PDF refusal: unknown type; the file name"), name)
            case let .empty(name):
                String(format: NSLocalizedString("“%@” has no text to put on a page.", comment: "Create PDF refusal: empty document; the file name"), name)
            }
        }
    }

    /// The page the text is laid out on: A4 where the metric system is used, Letter elsewhere,
    /// with 20 mm margins.
    struct PageSetup: Equatable, Sendable {
        var size: CGSize
        var margin: CGFloat

        static var standard: PageSetup {
            Locale.current.measurementSystem == .us
                ? PageSetup(size: CGSize(width: 612, height: 792), margin: 56.7)
                : PageSetup(size: CGSize(width: 595.276, height: 841.89), margin: 56.7)
        }
    }

    /// Reads one document into attributed text. Pure apart from reading the file.
    static func attributedText(of url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        if authoringOnlyExtensions.contains(ext) { throw Refusal.needsAuthoringApp(name) }
        guard convertibleExtensions.contains(ext) else { throw Refusal.unknown(name) }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch ext {
        case "txt", "text", "md":
            options[.documentType] = NSAttributedString.DocumentType.plain
            options[.characterEncoding] = String.Encoding.utf8.rawValue
        case "html", "htm":
            // Web pages are read as documents only: no network, no scripts. The text system's
            // HTML importer is asked not to load remote resources by giving it the data, not a URL.
            options[.documentType] = NSAttributedString.DocumentType.html
            options[.characterEncoding] = String.Encoding.utf8.rawValue
        case "docx": options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "doc": options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "odt": options[.documentType] = NSAttributedString.DocumentType.openDocument
        case "rtf": options[.documentType] = NSAttributedString.DocumentType.rtf
        case "rtfd": options[.documentType] = NSAttributedString.DocumentType.rtfd
        default: break
        }
        let text: NSAttributedString
        do {
            if ext == "rtfd" {
                text = try NSAttributedString(url: url, options: options, documentAttributes: nil)
            } else if ext == "html" || ext == "htm" {
                let data = localOnlyHTML(try Data(contentsOf: url))
                text = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            } else {
                let data = try Data(contentsOf: url)
                text = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            }
        } catch {
            throw Refusal.unreadable(name)
        }
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal.empty(name) }
        return text
    }

    /// The page's text and layout, without anything that could reach the network: scripts,
    /// styles' external references, frames, embedded objects, media and pictures are removed
    /// before the importer sees the page. Local-first: converting a document never fetches.
    static func localOnlyHTML(_ data: Data) -> Data {
        var html = String(decoding: data, as: UTF8.self)
        let patterns = [
            #"(?is)<script\b.*?</script\s*>"#,
            #"(?is)<style\b.*?</style\s*>"#,
            #"(?is)<(iframe|object|video|audio)\b.*?</\1\s*>"#,
            #"(?is)<(img|link|embed|source|iframe|object|video|audio|meta|base|input|track)\b[^>]*>"#,
            #"(?is)\s(src|srcset|background|poster|data)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
            #"(?is)url\s*\([^)]*\)"#
        ]
        for pattern in patterns {
            html = html.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return Data(html.utf8)
    }

    /// Lays `documents` out one after another, each starting on a new page, and returns the PDF.
    static func pdf(from documents: [NSAttributedString], page: PageSetup = .standard, title: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title, kCGPDFContextCreator: "Zenit PDF"] as CFDictionary)
        else { return Data() }
        let textSize = CGSize(width: page.size.width - 2 * page.margin, height: page.size.height - 2 * page.margin)
        for document in documents {
            let storage = NSTextStorage(attributedString: document)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            var containers: [NSTextContainer] = []
            // One container per page until every glyph has a place; capped so a hostile file
            // cannot ask for a million pages.
            repeat {
                let container = NSTextContainer(size: textSize)
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                containers.append(container)
                layout.ensureLayout(for: container)
            } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 5_000
            for container in containers {
                let range = layout.glyphRange(for: container)
                guard range.length > 0 || container === containers.first else { continue }
                context.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                // Flipped, so the text system's top-left origin lands at the page's top margin.
                context.translateBy(x: 0, y: page.size.height)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let origin = CGPoint(x: page.margin, y: page.margin)
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
                NSGraphicsContext.restoreGraphicsState()
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    /// Converts `urls` into one PDF at `destination`. Returns the page count.
    ///
    /// `destination` may never be a file one of `openDocuments` is made of — a drawing, a
    /// revision dropped on it, its own file, anything in its package (W-023): Replace in the save
    /// panel used to overwrite the front drawing, or a dropped revision that is the only copy in
    /// a Quick PDF. Refused before anything is read.
    @discardableResult
    static func convert(
        _ urls: [URL],
        to destination: URL,
        page: PageSetup = .standard,
        refusingFilesOf openDocuments: [ZenitPDFProjectDocument]
    ) throws -> Int {
        for document in openDocuments { try DerivedCopyGuard.refuseIfDocumentFile(destination, document: document) }
        let documents = try urls.map(attributedText(of:))
        let title = destination.deletingPathExtension().lastPathComponent
        let data = pdf(from: documents, page: page, title: title)
        try data.write(to: destination, options: .atomic)
        return CGPDFDocument(CGDataProvider(data: data as CFData)!)?.numberOfPages ?? 0
    }

    // MARK: - The print route

    /// Writes an alias of the application at `destination` — which the person chose, normally in
    /// the PDF Services folder — so the print dialog's PDF menu lists Zenit PDF and hands it any
    /// application's print job.
    static func writePrintServiceAlias(to destination: URL, application: URL = Bundle.main.bundleURL) throws {
        let bookmark = try application.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try URL.writeBookmarkData(bookmark, to: destination)
    }

    /// Where the print dialog looks for PDF services.
    static var pdfServicesFolder: URL {
        // The real home, not the container's: this is only the folder the save panel opens at.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: #"/Library/Containers/[^/]+/Data$"#, with: "", options: .regularExpression)
        return URL(fileURLWithPath: home).appendingPathComponent("Library/PDF Services", isDirectory: true)
    }

    // MARK: - Commands

    static func refuse(_ refusal: Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("No PDF was made.", comment: "Create PDF refusal title")
        alert.informativeText = (refusal as? Refusal)?.description ?? refusal.localizedDescription
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert dismissal"))
        ZenitModalPresenter.runAlert(alert, identifier: refusalIdentifier, sheetedOn: window) { _ in }
    }

    /// File ▸ New PDF from Documents…. The PDF made is remembered for Share Last Export… in the
    /// window the command ran from (R-028); the new PDF also opens on its own.
    static func run(window: NSWindow?) {
        let origin = window?.windowController?.document as? ZenitPDFProjectDocument
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.allowedContentTypes = convertibleExtensions.union(authoringOnlyExtensions).compactMap { UTType(filenameExtension: $0) }
        open.message = NSLocalizedString(
            "Choose Word, OpenDocument, rich-text, web or plain-text documents. They become one PDF, in the order chosen.",
            comment: "Create PDF open panel message"
        )
        ZenitModalPresenter.runOpenPanel(open, identifier: openPanelIdentifier, sheetedOn: window) { answer in
            guard case let .urls(sources) = answer, let first = sources.first else { return }
            // Refuse before asking where to save, so a spreadsheet is said at once.
            do { _ = try sources.map(attributedText(of:)) } catch { refuse(error, window: window); return }
            let save = NSSavePanel()
            save.allowedContentTypes = [.pdf]
            save.nameFieldStringValue = first.deletingPathExtension().lastPathComponent + ".pdf"
            ZenitModalPresenter.runSavePanel(save, identifier: savePanelIdentifier, sheetedOn: window) { chosen in
                guard let destination = chosen.firstURL else { return }
                do {
                    let open = NSDocumentController.shared.documents.compactMap { $0 as? ZenitPDFProjectDocument }
                    try convert(sources, to: destination, refusingFilesOf: open)
                    if let origin { ExportCompletion.remember(destination, document: origin) }
                    if let opener { opener(destination) } else {
                        NSDocumentController.shared.openDocument(withContentsOf: destination, display: true) { _, _, _ in }
                    }
                } catch {
                    refuse(error, window: window)
                }
            }
        }
    }

    /// File ▸ Set Up “Print to Zenit PDF”….
    static func setUpPrintService(window: NSWindow?) {
        let panel = NSSavePanel()
        panel.directoryURL = pdfServicesFolder
        panel.nameFieldStringValue = ZenitAppInfo.displayName
        panel.canCreateDirectories = true
        panel.message = NSLocalizedString(
            "Save the shortcut in the PDF Services folder of your Library. The print dialog's PDF menu then lists Zenit PDF, and anything printed to it opens here as a Quick PDF.",
            comment: "Print service save panel message"
        )
        ZenitModalPresenter.runSavePanel(panel, identifier: servicePanelIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            do {
                try writePrintServiceAlias(to: url)
            } catch {
                refuse(error, window: window)
            }
        }
    }
}
