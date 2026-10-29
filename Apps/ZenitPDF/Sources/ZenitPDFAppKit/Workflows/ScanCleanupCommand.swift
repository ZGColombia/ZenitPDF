import AppKit
import ZPDFAppCore
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// Tools ▸ Clean Up Scanned Sheets… (NL-PDF-12).
///
/// Straighten, rectify a phone photo, trim the scanner border, turn, enhance — written as a new
/// PDF at each sheet's own physical size and opened beside the original. The drawing this takeoff
/// was measured on is never changed, so no markup moves under a rotation it did not follow; the
/// new file starts uncalibrated and the note says so.
@MainActor
enum ScanCleanupCommand {

    static let panelIdentifier = "scanCleanup.savePanel"
    static let resultNoteID = UUID(uuidString: "2E7A9C41-5B3D-4F86-A1C2-9D0E8F7B6A53")!

    /// Opens the cleaned PDF. A test injects its own; the product opens a Quick PDF.
    static var opener: (@MainActor (URL) -> Void)?

    /// The note after a clean-up. Pure. `requestedDPI` is the resolution asked for, so a sheet
    /// cleaned below it, or copied uncleaned, is named (U-053).
    static func resultNote(reports: [ScanCleanup.PageReport], output: URL, labels: [Int: String], requestedDPI: Double = 200, now: Date = Date()) -> AppWarning {
        var parts: [String] = []
        func label(_ report: ScanCleanup.PageReport) -> String { labels[report.pageIndex] ?? String(report.pageIndex + 1) }
        let reduced = reports.filter { $0.wasReduced(from: requestedDPI) }.map { report in
            String(format: NSLocalizedString("%1$@ at %2$lld dpi", comment: "Scan clean-up: one sheet cleaned at a lower resolution; sheet label, dpi"),
                   label(report), Int64(report.renderedDPI ?? 0))
        }
        if !reduced.isEmpty {
            parts.append(String(format: NSLocalizedString("Too large for %1$lld dpi, cleaned at a lower resolution: %2$@.", comment: "Scan clean-up note: sheets cleaned below the requested resolution; requested dpi, sheet list"),
                                Int64(requestedDPI), reduced.joined(separator: ", ")))
        }
        let uncleaned = reports.filter { !$0.wasCleaned }.map(label)
        if !uncleaned.isEmpty {
            parts.append(String(format: NSLocalizedString("Not cleaned, copied as they were: %@. They could not be rendered as pictures.", comment: "Scan clean-up note: sheets that could not be cleaned; sheet list"),
                                uncleaned.joined(separator: ", ")))
        }
        let straightened = reports.compactMap { report -> String? in
            guard let skew = report.measuredSkew, abs(skew) >= 0.05 else { return nil }
            let label = labels[report.pageIndex] ?? String(report.pageIndex + 1)
            return String(format: NSLocalizedString("%1$@ by %2$@°", comment: "Scan clean-up: one sheet straightened; sheet label, degrees"),
                          label, String(format: "%.1f", locale: Locale.current, skew))
        }
        if !straightened.isEmpty {
            parts.append(String(format: NSLocalizedString("Straightened: %@.", comment: "Scan clean-up note: sheets straightened"),
                                straightened.joined(separator: ", ")))
        }
        let rectified = reports.filter(\.perspectiveCorrected).count
        if rectified > 0 {
            parts.append(String(format: NSLocalizedString("%lld photographed sheets rectified to their outline.", comment: "Scan clean-up note: perspective; count"), Int64(rectified)))
        }
        parts.append(NSLocalizedString(
            "The cleaned sheets are a new PDF, each at its own paper size; a trimmed or rectified sheet is the size of its cleaned picture, at one scale across and down. This takeoff's markups and scales stay with the original drawing; calibrate the new file before measuring on it.",
            comment: "Scan clean-up note: new file, uncalibrated"
        ))
        return AppWarning(
            id: resultNoteID,
            severity: uncleaned.isEmpty ? .info : .warning,
            title: String(format: NSLocalizedString("Cleaned up “%@”", comment: "Scan clean-up headline; the file name"), output.lastPathComponent),
            message: parts.joined(separator: " "),
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            isDismissible: true,
            timestamp: now
        )
    }

    /// The drawing a clean-up reads, with its password: the drawing of the sheet on screen
    /// (V-053). A PDF page index names a page only within one file, so in a project of several
    /// drawings the command used to look the current sheet up in the primary drawing, miss it,
    /// and rasterise every page of the primary instead.
    static func source(for document: ZenitPDFProjectDocument) -> (drawing: LoadedDrawing, password: String?, name: String)? {
        let current = document.core?.document.currentPageID
        guard let drawing = current.flatMap(document.loadedDrawing(forPage:)) ?? document.drawing else { return nil }
        let name = current.flatMap { document.drawingSet?.member(forPage: $0).displayName }
            ?? drawing.url.deletingPathExtension().lastPathComponent
        return (drawing, current.map(document.drawingPassword(forPage:)) ?? document.drawingPassword, name)
    }

    /// Cleans and writes; the half of the command worth asserting.
    static func run(document: ZenitPDFProjectDocument, options: ScanCleanup.Options, currentSheetOnly: Bool, to output: URL) async throws -> [ScanCleanup.PageReport] {
        guard let (drawing, password, _) = source(for: document) else { throw FlattenedDrawingExport.PreparationFailure.noDocument }
        var pages: Set<Int>?
        if currentSheetOnly, let current = document.core?.document.currentPageID,
           let page = drawing.pages.first(where: { $0.id.rawValue == current }) {
            pages = [page.index]
        }
        let input = drawing.url
        // "The original drawing is not changed": the panel may not name it (R-026), nor any other
        // drawing of the project.
        try DerivedCopyGuard.refuseIfSource(output, source: input)
        try DerivedCopyGuard.refuseIfDocumentFile(output, document: document)
        let reports = try await Task.detached(priority: .userInitiated) {
            try ScanCleanup.cleanDocument(at: input, password: password, to: output, pages: pages, options: options)
        }.value
        let labels = Dictionary(drawing.pages.map { ($0.index, $0.label.isEmpty ? String($0.index + 1) : $0.label) }, uniquingKeysWith: { first, _ in first })
        document.core?.document.post(resultNote(reports: reports, output: output, labels: labels, requestedDPI: options.dpi))
        ExportCompletion.remember(output, document: document)
        return reports
    }

    /// The save panel's message. In a project of several drawings it names the drawing cleaned —
    /// the one of the sheet on screen — since "All sheets" means that drawing's sheets (V-053).
    static func panelMessage(for document: ZenitPDFProjectDocument, drawingName: String) -> String {
        guard document.drawingSet?.isMultiDrawing == true else {
            return NSLocalizedString(
                "Save cleaned-up copies of the scanned sheets. Each chosen sheet becomes a picture at 200 dpi, at its own paper size; the original drawing is not changed.",
                comment: "Scan clean-up save panel message"
            )
        }
        return String(
            format: NSLocalizedString(
                "Save cleaned-up copies of the scanned sheets of “%@”, the drawing of the sheet on screen. Each chosen sheet becomes a picture at 200 dpi, at its own paper size; the original drawing is not changed.",
                comment: "Scan clean-up save panel message in a project of several drawings; the drawing's name"
            ),
            drawingName
        )
    }

    /// Tools ▸ Clean Up Scanned Sheets….
    static func present(document: ZenitPDFProjectDocument, window: NSWindow?) {
        guard let (_, _, name) = source(for: document) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name + " — "
            + NSLocalizedString("Cleaned", comment: "Scan clean-up file-name suffix") + ".pdf"
        panel.message = panelMessage(for: document, drawingName: name)
        let accessory = ScanCleanupAccessory()
        panel.accessoryView = accessory
        ZenitModalPresenter.runSavePanel(panel, identifier: panelIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            let options = accessory.options
            let currentOnly = accessory.currentSheetOnly
            Task { @MainActor in
                do {
                    _ = try await run(document: document, options: options, currentSheetOnly: currentOnly, to: url)
                    if let opener { opener(url) } else {
                        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                    }
                } catch {
                    ZenitErrorPresenter.present(error, in: window)
                }
            }
        }
    }
}

/// The save panel's choices for a clean-up.
@MainActor
final class ScanCleanupAccessory: NSView {

    let straighten = NSButton(checkboxWithTitle: NSLocalizedString("Straighten skewed sheets", comment: "Scan clean-up option"), target: nil, action: nil)
    let perspective = NSButton(checkboxWithTitle: NSLocalizedString("Correct the perspective of photographed sheets", comment: "Scan clean-up option"), target: nil, action: nil)
    let trim = NSButton(checkboxWithTitle: NSLocalizedString("Trim the scanner border", comment: "Scan clean-up option"), target: nil, action: nil)
    let turn = NSPopUpButton(frame: .zero, pullsDown: false)
    let enhance = NSPopUpButton(frame: .zero, pullsDown: false)
    let scope = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 190))
        straighten.state = .on
        turn.addItems(withTitles: [
            NSLocalizedString("Do not turn", comment: "Scan clean-up turn choice"),
            NSLocalizedString("Turn 90° clockwise", comment: "Scan clean-up turn choice"),
            NSLocalizedString("Turn 180°", comment: "Scan clean-up turn choice"),
            NSLocalizedString("Turn 90° counter-clockwise", comment: "Scan clean-up turn choice")
        ])
        enhance.addItems(withTitles: [
            NSLocalizedString("Keep colours", comment: "Scan clean-up enhancement choice"),
            NSLocalizedString("Grey, paper lifted to white", comment: "Scan clean-up enhancement choice"),
            NSLocalizedString("Black and white", comment: "Scan clean-up enhancement choice")
        ])
        enhance.selectItem(at: 1)
        scope.addItems(withTitles: [
            NSLocalizedString("All sheets", comment: "Scan clean-up scope choice"),
            NSLocalizedString("This sheet only", comment: "Scan clean-up scope choice")
        ])
        turn.setAccessibilityLabel(NSLocalizedString("Turn", comment: "Accessibility label: scan clean-up turn choice"))
        enhance.setAccessibilityLabel(NSLocalizedString("Enhance", comment: "Accessibility label: scan clean-up enhancement choice"))
        scope.setAccessibilityLabel(NSLocalizedString("Sheets to clean up", comment: "Accessibility label: scan clean-up scope choice"))
        for button in [straighten, perspective, trim] { button.setAccessibilityLabel(button.title) }
        let stack = NSStackView(views: [straighten, perspective, trim, turn, enhance, scope])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var currentSheetOnly: Bool { scope.indexOfSelectedItem == 1 }

    var options: ScanCleanup.Options {
        ScanCleanup.Options(
            straightens: straighten.state == .on,
            correctsPerspective: perspective.state == .on,
            trimsBorder: trim.state == .on,
            quarterTurns: max(0, turn.indexOfSelectedItem),
            enhancement: ScanCleanup.Options.Enhancement.allCases[max(0, min(2, enhance.indexOfSelectedItem))],
            dpi: 200
        )
    }
}
