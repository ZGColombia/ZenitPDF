import AppKit
import Foundation
import SwiftUI
import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFUIPresentation

/// Revisions matched by sheet number, reviewed and kept (NL-DOCS-11), and the card's Compare
/// with Previous Revision.
extension ZenitPDFProjectDocument {

    static let sheetMatchReviewIdentifier = "documents.sheet-match-review"

    /// How the review reaches the screen, returning its dismissal. A test injects a capture;
    /// nothing is shown outside the assembled bundle.
    static var sheetMatchReviewPresenter: (@MainActor (SheetMatchReviewModel, String, NSWindow?) -> () -> Void) = { model, revisionID, window in
        guard ZenitModalPresenter.canPresentModally, let window else { return {} }
        let host = NSHostingController(rootView: SheetMatchReviewView(model: model, revisionID: revisionID))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled, .resizable]
        // Through the one modal door: recorded, and refused on a visible window in a
        // process with no user (R-039).
        ZenitModalPresenter.beginSheet(panel, on: window, identifier: ZenitPDFProjectDocument.sheetMatchReviewIdentifier) {}
        return { [weak window, weak panel] in
            guard let window, let panel else { return }
            window.endSheet(panel)
        }
    }

    /// The set sheets a revision is matched against: every sheet of the project's primary
    /// drawing, named by its sheet number when it has one, in set order.
    func matchableSetSheets() async -> [(pageID: String, label: String, explicit: Bool, size: CGSize, pdfIndex: Int)] {
        guard let core, let drawing else { return [] }
        let identities = await core.session.sheetIdentities
        return await core.session.pageDescriptors.filter { $0.documentID == drawing.documentID }.map { page in
            let number = identities[page.id]?.number
            let label = number ?? page.label
            let explicit = number != nil || (!page.label.isEmpty && !page.label.allSatisfy(\.isNumber))
            let box = page.boxes.crop
            return (page.id.rawValue.uuidString, label, explicit, CGSize(width: box.size.width, height: box.size.height), page.index)
        }
    }

    /// The matcher's pairing of the set with a revision.
    static func matchSheets(
        set: [(pageID: String, label: String, explicit: Bool, size: CGSize, pdfIndex: Int)],
        revision: [(label: String, explicit: Bool, size: CGSize)]
    ) -> SheetMatching {
        let old = set.enumerated().map { SetSheet(index: $0.offset, label: $0.element.label, sizeInPoints: $0.element.size, labelIsExplicit: $0.element.explicit) }
        let new = revision.enumerated().map { SetSheet(index: $0.offset, label: $0.element.label, sizeInPoints: $0.element.size, labelIsExplicit: $0.element.explicit) }
        return (try? SheetMatcher.standard.match(old: old, new: new)) ?? .empty
    }

    /// Opens the review for a just-kept revision and stores the confirmed pairings.
    func reviewSheetMatching(summaryID: UUID, revisionRowID: String, name: String, handle: DocumentHandle, provider: PDFKitDocumentProvider) async {
        guard let package = projectPackage else { return }
        let set = await matchableSetSheets()
        let descriptors = (try? await provider.pageDescriptors(of: handle, range: nil)) ?? []
        let revision = descriptors.map { page in
            (label: page.label, explicit: page.labelIsExplicit,
             size: CGSize(width: page.boxes.crop.width, height: page.boxes.crop.height))
        }
        let matching = Self.matchSheets(set: set, revision: revision)
        let model = SheetMatchReviewModel(
            revisionName: name,
            setSheets: set.map { ($0.pageID, $0.label) },
            revisionLabels: revision.map(\.label),
            matching: matching
        )
        adoptSheetPairs(model.pairings(revisionID: revisionRowID), summaryID: summaryID)
        var dismiss: () -> Void = {}
        model.onCancel = { dismiss() }
        model.onAccept = { [weak self] records in
            dismiss()
            guard let self else { return }
            self.adoptSheetPairs(records, summaryID: summaryID)
            Task { @MainActor in
                try? await package.write { db in
                    let documentId = try String.fetchOne(db, sql: "SELECT document_id FROM revision_entry WHERE id = ?", arguments: [revisionRowID])
                    guard let documentId,
                          let entry = try DocumentSetStore.revisions(document: documentId, in: db).first(where: { $0.id == revisionRowID })
                    else { return }
                    try DocumentSetStore.upsertRevision(entry, sheets: records, in: db)
                }
                await package.registerEdit()
                self.updateChangeCount(.changeDone)
            }
        }
        dismiss = Self.sheetMatchReviewPresenter(model, revisionRowID, windowForSheet)
        for shell in allWindowShells { shell.hasPreviousRevision = true }   // NL-UX-20: every window
    }

    /// Remembers which revision page each set sheet pairs with, and on what evidence (U-080).
    func adoptSheetPairs(_ records: [RevisionSheetRecord], summaryID: UUID) {
        var pairs: [UUID: Int] = [:]
        var evidence: [UUID: RevisionSheetRecord.Evidence] = [:]
        for record in records {
            guard let id = record.pageId.flatMap(UUID.init(uuidString:)) else { continue }
            pairs[id] = record.revisionPageIndex
            evidence[id] = RevisionSheetRecord.Evidence(rawValue: record.evidence)
        }
        revisionSheetPairs[summaryID] = pairs
        revisionSheetPairEvidence[summaryID] = evidence
    }

    /// The newest revision that is not the drawing itself.
    var newestRevision: RevisionSummary? {
        comparePresenter?.revisions.last { !$0.isBaseline }
    }

    /// Compare with Previous Revision (NL-DOCS-11): the sheet against its partner in the
    /// newest revision, by the stored pairing (else by sheet number), in Revision Compare.
    /// Answers whether there is a partner to compare with.
    @discardableResult
    func prepareCompareWithPreviousRevision(pageID: UUID) -> Bool {
        guard let compare = comparePresenter, let revision = newestRevision,
              let baselineID = compare.revisions.first(where: \.isBaseline)?.id,
              let drawing, let page = drawing.pages.first(where: { $0.id.rawValue == pageID }),
              var baselinePage = revisionPages[baselineID], var revisionPage = revisionPages[revision.id] else {
            core?.status.setActiveToolNote(NSLocalizedString(
                "This sheet has no earlier revision to compare with.",
                comment: "Status note: Compare with Previous Revision found no partner"
            ))
            return false
        }
        let partner: Int
        if let stored = revisionSheetPairs[revision.id]?[pageID] {
            partner = stored
        } else {
            let labels = revisionPageLabels[revision.id] ?? []
            let pairing = Self.pairRevisionPage(currentIndex: page.index, baselineLabel: page.label, revisionLabels: labels, revisionPageCount: revision.pageCount)
            if case .mismatch = pairing {
                core?.status.setActiveToolNote(NSLocalizedString(
                    "This sheet has no earlier revision to compare with.",
                    comment: "Status note: Compare with Previous Revision found no partner"
                ))
                return false
            }
            partner = pairing.pageIndex
        }
        baselinePage.pageIndex = page.index
        revisionPage.pageIndex = partner
        revisionPages[baselineID] = baselinePage
        revisionPages[revision.id] = revisionPage
        if let baseline = compare.revisions.first(where: { $0.id == baselineID }) { compare.addRevision(baseline, page: baselinePage) }
        compare.addRevision(revision, page: revisionPage)
        compare.setBaseline(id: baselineID)
        compare.setComparison(id: revision.id)
        return true
    }
}
