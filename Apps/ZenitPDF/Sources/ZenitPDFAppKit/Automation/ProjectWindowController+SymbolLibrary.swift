import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIWorkflows
import ZPDFVectorExtraction

/// NL-AUTO-17: the local symbol library — save a confirmed symbol from the review, and search a
/// sheet for every saved symbol at once. Learning by example, with no training and no upload.
extension ProjectWindowController {

    /// Overridable so tests keep out of the real container.
    static var symbolLibraryURLOverride: URL?

    /// `Application Support/Zenit PDF/Symbols/library.json` in the assembled bundle, a
    /// per-process temporary file everywhere else.
    static var symbolLibrary: SymbolLibrary {
        if let symbolLibraryURLOverride { return SymbolLibrary(fileURL: symbolLibraryURLOverride) }
        let directory: URL
        if Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            directory = base.appendingPathComponent(ZenitAppInfo.displayName, isDirectory: true)
                .appendingPathComponent("Symbols", isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(ZenitAppInfo.displayName, isDirectory: true)
                .appendingPathComponent("Symbols-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return SymbolLibrary(fileURL: directory.appendingPathComponent("library.json"))
    }

    /// The most library symbols one search runs, newest first, stated when it bites.
    static let librarySearchCap = 24

    func saveToSymbolLibrary(designation: String, exemplar: SymbolExemplar, core: AppCoreEnvironment) {
        do {
            try Self.symbolLibrary.add(designation: designation, exemplar: exemplar)
        } catch {
            core.status.setActiveToolNote(String(
                format: NSLocalizedString(
                    "The symbol was counted but not saved to the library: %@",
                    comment: "Status note when writing the symbol library failed; the reason"
                ),
                String(describing: error)
            ))
        }
    }

    func findLibrarySymbols(for document: ZenitPDFProjectDocument) {
        Task { @MainActor in
            guard let core = document.core, let drawing = document.currentPageDrawing,
                  let currentID = core.document.currentPageID,
                  let page = drawing.pages.first(where: { $0.id.rawValue == currentID }) else { return }
            let entries: [SymbolLibraryEntry]
            do {
                entries = try Self.symbolLibrary.entries()
            } catch {
                core.status.setActiveToolNote(String(
                    format: NSLocalizedString(
                        "The symbol library could not be read: %@",
                        comment: "Status note when the symbol library file is unreadable; the reason"
                    ),
                    String(describing: error)
                ))
                return
            }
            guard !entries.isEmpty else {
                core.status.setActiveToolNote(NSLocalizedString(
                    "The symbol library is empty. Tick “Save this symbol to the library” in a symbol review to add one.",
                    comment: "Status note when searching an empty symbol library"
                ))
                return
            }
            let primitives: [VectorPrimitive]
            do {
                primitives = try await self.symbolSearchPrimitives(for: document, page: page)
            } catch {
                core.status.setActiveToolNote(Self.symbolScheduleExtractionFailureNote(error))
                return
            }
            let searched = Array(entries.prefix(Self.librarySearchCap))
            let existing = await Self.existingCountPoints(session: core.session)[page.id] ?? []
            // Library symbols are held to their own style as well as their shape (NL-AUTO-13):
            // a saved red door does not claim the grey ones.
            var options = SymbolMatchOptions.standard
            options.styleGate = [.strokeColor, .strokeWidth]
            var groups: [(designation: String, results: [SymbolCountPageResult], exemplar: SymbolExemplar)] = []
            var rows: [SymbolCountReviewRow] = []
            var others = 0
            var truncated = false
            let label = Self.pageLabel(page, core: core)
            for (index, entry) in searched.enumerated() {
                let exemplar = entry.exemplar
                let gate = options
                guard let report = await Task.detached(priority: .userInitiated, operation: {
                    try? SymbolMatcher().matches(exemplar: exemplar, in: primitives, options: gate)
                }).value else { continue }
                let result = SymbolCountReviewBuilder().pageResult(
                    pageID: page.id, pageIndex: page.index, exemplar: exemplar, report: report,
                    existing: existing, idOffset: (index + 1) * 10_000_000
                )
                // A library search lists what matched; each symbol's near misses stay with its
                // own review, or this list would be every near miss of every saved symbol.
                let kept = result.candidates.filter { if case .nearMiss = $0.status { false } else { true } }
                guard !kept.isEmpty else { continue }
                others += result.otherShapeCount
                truncated = truncated || result.wasTruncated
                groups.append((entry.designation, [result], exemplar))
                rows += kept.map {
                    let row = Self.reviewRow($0, pageLabel: label)
                    return SymbolCountReviewRow(
                        id: row.id, pageIndex: row.pageIndex, pageLabel: row.pageLabel, position: row.position,
                        bounds: row.bounds, status: row.status, detail: row.detail, isExemplar: false,
                        designation: entry.designation
                    )
                }
            }
            guard !rows.isEmpty else {
                core.status.setActiveToolNote(String(
                    format: NSLocalizedString(
                        "None of the %d library symbols is on this page.",
                        comment: "Status note when a library search found nothing; how many symbols were searched"
                    ),
                    searched.count
                ))
                return
            }
            let box = SheetDismissBox()
            let found = groups
            let model = SymbolCountReviewModel(
                designation: NSLocalizedString("Library symbols", comment: "Symbol review title field for a library search"),
                pageTotal: 1,
                onAccept: { [weak self, weak document] outcome in
                    box.dismiss()
                    guard let self, let document else { return }
                    self.canvasController(for: document)?.setAutomationOverlay(nil)
                    Task { @MainActor in
                        await self.landSymbolCounts(groups: found, selected: outcome.selectedRowIDs, core: core)
                    }
                },
                onCancel: { [weak self, weak document] in
                    box.dismiss()
                    guard let self, let document else { return }
                    self.canvasController(for: document)?.setAutomationOverlay(nil)
                },
                onReveal: { [weak self, weak document] row in
                    guard let self, let document else { return }
                    self.canvasController(for: document)?.revealPageRect(row.bounds, highlight: true)
                }
            )
            model.append(
                page: SymbolCountReviewPage(pageIndex: page.index, pageLabel: label, otherShapeCount: others, isTruncated: truncated),
                rows: rows
            )
            var overlay = CanvasAutomationOverlay()
            overlay.hits = rows.map(\.bounds)
            self.canvasController(for: document)?.setAutomationOverlay(overlay)
            if entries.count > searched.count {
                core.status.setActiveToolNote(String(
                    format: NSLocalizedString(
                        "Searched the %1$d newest of %2$d library symbols.",
                        comment: "Status note when the library search cap applied"
                    ),
                    searched.count, entries.count
                ))
            }
            box.dismiss = Self.symbolReviewPresenter(model, self.window)
        }
    }
}
