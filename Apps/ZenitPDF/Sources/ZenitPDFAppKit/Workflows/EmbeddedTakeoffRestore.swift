import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// The takeoff a PDF carries back into Zenit (NL-PDF-03 restore, ADR-0023 §5).
///
/// File ▸ Save Markups into PDF… embeds two Zenit files beside the standard annotations: the
/// measurement overlay (for any Zenit, and for people reading the ledger rows) and this session
/// archive — every markup, scale, page-scale assignment, calibration evidence, Scale Region and
/// Project Zone exactly as the session held them. Opening the PDF again offers, in the warning
/// tray, to restore it. Restoring hydrates the session the way a project reopen does: every
/// measurement is recomputed from its stored geometry, scale and parameters by the one engine,
/// so values, scale identity and version, and provenance come back digit for digit.
///
/// Two refusals keep it honest:
/// - the drawing under the takeoff must be the file's own untouched prefix (the embedded digest
///   is checked before anything is believed), and
/// - a session that already holds markups or scales is never overwritten — the offer is made
///   only on an empty takeoff and re-checked at the press.
///
/// Zenit's own annotations in the file are then hidden on the canvas (view state, never written),
/// so a restored markup is not drawn twice: once live, once as the PDF's appearance.
struct EmbeddedSessionArchive: Codable, Sendable {

    static let fileName = "zenit-session.json"
    static let currentVersion = 1

    var version: Int
    var documentID: UUID
    /// The session's page identifiers, by page index in the file — never by set position
    /// (W-017). Page identities are minted per session, so a restore maps each onto the page at
    /// the same index of the drawing opened.
    var pageIDs: [UUID]
    /// Visible-box width and height by page index: a different drawing is refused, not guessed.
    var pageSizes: [[Double]]
    var markups: [MarkupRecord]
    var scales: [ScaleTransform]
    var pageScaleIDs: [PageID: ScaleID]
    var calibrationEvidence: [ScaleID: CalibrationEvidence]
    var scaleRegions: [Region]
    var projectZones: [Zone]
    var customColumns: [LedgerColumnDefinition]

    struct Region: Codable, Sendable {
        var id: ScaleRegionID
        var pageID: PageID
        var name: String
        var boundary: [PDFPoint]
        var scaleID: ScaleID
        var priority: Int
        var locked: Bool
        var isVisible: Bool
        var colorRGBA: ColorRGBA
    }

    struct Zone: Codable, Sendable {
        var id: ZoneID
        var name: String
        var kind: ProjectZoneKind
        var parentID: ZoneID?
        var pageID: PageID?
        var boundary: [PDFPoint]
        var sortOrder: Int
        var isVisible: Bool
        var colorRGBA: ColorRGBA
    }

    /// What a restore installs, already mapped onto the session's own page identities.
    struct Restored: Sendable {
        var markups: [MarkupRecord]
        var scales: [ScaleTransform]
        var pageScaleIDs: [PageID: ScaleID]
        var calibrationEvidence: [ScaleID: CalibrationEvidence]
        var scaleRegions: [ScaleRegionDefinition]
        var projectZones: [ProjectZoneDefinition]
        var customColumns: [LedgerColumnDefinition]
        var sheetCount: Int
    }

    enum Refusal: Error, Equatable {
        case unreadable
        case newerVersion(Int)
        case differentDrawing
    }

    // MARK: - Writing

    /// Encodes the takeoff on one drawing's own pages, in its file order (W-017).
    ///
    /// The file the archive rides in is that drawing's bytes, in file order, and a restore pairs
    /// the archive's pages with the reopened file's by position. The session's own page list is
    /// the set order — rearranged, with removed sheets left out and other drawings' sheets in
    /// it — so writing that list moved every markup to the file page at its set position after
    /// a reorder, and refused the restore outright after a removal or in a project of several
    /// drawings. Only what lies on `pages` is written: its markups, their pages' scales and
    /// evidence, its Scale Regions, and the Project Zones on its sheets or on none (a parent
    /// left out is dropped from the child, never left dangling). The markups of a sheet removed
    /// from the set are set aside, outside the takeoff, and stay out here as they stay out of
    /// the annotations written.
    static func encode(
        _ state: TakeoffSession.TakeoffState,
        pages: [ZPDFContracts.PageDescriptor],
        documentID: DocumentID
    ) throws -> Data {
        let onFile = Set(pages.map(\.id))
        let scales = state.scales.filter { $0.pageID.map(onFile.contains) ?? true }
        let scaleIDs = Set(scales.map(\.id))
        let zones = state.projectZones.filter { $0.pageID.map(onFile.contains) ?? true }
        let zoneIDs = Set(zones.map(\.id))
        let archive = EmbeddedSessionArchive(
            version: currentVersion,
            documentID: documentID.rawValue,
            pageIDs: pages.map(\.id.rawValue),
            pageSizes: pages.map { [Double($0.visibleBox.size.width), Double($0.visibleBox.size.height)] },
            markups: state.markups.filter { onFile.contains($0.pageID) },
            scales: scales,
            pageScaleIDs: state.pageScaleIDs.filter { onFile.contains($0.key) && scaleIDs.contains($0.value) },
            calibrationEvidence: state.calibrationEvidence.filter { scaleIDs.contains($0.key) },
            scaleRegions: state.scaleRegions.filter { onFile.contains($0.pageID) }.map {
                Region(id: $0.id, pageID: $0.pageID, name: $0.name, boundary: $0.boundary, scaleID: $0.scaleID,
                       priority: $0.priority, locked: $0.locked, isVisible: $0.isVisible, colorRGBA: $0.colorRGBA)
            },
            projectZones: zones.map {
                Zone(id: $0.id, name: $0.name, kind: $0.kind, parentID: $0.parentID.flatMap { zoneIDs.contains($0) ? $0 : nil },
                     pageID: $0.pageID, boundary: $0.boundary, sortOrder: $0.sortOrder, isVisible: $0.isVisible,
                     colorRGBA: $0.colorRGBA)
            },
            customColumns: state.customColumns
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    // MARK: - Reading

    /// Decodes `data` and maps it onto `pages` of `documentID`. Pure.
    ///
    /// The archive's page and document identities are replaced textually in the JSON before the
    /// typed decode — they are UUIDs, unique by construction — so every nested reference (a
    /// markup's page, its geometry's page, a scale's page, a region's, a zone's, a page-scale
    /// key) follows without a hand-written walk that a new field could escape.
    static func restore(_ data: Data, onto pages: [ZPDFContracts.PageDescriptor], documentID: DocumentID) throws -> Restored {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(EmbeddedSessionArchive.self, from: data) else { throw Refusal.unreadable }
        guard header.version <= currentVersion else { throw Refusal.newerVersion(header.version) }
        guard header.pageIDs.count == pages.count, header.pageSizes.count == pages.count else { throw Refusal.differentDrawing }
        for (size, page) in zip(header.pageSizes, pages) {
            guard size.count == 2,
                  abs(size[0] - Double(page.visibleBox.size.width)) <= 0.5,
                  abs(size[1] - Double(page.visibleBox.size.height)) <= 0.5
            else { throw Refusal.differentDrawing }
        }
        var text = String(decoding: data, as: UTF8.self)
        for (old, page) in zip(header.pageIDs, pages) where old != page.id.rawValue {
            text = text.replacingOccurrences(of: old.uuidString, with: page.id.rawValue.uuidString)
        }
        if header.documentID != documentID.rawValue {
            text = text.replacingOccurrences(of: header.documentID.uuidString, with: documentID.rawValue.uuidString)
        }
        guard let mapped = try? decoder.decode(EmbeddedSessionArchive.self, from: Data(text.utf8)) else { throw Refusal.unreadable }
        return Restored(
            markups: mapped.markups,
            scales: mapped.scales,
            pageScaleIDs: mapped.pageScaleIDs,
            calibrationEvidence: mapped.calibrationEvidence,
            scaleRegions: mapped.scaleRegions.map {
                ScaleRegionDefinition(id: $0.id, pageID: $0.pageID, name: $0.name, boundary: $0.boundary, scaleID: $0.scaleID,
                                      priority: $0.priority, locked: $0.locked, isVisible: $0.isVisible, colorRGBA: $0.colorRGBA)
            },
            projectZones: mapped.projectZones.map {
                ProjectZoneDefinition(id: $0.id, name: $0.name, kind: $0.kind, parentID: $0.parentID, pageID: $0.pageID,
                                      boundary: $0.boundary, sortOrder: $0.sortOrder, isVisible: $0.isVisible, colorRGBA: $0.colorRGBA)
            },
            customColumns: mapped.customColumns,
            sheetCount: Set(mapped.markups.map(\.pageID)).count
        )
    }
}

/// The offer in the warning tray and the press that restores.
@MainActor
enum EmbeddedTakeoffRestore {

    /// The pseudo-layer Zenit's own annotations are bound to once their markups are live again.
    nonisolated static let restoredLayer = PDFLayerID(rawValue: "zenit:restored-takeoff")

    struct Offer {
        weak var document: ZenitPDFProjectDocument?
        var archive: Data
    }

    static var pending: [UUID: Offer] = [:]

    /// What reading the file found.
    enum Finding: Equatable {
        case none
        /// A takeoff is carried, but the drawing under it is not the one it was measured on.
        case tampered
        case restorable(markups: Int, sheets: Int)
    }

    /// Reads the file off the main actor and decides. Pure apart from reading `url`.
    nonisolated static func inspect(
        fileAt url: URL,
        pages: [ZPDFContracts.PageDescriptor],
        documentID: DocumentID
    ) -> (finding: Finding, archive: Data?) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return (.none, nil) }
        // Only the session archive is decoded and its prefix hashed: the reader tells entries
        // apart by name first (W-055: every carried file used to be decoded to find this one).
        // No archive — nothing carried, or only the overlay of a save from before the session
        // archive — leaves nothing to restore from.
        guard let archive = EmbeddedTakeoffReader.read(data, named: EmbeddedSessionArchive.fileName) else {
            return (.none, nil)
        }
        guard archive.prefixVerified else { return (.tampered, nil) }
        guard let restored = try? EmbeddedSessionArchive.restore(archive.takeoff.payload, onto: pages, documentID: documentID),
              !restored.markups.isEmpty || !restored.scales.isEmpty
        else { return (.none, nil) }
        return (.restorable(markups: restored.markups.count, sheets: max(restored.sheetCount, 1)), archive.takeoff.payload)
    }

    static func offerTitle(markups: Int, sheets: Int) -> String {
        sheets == 1
            ? String(format: NSLocalizedString("This PDF carries its Zenit takeoff: %lld markups.", comment: "Embedded takeoff offer title; markup count"), Int64(markups))
            : String(format: NSLocalizedString("This PDF carries its Zenit takeoff: %1$lld markups on %2$lld sheets.", comment: "Embedded takeoff offer title; markup count, sheet count"), Int64(markups), Int64(sheets))
    }

    /// Offers the restore once per open, only on an empty takeoff.
    static func offer(for document: ZenitPDFProjectDocument) {
        guard let drawing = document.drawing, let core = document.core else { return }
        let url = drawing.url
        let pages = drawing.pages
        let documentID = drawing.documentID
        Task { @MainActor [weak document] in
            let result = await Task.detached(priority: .utility) {
                inspect(fileAt: url, pages: pages, documentID: documentID)
            }.value
            guard let document, document.core === core else { return }
            switch result.finding {
            case .none:
                return
            case .tampered:
                core.document.post(AppWarning(
                    id: UUID(),
                    severity: .warning,
                    title: NSLocalizedString("The Zenit takeoff in this PDF was not restored.", comment: "Embedded takeoff refused title"),
                    message: NSLocalizedString(
                        "The drawing under it was changed after the takeoff was saved into it, so its measurements may no longer fit the drawing. The annotations are still shown as part of the PDF.",
                        comment: "Embedded takeoff refused detail"
                    ),
                    source: NSLocalizedString("Export", comment: "Warning source for print and export"),
                    isDismissible: true,
                    timestamp: Date()
                ))
            case let .restorable(markups, sheets):
                guard let archive = result.archive, await isEmpty(core) else { return }
                let id = UUID()
                pending[id] = Offer(document: document, archive: archive)
                core.document.post(AppWarning(
                    id: id,
                    severity: .info,
                    title: offerTitle(markups: markups, sheets: sheets),
                    message: NSLocalizedString(
                        "It was saved into the file with Save Markups into PDF. Restore brings back every measurement, scale and region exactly as saved; the drawing itself is not changed.",
                        comment: "Embedded takeoff offer detail"
                    ),
                    source: NSLocalizedString("Export", comment: "Warning source for print and export"),
                    actionTitle: NSLocalizedString("Restore Takeoff", comment: "Embedded takeoff offer action"),
                    isDismissible: true,
                    timestamp: Date()
                ))
            }
        }
    }

    static func isEmpty(_ core: AppCoreEnvironment) async -> Bool {
        let state = await core.session.takeoffState()
        return state.markups.isEmpty && state.scales.isEmpty && state.scaleRegions.isEmpty
    }

    /// The tray's action. Returns whether the warning was a restore offer.
    static func handleAction(_ warningID: UUID, document: ZenitPDFProjectDocument) -> Bool {
        guard let offer = pending[warningID], offer.document === document else { return false }
        pending.removeValue(forKey: warningID)
        Task { @MainActor in _ = await restore(offer.archive, into: document, warningID: warningID) }
        return true
    }

    /// Restores `archive` into the document's session. Returns the restored markup identifiers,
    /// or `nil` when it refused (a takeoff appeared meanwhile, or the archive does not fit).
    @discardableResult
    static func restore(_ archive: Data, into document: ZenitPDFProjectDocument, warningID: UUID? = nil) async -> Set<UUID>? {
        guard let core = document.core, let drawing = document.drawing else { return nil }
        if let warningID { core.document.dismissWarning(id: warningID) }
        // Re-checked at the press: a takeoff started meanwhile is never overwritten.
        guard await isEmpty(core) else {
            core.document.post(AppWarning(
                id: UUID(),
                severity: .warning,
                title: NSLocalizedString("The Zenit takeoff in this PDF was not restored.", comment: "Embedded takeoff refused title"),
                message: NSLocalizedString(
                    "Markups or scales were added since the drawing opened, and a restore never replaces work. Open the PDF again in a new window to restore it.",
                    comment: "Embedded takeoff refused because the session is no longer empty"
                ),
                source: NSLocalizedString("Export", comment: "Warning source for print and export"),
                isDismissible: true,
                timestamp: Date()
            ))
            return nil
        }
        do {
            let restored = try EmbeddedSessionArchive.restore(archive, onto: drawing.pages, documentID: drawing.documentID)
            _ = await core.session.restoreCustomColumns(restored.customColumns)
            try await core.session.hydrate(
                markups: restored.markups,
                scales: restored.scales,
                pageScaleIDs: restored.pageScaleIDs,
                calibrationEvidence: restored.calibrationEvidence,
                scaleRegions: restored.scaleRegions,
                projectZones: restored.projectZones
            )
            await core.refresh()
            let ids = Set(restored.markups.map(\.id.rawValue))
            await hideOwnAnnotations(of: document, restoredIDs: ids)
            return ids
        } catch {
            ZenitErrorPresenter.present(error)
            return nil
        }
    }

    /// Binds every annotation Zenit wrote for a restored markup (its `/NM` is the markup's id)
    /// to a hidden pseudo-layer, so the canvas draws the live markup and not its picture too.
    static func hideOwnAnnotations(of document: ZenitPDFProjectDocument, restoredIDs: Set<UUID>) async {
        guard let drawing = document.drawing, !restoredIDs.isEmpty else { return }
        let url = drawing.url
        let reading = await Task.detached(priority: .utility) { try? ReviewAnnotationReader.read(url: url) }.value
        guard let reading else { return }
        let bindings = ownAnnotationBindings(reading, restoredIDs: restoredIDs)
        guard !bindings.isEmpty else { return }
        // Outputs leave these out too, even once their markup is deleted (L-23).
        ZenitAnnotationSupersession.record(bindings.compactMap(\.annotationName), for: document)
        let changed = (try? await drawing.rasterSource.applyAnnotationLayerVisibility(
            bindings: bindings,
            hiddenLayerIDs: [restoredLayer]
        )) ?? 0
        guard changed > 0 else { return }
        document.invalidateThumbnailsAfterLayerChange()
        document.rerenderAfterAnnotationDisplayChange()
    }

    /// The bindings for Zenit-owned top-level annotations named by a restored markup. Pure.
    nonisolated static func ownAnnotationBindings(
        _ reading: ReviewAnnotationReader.Reading,
        restoredIDs: Set<UUID>
    ) -> [AnnotationLayerBindingReader.Binding] {
        var positionOnPage: [Int: Int] = [:]
        var bindings: [AnnotationLayerBindingReader.Binding] = []
        for annotation in reading.annotations {
            let position = positionOnPage[annotation.pageIndex, default: 0]
            positionOnPage[annotation.pageIndex] = position + 1
            guard annotation.zenitOwned, annotation.inReplyToIndex == nil,
                  let name = annotation.name, let id = UUID(uuidString: name), restoredIDs.contains(id)
            else { continue }
            bindings.append(AnnotationLayerBindingReader.Binding(
                pageIndex: annotation.pageIndex,
                annotationIndex: position,
                layerID: restoredLayer,
                annotationName: annotation.name,
                subtype: annotation.subtype,
                rect: CGRect(
                    x: annotation.rect.minX, y: annotation.rect.minY,
                    width: annotation.rect.width, height: annotation.rect.height
                ).standardized
            ))
        }
        return bindings
    }
}

extension ZenitPDFProjectDocument {
    /// What the drawing file itself carries, said once after the document has loaded: the takeoff
    /// saved into it (NL-PDF-03) and its digital signatures (NL-PDF-15).
    func offerDrawingFileContents() {
        EmbeddedTakeoffRestore.offer(for: self)
        DrawingSignatureStatus.post(for: self)
    }
}
