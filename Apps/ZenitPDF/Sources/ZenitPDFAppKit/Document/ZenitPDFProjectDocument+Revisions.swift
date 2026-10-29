import CryptoKit
import Foundation
import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFUIPresentation

/// Revisions kept with the project and paired by sheet number.
///
/// Before: a dropped revision lived in the session only ("nothing is persisted") and was gone
/// after close, and Revision Overlay paired every revision's page by the canvas's page *index*,
/// so on a revision with one sheet inserted every later sheet was overlaid on a different sheet,
/// with no warning.
extension ZenitPDFProjectDocument {

    // MARK: Pairing

    /// How one revision page was chosen for the sheet on screen.
    enum RevisionPairing: Equatable {
        /// The revision has a page with the same sheet number (label).
        case label(Int)
        /// No usable label: same position, clamped to the revision's page count.
        case position(Int)
        /// The labels say this is a different sheet and no page carries this sheet's number:
        /// paired by position, and said.
        case mismatch(Int)

        var pageIndex: Int {
            switch self {
            case let .label(index), let .position(index), let .mismatch(index): return index
            }
        }
    }

    /// The revision page for the sheet at `currentIndex` whose label is `baselineLabel`.
    ///
    /// A label pairs only when it is a real sheet number: a bare-number label is the reader's
    /// fallback and says nothing about which sheet a page is.
    nonisolated static func pairRevisionPage(
        currentIndex: Int,
        baselineLabel: String?,
        revisionLabels: [String],
        revisionPageCount: Int
    ) -> RevisionPairing {
        let clamped = Swift.max(0, Swift.min(currentIndex, Swift.max(0, revisionPageCount - 1)))
        func isName(_ label: String) -> Bool { !label.isEmpty && !label.allSatisfy(\.isNumber) }
        let normalised = { (label: String) in label.trimmingCharacters(in: .whitespaces).uppercased() }
        guard let baselineLabel, isName(baselineLabel) else { return .position(clamped) }
        let wanted = normalised(baselineLabel)
        let matches = revisionLabels.indices.filter { normalised(revisionLabels[$0]) == wanted }
        if matches.count == 1 { return .label(matches[0]) }
        if matches.count > 1 {
            // Two pages claim the number: the one nearest the position, never a guess elsewhere.
            return .label(matches.min { abs($0 - clamped) < abs($1 - clamped) } ?? matches[0])
        }
        let revisionHasNames = revisionLabels.contains(where: isName)
        return revisionHasNames ? .mismatch(clamped) : .position(clamped)
    }

    /// Every revision page's partner in the set, with the evidence, for `revision_sheet`.
    nonisolated static func sheetPairings(
        revisionLabels: [String],
        setPages: [(id: String, label: String)]
    ) -> [RevisionSheetRecord] {
        func isName(_ label: String) -> Bool { !label.isEmpty && !label.allSatisfy(\.isNumber) }
        var byLabel: [String: String] = [:]
        for page in setPages where isName(page.label) {
            byLabel[page.label.uppercased()] = byLabel[page.label.uppercased()] ?? page.id
        }
        return revisionLabels.enumerated().map { index, label in
            if isName(label), let id = byLabel[label.uppercased()] {
                return RevisionSheetRecord(revisionId: "", revisionPageIndex: index, pageId: id, evidence: RevisionSheetRecord.Evidence.label.rawValue)
            }
            if !isName(label), index < setPages.count {
                return RevisionSheetRecord(revisionId: "", revisionPageIndex: index, pageId: setPages[index].id, evidence: RevisionSheetRecord.Evidence.position.rawValue)
            }
            return RevisionSheetRecord(revisionId: "", revisionPageIndex: index, pageId: nil, evidence: RevisionSheetRecord.Evidence.added.rawValue)
        }
    }

    /// Revision Overlay's pages for the sheet on screen, each revision paired by sheet number.
    /// A pairing the labels contradict is posted to the warning tray once per revision and sheet
    /// (U-014) — unless `postsWarnings` is false, for a caller that only counts the pages.
    ///
    /// The sheet on screen is resolved by identity (X-016). Its index is local to its own PDF,
    /// and the revisions are the primary drawing's: on sheet i of an added drawing, the primary's
    /// sheet i used to be composited as the baseline and its label paired the revisions — another
    /// sheet's revision drawn over this one, with no warning when the labels lined up. A sheet of
    /// another drawing gets no overlay pages, and the tray says once why.
    func labelPairedOverlayPages(for windowCore: AppCoreEnvironment?, postsWarnings: Bool = true) -> [RevisionSummary.ID: RevisionPageReference] {
        let onScreen = windowCore.flatMap { pageDescriptor(forPage: $0.canvas.viewport.pageID) }
        if let onScreen, !isPrimaryDrawingPage(onScreen) {
            if postsWarnings { postRevisionsBelongToPrimaryDrawing(in: windowCore) }
            return [:]
        }
        let current = onScreen?.index ?? windowCore?.canvas.viewport.pageIndex ?? 0
        let baselineLabel = onScreen?.label ?? drawing?.pages.first { $0.index == current }?.label
        let counts = Dictionary(
            (comparePresenter?.revisions ?? []).map { ($0.id, $0.pageCount) },
            uniquingKeysWith: { first, _ in first }
        )
        var pages: [RevisionSummary.ID: RevisionPageReference] = [:]
        for (id, reference) in revisionPages {
            var moved = reference
            let pairing: RevisionPairing
            if let labels = revisionPageLabels[id] {
                pairing = Self.pairRevisionPage(
                    currentIndex: current, baselineLabel: baselineLabel,
                    revisionLabels: labels, revisionPageCount: counts[id] ?? labels.count
                )
            } else {
                // The baseline itself follows the canvas.
                pairing = .position(Swift.max(0, Swift.min(current, (counts[id] ?? Int.max) - 1)))
            }
            moved.pageIndex = pairing.pageIndex
            pages[id] = moved
            if postsWarnings, case .mismatch = pairing, let baselineLabel {
                postRevisionPairingWarning(revision: id, revisionLabel: reference.label, sheet: baselineLabel, in: windowCore)
            }
        }
        return pages
    }

    /// Says once that Revision Overlay has nothing to stack on a sheet of an added drawing: the
    /// revisions are the primary drawing's (X-016). Once per document, under a stable identity,
    /// since the overlay re-pairs on every composite.
    private func postRevisionsBelongToPrimaryDrawing(in windowCore: AppCoreEnvironment?) {
        guard let core = windowCore ?? core else { return }
        let key = "primary-drawing-only"
        guard revisionPairingsWarned.insert(key).inserted else { return }
        core.document.post(
            AppWarning(
                id: Self.revisionPairingWarningID(key),
                severity: .warning,
                title: String(
                    format: NSLocalizedString(
                        "Revisions belong to “%@”",
                        comment: "Revision Overlay warning on a sheet of an added drawing: the primary drawing's name"
                    ),
                    drawingSet?.primary.displayName ?? displayName ?? ""
                ),
                message: NSLocalizedString(
                    "Revision Overlay stacks the revisions of the project's first drawing. This sheet comes from another drawing, so nothing is stacked on it.",
                    comment: "Revision Overlay warning detail: the sheet on screen is from an added drawing"
                ),
                source: NSLocalizedString("Revision Overlay", comment: "Warning source"),
                timestamp: Date()
            )
        )
    }

    /// Says once that a revision has no page for a sheet. The overlay re-pairs on every
    /// composite — each zoom, page turn and opacity drag — and a fresh identity per post stacked
    /// one copy of this warning per request (U-014). Now it is said once per revision and sheet,
    /// under an identity derived from both, so even a second window's post replaces it.
    private func postRevisionPairingWarning(revision: RevisionSummary.ID, revisionLabel: String, sheet: String, in windowCore: AppCoreEnvironment?) {
        guard let core = windowCore ?? core else { return }
        let key = "\(revision.uuidString)|\(sheet.uppercased())"
        guard revisionPairingsWarned.insert(key).inserted else { return }
        core.document.post(
            AppWarning(
                id: Self.revisionPairingWarningID(key),
                severity: .warning,
                title: String(
                    format: NSLocalizedString(
                        "%1$@ has no sheet %2$@",
                        comment: "Revision Overlay warning: revision name, sheet number"
                    ),
                    revisionLabel, sheet
                ),
                message: NSLocalizedString(
                    "The overlay shows the page in the same position, which is a different sheet.",
                    comment: "Revision Overlay warning detail: paired by position against the labels"
                ),
                source: NSLocalizedString("Revision Overlay", comment: "Warning source"),
                timestamp: Date()
            )
        )
    }

    /// A stable identity for one revision-and-sheet warning: the first sixteen bytes of the
    /// key's SHA-256, shaped as a version-5-style UUID.
    nonisolated static func revisionPairingWarningID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("revision-overlay-pairing|" + key).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: Persistence

    /// Reads a just-opened revision's page labels and, in Project Mode, keeps the file in the
    /// package with its sheet pairings. A Quick PDF has no package: the revision stays for this
    /// session only, as before.
    func keepRevision(summaryID: UUID, url: URL, handle: DocumentHandle, provider: PDFKitDocumentProvider, label: String) async {
        let labels = (try? await provider.pageLabels(of: handle).allLabels()) ?? []
        revisionPageLabels[summaryID] = labels
        guard let package = projectPackage, !restoringRevisions else { return }
        let setPages = (drawing?.pages ?? []).map { (id: $0.id.rawValue.uuidString, label: $0.label) }
        do {
            let documentId = try await package.read { db in
                try String.fetchOne(db, sql: "SELECT id FROM document ORDER BY created_at, id LIMIT 1")
            }
            guard let documentId else { return }
            let row = try await package.addRevision(
                pdf: url, documentId: documentId, label: label, pageCount: labels.count,
                sheets: Self.sheetPairings(revisionLabels: labels, setPages: setPages)
            )
            persistedRevisionIDs[summaryID] = row.id
            await package.registerEdit()
            updateChangeCount(.changeDone)
            // Matched by sheet number, reviewed before it is trusted (NL-DOCS-11).
            await reviewSheetMatching(summaryID: summaryID, revisionRowID: row.id, name: label, handle: handle, provider: provider)
        } catch {
            // The revision is still open for this session; the tray says it was not kept.
            core?.document.post(AppWarning(
                id: UUID(),
                severity: .warning,
                title: NSLocalizedString(
                    "The revision opened, but the project could not keep it.",
                    comment: "Warning when a dropped revision cannot be stored in the project"
                ),
                message: String(describing: error),
                source: NSLocalizedString("Project File", comment: "Warning source"),
                timestamp: Date()
            ))
        }
    }

    /// Carries every revision of the takeoff into a package that Save As, Save To or Create
    /// Project has just built (V-017).
    ///
    /// `ProjectPackage.create` starts an empty package and the takeoff archive holds no
    /// revisions, so the copy used to reopen with none: Revision Compare, Overlay, the Set
    /// Compare Report and Carry Forward all lost their revisions and the pairings a person had
    /// confirmed. The open package's stored revisions are copied row for row, with their stored
    /// pairings (confirmed ones included); a revision only this session holds — every revision
    /// of a Quick PDF — is added from its own file, with the pairing the session has for it.
    ///
    /// - Returns: the new package's row for each revision the session shows, which becomes
    ///   ``persistedRevisionIDs`` once the document moves to the new package.
    func carryRevisions(into package: ProjectPackage, from oldPackage: ProjectPackage?) async throws -> [RevisionSummary.ID: String] {
        let firstDocument = "SELECT id FROM document ORDER BY created_at, id LIMIT 1"
        guard let documentId = try await package.read({ db in try String.fetchOne(db, sql: firstDocument) }) else {
            return [:]
        }
        var carried: [RevisionSummary.ID: String] = [:]
        if let oldPackage, oldPackage !== package {
            let stored: [(RevisionEntryRecord, [RevisionSheetRecord])] = try await oldPackage.read { db in
                guard let oldDocument = try String.fetchOne(db, sql: firstDocument) else { return [] }
                return try DocumentSetStore.revisions(document: oldDocument, in: db).map { revision in
                    (revision, try DocumentSetStore.sheets(revision: revision.id, in: db))
                }
            }
            var newRow: [String: String] = [:]
            for (revision, sheets) in stored {
                let file = oldPackage.revisionFileURL(revision)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let row = try await package.addRevision(
                    pdf: file, documentId: documentId, label: revision.label,
                    pageCount: revision.pageCount, sheets: sheets
                )
                newRow[revision.id] = row.id
            }
            for (summaryID, oldRow) in persistedRevisionIDs {
                if let row = newRow[oldRow] { carried[summaryID] = row }
            }
        }
        // The revisions the session holds that no stored row carried.
        let setPages = (drawing?.pages ?? []).map { (id: $0.id.rawValue.uuidString, label: $0.label) }
        for summary in comparePresenter?.revisions ?? [] where !summary.isBaseline && carried[summary.id] == nil {
            guard let file = revisionPages[summary.id]?.fileURL,
                  FileManager.default.fileExists(atPath: file.path) else { continue }
            let labels = revisionPageLabels[summary.id] ?? []
            let row = try await package.addRevision(
                pdf: file, documentId: documentId, label: summary.name,
                pageCount: summary.pageCount,
                sheets: sessionSheetRecords(for: summary.id, revisionLabels: labels, pageCount: summary.pageCount, setPages: setPages)
            )
            carried[summary.id] = row.id
        }
        return carried
    }

    /// One session revision's pairings as `revision_sheet` rows: the pairs the session adopted
    /// (a review's, a person's), else the label pairing a kept revision is first given.
    func sessionSheetRecords(
        for summaryID: RevisionSummary.ID,
        revisionLabels labels: [String],
        pageCount: Int,
        setPages: [(id: String, label: String)]
    ) -> [RevisionSheetRecord] {
        guard let pairs = revisionSheetPairs[summaryID], !pairs.isEmpty else {
            return Self.sheetPairings(revisionLabels: labels, setPages: setPages)
        }
        let evidence = revisionSheetPairEvidence[summaryID] ?? [:]
        var byRevisionPage: [Int: RevisionSheetRecord] = [:]
        for (pageID, index) in pairs.sorted(by: { $0.value < $1.value }) where byRevisionPage[index] == nil {
            byRevisionPage[index] = RevisionSheetRecord(
                revisionId: "", revisionPageIndex: index, pageId: pageID.uuidString,
                evidence: (evidence[pageID] ?? .label).rawValue
            )
        }
        let count = Swift.max(pageCount, labels.count, (byRevisionPage.keys.max() ?? -1) + 1)
        return (0..<count).map { index in
            byRevisionPage[index] ?? RevisionSheetRecord(
                revisionId: "", revisionPageIndex: index, pageId: nil,
                evidence: RevisionSheetRecord.Evidence.added.rawValue
            )
        }
    }

    /// Re-registers the project's stored revisions after an open, oldest first, so Revision
    /// Compare and Overlay have them without dropping the files again.
    func restorePersistedRevisions() {
        guard let package = projectPackage else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let stored: [RevisionEntryRecord] = (try? await package.read { db in
                guard let documentId = try String.fetchOne(
                    db, sql: "SELECT id FROM document ORDER BY created_at, id LIMIT 1"
                ) else { return [] }
                return try DocumentSetStore.revisions(document: documentId, in: db)
            }) ?? []
            guard !stored.isEmpty else { return }
            self.restoringRevisions = true
            defer { self.restoringRevisions = false }
            for revision in stored {
                let url = package.revisionFileURL(revision)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let done: Bool = await withCheckedContinuation { continuation in
                    self.addRevision(fromDroppedFile: url, label: revision.label) { continuation.resume(returning: $0) }
                }
                if done, let id = self.revisionPages.first(where: { $0.value.fileURL == url })?.key {
                    self.persistedRevisionIDs[id] = revision.id
                    // The pairing confirmed when it was kept (NL-DOCS-11).
                    let sheets = (try? await package.read { db in try DocumentSetStore.sheets(revision: revision.id, in: db) }) ?? []
                    self.adoptSheetPairs(sheets, summaryID: id)
                }
            }
        }
    }
}

extension ProjectWindowController {

    /// Every revision's page for the sheet this window shows (T-011). `document.core` answers
    /// for the focused window, so a composition that ran while another window had focus — a
    /// scroll over this inactive window, a change inside the coalescing pause, the arm after the
    /// baseline await — stacked that window's sheet here, and the viewport observation then
    /// followed that window for good.
    func overlayPages(for document: ZenitPDFProjectDocument) -> [RevisionSummary.ID: RevisionPageReference] {
        document.overlayPages(for: windowCore(for: document))
    }
}
