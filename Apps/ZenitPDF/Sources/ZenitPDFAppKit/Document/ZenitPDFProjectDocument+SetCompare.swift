import AppKit
import CoreGraphics
import CoreText
import Foundation
import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// The set compare report (NL-DOCS-13): every sheet of the set against its partner in the newest
/// revision — changed, unchanged, added, dropped, renamed — with the number of differences, the
/// measurements the differences touch, and how each pair was decided, as CSV and PDF. The
/// pairing section is part of the report, so a wrong pair is visible to whoever reads it.
/// A pair Revision Compare could not compare is reported `failed`, with the reason — never as
/// `unchanged` (U-079).
extension ZenitPDFProjectDocument {

    struct SetCompareRow: Sendable, Equatable {
        enum Status: String, Sendable {
            case changed, unchanged, added, dropped, renamed
            /// The comparison could not be made (a render, service or alignment fault): unknown,
            /// which is not the same claim as `unchanged` (U-079).
            case failed
        }
        var setSheet: String
        var revisionSheet: String
        var status: Status
        var differences: Int
        var affectedMeasurements: Int
        var evidence: String
    }

    static let setCompareReportPanelIdentifier = "documents.set-compare-report"

    /// Runs Revision Compare on every pair (or on the pairs of `only`) and builds the rows.
    /// Cancellable between sheets; a cancelled run returns what it has, marked incomplete, and a
    /// sheet whose comparison the cancel cut off gets no row.
    ///
    /// - Parameter compareSheet: the comparison each pair runs; `nil` is the document's
    ///   Revision Compare. A test injects one that fails.
    func setCompareRows(
        only: Set<UUID>? = nil,
        isCancelled: @Sendable () -> Bool = { false },
        compareSheet: (@Sendable (RevisionCompareRequest) async throws -> RevisionComparisonResult)? = nil
    ) async -> (rows: [SetCompareRow], complete: Bool) {
        guard let core, let comparator = revisionComparator, let compare = comparePresenter,
              let revision = newestRevision, let baselineID = compare.revisions.first(where: \.isBaseline)?.id,
              let baselineRef = revisionPages[baselineID], let revisionRef = revisionPages[revision.id],
              let drawing else { return ([], true) }
        let run = compareSheet ?? { try await comparator.compare($0) }
        let pairs = revisionSheetPairs[revision.id] ?? [:]
        let pairEvidence = revisionSheetPairEvidence[revision.id] ?? [:]
        let labels = revisionPageLabels[revision.id] ?? []
        let identities = await core.session.sheetIdentities
        let markups = await core.session.orderedMarkups
        let set = await core.session.pageDescriptors.filter { $0.documentID == drawing.documentID }
        var rows: [SetCompareRow] = []
        var complete = true
        for page in set where only?.contains(page.id.rawValue) ?? true {
            if isCancelled() { complete = false; break }
            let name = identities[page.id]?.number ?? page.label
            guard let partner = pairs[page.id.rawValue] else {
                rows.append(SetCompareRow(setSheet: name, revisionSheet: "—", status: .dropped, differences: 0, affectedMeasurements: 0,
                                          evidence: SheetMatchReviewModel.evidenceText(nil)))
                continue
            }
            var base = baselineRef
            base.pageIndex = page.index
            var revised = revisionRef
            revised.pageIndex = partner
            let request = RevisionCompareRequest(baseline: base, revised: revised, renderScale: 1, raster: compare.rasterOptions)
            let result: RevisionComparisonResult
            let revisionName = partner < labels.count ? labels[partner] : String(partner + 1)
            let renamed = SheetLabel.canonical(revisionName) != SheetLabel.canonical(name)
            let pairing = Self.setComparePairingText(pairEvidence[page.id.rawValue], renamed: renamed)
            do {
                result = try await run(request)
            } catch {
                // A cancel ends the run: this sheet was not compared, so it gets no row at all.
                if Self.isSetCompareCancellation(error) || isCancelled() { complete = false; break }
                // Any other fault is reported as what it is. The empty list it used to become
                // printed as "unchanged, 0 differences" — a sheet marked safe that nobody compared.
                rows.append(SetCompareRow(
                    setSheet: name, revisionSheet: revisionName, status: .failed, differences: 0, affectedMeasurements: 0,
                    evidence: Self.setCompareFailureText(pairing: pairing, error: error)
                ))
                continue
            }
            let diffs = CompareBridge.diffs(of: result, pageLabel: name, minimumAreaInSquarePoints: compare.minimumRegionAreaPoints)
            let regions = diffs.compactMap { $0.baselineBounds ?? $0.comparisonBounds }
            let affected = markups.filter { record in
                guard record.pageID == page.id, record.measurement != nil, let box = record.geometry?.bounds else { return false }
                return regions.contains { region in
                    region.minX <= box.maxX && box.minX <= region.maxX && region.minY <= box.maxY && box.minY <= region.maxY
                }
            }.count
            rows.append(SetCompareRow(
                setSheet: name,
                revisionSheet: revisionName,
                status: renamed ? .renamed : (diffs.isEmpty ? .unchanged : .changed),
                differences: diffs.count,
                affectedMeasurements: affected,
                evidence: pairing
            ))
        }
        if complete, only == nil {
            let taken = Set(pairs.values)
            for index in labels.indices where !taken.contains(index) {
                rows.append(SetCompareRow(setSheet: "—", revisionSheet: labels[index], status: .added, differences: 0, affectedMeasurements: 0,
                                          evidence: NSLocalizedString("Added in the revision", comment: "Sheet match review: revision sheets with no partner")))
            }
        }
        return (rows, complete)
    }

    /// The Pairing column for a paired sheet, from the evidence stored with the pair (U-080): a
    /// position fallback and a pair a person made say so. Only a sheet-number pair — or one
    /// stored before the evidence was kept — is told apart by its labels, exact or with a
    /// revision mark.
    static func setComparePairingText(_ evidence: RevisionSheetRecord.Evidence?, renamed: Bool) -> String {
        switch evidence {
        case .position?: SheetMatchReviewModel.evidenceText(.positionFallback)
        case .manual?: SheetMatchReviewModel.evidenceText(.manualOverride)
        case .label?, .added?, nil: SheetMatchReviewModel.evidenceText(renamed ? .normalisedLabel : .exactLabel)
        }
    }

    /// Whether a comparison's error is the run being cancelled rather than a fault.
    static func isSetCompareCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? CompareFault) == .cancelled
    }

    /// The Pairing column of a sheet that could not be compared: how it was paired, and why the
    /// comparison failed.
    static func setCompareFailureText(pairing: String, error: any Error) -> String {
        String(
            format: NSLocalizedString("%1$@; not compared: %2$@", comment: "Set compare report: how the pair was decided, and why its comparison failed"),
            pairing, String(describing: error)
        )
    }

    /// The report header's line for sheets that could not be compared, or `nil` when every pair
    /// was compared.
    static func setCompareFailureNote(_ rows: [SetCompareRow]) -> String? {
        let failed = rows.filter { $0.status == .failed }.count
        guard failed > 0 else { return nil }
        return String(
            format: NSLocalizedString(
                "%d sheets could not be compared and are listed as failed, not as unchanged.",
                comment: "Set compare report header note; the count of sheets whose comparison failed"),
            failed
        )
    }

    /// The report as CSV: a header and one line per sheet, through the app's one CSV field rule
    /// (V-022). The sheet names come from the revision PDF's own page labels, so a label such as
    /// `=HYPERLINK(…)` used to reach the spreadsheet as a live formula; it is text now, and a
    /// field with a carriage return is quoted.
    static func setCompareCSV(_ rows: [SetCompareRow]) -> String {
        func field(_ text: String) -> String { LedgerCSVExport.field(text) }
        var lines = ["Sheet,Revision sheet,Status,Differences,Affected measurements,Pairing"]
        for row in rows {
            lines.append([
                field(row.setSheet), field(row.revisionSheet), row.status.rawValue,
                String(row.differences), String(row.affectedMeasurements), field(row.evidence)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The report as a PDF table, US Letter landscape, as many pages as it needs.
    static func writeSetComparePDF(_ rows: [SetCompareRow], title: String, complete: Bool, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 792, height: 612)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let columns: [(String, CGFloat)] = [
            (NSLocalizedString("Sheet", comment: "Set compare report column"), 40),
            (NSLocalizedString("Revision sheet", comment: "Set compare report column"), 150),
            (NSLocalizedString("Status", comment: "Set compare report column"), 270),
            (NSLocalizedString("Differences", comment: "Set compare report column"), 360),
            (NSLocalizedString("Affected", comment: "Set compare report column: measurements the differences touch"), 450),
            (NSLocalizedString("Pairing", comment: "Set compare report column: how the pair was decided"), 530)
        ]
        func draw(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool = false) {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = point
            CTLineDraw(line, context)
        }
        var index = 0
        repeat {
            context.beginPDFPage(nil)
            draw(title, at: CGPoint(x: 40, y: 570), size: 16, bold: true)
            if !complete {
                draw(NSLocalizedString("Incomplete: the comparison was cancelled.", comment: "Set compare report note"), at: CGPoint(x: 40, y: 552), size: 10)
            }
            if let failures = setCompareFailureNote(rows) {
                draw(failures, at: CGPoint(x: complete ? 40 : 280, y: 552), size: 10)
            }
            for column in columns { draw(column.0, at: CGPoint(x: column.1, y: 530), size: 10, bold: true) }
            var y: CGFloat = 512
            while index < rows.count, y > 40 {
                let row = rows[index]
                let values = [row.setSheet, row.revisionSheet, row.status.rawValue, String(row.differences), String(row.affectedMeasurements), row.evidence]
                for (column, value) in zip(columns, values) { draw(value, at: CGPoint(x: column.1, y: y), size: 9) }
                y -= 16
                index += 1
            }
            context.endPDFPage()
        } while index < rows.count
        context.closePDF()
    }

    /// Why Set Compare Report… wrote nothing: the set has no revision yet, and how to add one —
    /// the menu command first (L-57: the ⌥ drop from Finder was the only way, and the only one
    /// named).
    static var setCompareNoRevisionNote: String {
        String(
            format: NSLocalizedString(
                "The set has no revision to compare with. Choose %@, or hold ⌥ and drop the revised PDF on the canvas, to add one first.",
                comment: "Status note: Set Compare Report found no revision in the project; the Add Revision menu command's path in the menu bar"
            ),
            ZenitAppCommandTable.menuPath(for: .addRevision)
        )
    }

    /// Set Compare Report…: asks for one file — a PDF, or a CSV when the name says `.csv` — and
    /// writes the report there.
    ///
    /// One file, the one the save panel granted (W-020). The report used to write its CSV beside
    /// the chosen PDF, a sibling the sandbox never granted: in the shipped application the PDF
    /// was written, the CSV write was refused, and the refusal was the only note the person saw.
    func exportSetCompareReport(window: NSWindow?) {
        guard newestRevision != nil else {
            // The whole set's refusal, not the sheet card's borrowed sentence (V-029).
            core?.status.setActiveToolNote(Self.setCompareNoRevisionNote)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf, .commaSeparatedText]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = (displayName ?? "Set") + " compare.pdf"
        panel.message = NSLocalizedString(
            "Save the set compare report as a PDF, or change the name to .csv for a spreadsheet.",
            comment: "Save panel message for Set Compare Report"
        )
        ZenitModalPresenter.runSavePanel(panel, identifier: Self.setCompareReportPanelIdentifier, sheetedOn: window) { [weak self] answer in
            guard let destination = answer.firstURL else { return }
            Task { @MainActor [weak self] in await self?.writeSetCompareReport(to: destination) }
        }
    }

    /// The half of Set Compare Report… after the panel: compares the set and writes the report
    /// to `destination` — CSV when its name ends in `.csv`, PDF otherwise — and says so in the
    /// status bar. Answers whether the report was written.
    @discardableResult
    func writeSetCompareReport(to destination: URL) async -> Bool {
        // U-017: the report may never replace a file the document is made of. Asked before the
        // comparison runs, so a refused name costs nothing.
        do {
            try DerivedCopyGuard.refuseIfDocumentFile(destination, document: self)
        } catch {
            core?.status.setActiveToolNote((error as? DerivedCopyGuard.Refusal)?.errorDescription ?? String(describing: error))
            return false
        }
        core?.status.setActiveToolNote(NSLocalizedString("Comparing the set…", comment: "Status note while the set compare runs"))
        let (rows, complete) = await setCompareRows()
        do {
            if destination.pathExtension.lowercased() == "csv" {
                try Self.setCompareCSV(rows).write(to: destination, atomically: true, encoding: .utf8)
            } else {
                let title = String(format: NSLocalizedString("Set compare: %@", comment: "Set compare report title; the revision"), newestRevision?.revisionLabel ?? "")
                try Self.writeSetComparePDF(rows, title: title, complete: complete, to: destination)
            }
            ExportCompletion.remember(destination, document: self)   // R-028
            let written = String(
                format: NSLocalizedString("Set compare report written: %d sheets.", comment: "Status note after the set compare report; the count"),
                rows.count
            )
            core?.status.setActiveToolNote(Self.setCompareFailureNote(rows).map { written + " " + $0 } ?? written)
            return true
        } catch {
            core?.status.setActiveToolNote(String(describing: error))
            return false
        }
    }
}
