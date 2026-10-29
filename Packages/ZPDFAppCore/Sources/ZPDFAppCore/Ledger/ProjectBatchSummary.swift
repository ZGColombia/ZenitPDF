import Foundation
import GRDB
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// NL-QTY-15 phase 2: a summary over **closed** projects — `.zpdfproj` packages the person picks,
/// opened read-only (nothing is written to them, not even a session marker), each drawing's
/// takeoff hydrated into a throwaway session and totalled by the same core path as an open
/// drawing (``TakeoffSession/subjectTotals()``), then combined exactly (``ProjectLedgerCombiner``:
/// same subject and unit add in `Decimal`, two units stay two lines).
///
/// A package that cannot be read — not a project, damaged, a newer format, no saved takeoff — is
/// not guessed at and not dropped silently: it is named with the reason (QUALITY_BAR A36).
public enum ProjectBatchSummary {

    /// One package that is not in the summary, and why.
    public struct Refusal: Hashable, Sendable {
        public let name: String
        public let reason: String
    }

    public struct Outcome: Sendable {
        public let drawings: [LedgerProjectSummary.Drawing]
        public let combined: [LedgerSubjectTotal]
        public let refused: [Refusal]
    }

    /// Summarises `urls` in order, in the display units and locale of `formatter`.
    public static func summarise(_ urls: [URL], units: DisplayUnitSelection, localeIdentifier: String) async -> Outcome {
        var drawings: [LedgerProjectSummary.Drawing] = []
        var refused: [Refusal] = []
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let parts = try await read(url, name: name, units: units, localeIdentifier: localeIdentifier)
                if parts.isEmpty {
                    refused.append(Refusal(name: name, reason: NSLocalizedString(
                        "It has no saved takeoff.", comment: "Batch summary: a project package without measurements"
                    )))
                }
                drawings.append(contentsOf: parts)
            } catch {
                refused.append(Refusal(name: name, reason: String(describing: error)))
            }
        }
        let formatter = QuantityFormatter(units: units, localeIdentifier: localeIdentifier)
        return Outcome(
            drawings: drawings,
            combined: ProjectLedgerCombiner.combine(drawings, formatter: formatter),
            refused: refused
        )
    }

    /// Every drawing of one package, totalled. Throws what the package cannot give.
    static func read(_ url: URL, name: String, units: DisplayUnitSelection, localeIdentifier: String) async throws -> [LedgerProjectSummary.Drawing] {
        let package = try await ProjectPackage.open(at: url, resolving: .openReadOnly)
        do {
            let documents = try await package.read { db in
                try Row.fetchAll(db, sql: "SELECT id, display_name FROM document ORDER BY created_at, id")
                    .map { (id: $0["id"] as String, name: $0["display_name"] as String? ?? "") }
            }
            var drawings: [LedgerProjectSummary.Drawing] = []
            for document in documents {
                guard let stored = try await TakeoffArchive.read(from: package, documentId: document.id),
                      stored.hasSavedTakeoff, !stored.markups.isEmpty
                else { continue }
                let pages = try await pageDescriptors(package: package, documentID: document.id)
                // A drawing none of whose sheets is in the set bills nothing. `restoreArrangement`
                // shows every page of an all-removed set rather than none, which is right for a
                // window and wrong for a total.
                guard pages.contains(where: { !stored.excludedPageIDs.contains($0.id) }) else { continue }
                guard let documentUUID = UUID(uuidString: document.id) else { continue }
                let session = try TakeoffSession(
                    documentID: DocumentID(documentUUID), pages: pages, units: units, localeIdentifier: localeIdentifier
                )
                _ = await session.restoreCustomColumns(stored.customColumns)
                _ = try await session.hydrate(
                    markups: stored.markups, scales: stored.scales, pageScaleIDs: stored.pageScaleIDs,
                    calibrationEvidence: stored.calibrationEvidence, scaleRegions: stored.scaleRegions,
                    projectZones: stored.projectZones
                )
                // Sheets removed from the set stay in the `page` table with their markups (NL-DOCS-07).
                // The open path sets those markups aside through this call, and without it the
                // summary billed them (R-047).
                await session.restoreArrangement(excluded: stored.excludedPageIDs, views: stored.pageViews)
                let title = documents.count > 1 && !document.name.isEmpty ? "\(name) — \(document.name)" : name
                drawings.append(.init(documentID: documentUUID, title: title, totals: try await session.subjectTotals()))
            }
            try? await package.close()
            return drawings
        } catch {
            try? await package.close()
            throw error
        }
    }

    /// The document's pages from the package's own page table: boxes and rotation as saved.
    static func pageDescriptors(package: ProjectPackage, documentID: String) async throws -> [ZPDFContracts.PageDescriptor] {
        let records = try await package.read { db in
            try PageRecord.fetchAll(db, sql: "SELECT * FROM page WHERE document_id = ? ORDER BY page_index", arguments: [documentID])
        }
        return try records.compactMap { record in
            guard let pageUUID = UUID(uuidString: record.id), let documentUUID = UUID(uuidString: record.documentId) else { return nil }
            return ZPDFContracts.PageDescriptor(
                id: PageID(pageUUID),
                documentID: DocumentID(documentUUID),
                index: record.pageIndex,
                label: record.pageLabel ?? "\(record.pageIndex + 1)",
                boxes: PageBoxes(
                    media: PDFRect(x: record.mediaX, y: record.mediaY, width: record.mediaWidth, height: record.mediaHeight),
                    crop: PDFRect(x: record.cropX, y: record.cropY, width: record.cropWidth, height: record.cropHeight)
                ),
                rotation: try ZPDFContracts.PageRotation.normalizing(degrees: record.rotation)
            )
        }
    }
}
