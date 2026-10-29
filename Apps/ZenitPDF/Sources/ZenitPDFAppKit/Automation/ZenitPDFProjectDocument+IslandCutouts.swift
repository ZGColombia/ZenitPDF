import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation

/// NL-AUTO-10: closed outlines standing free inside a traced room — columns, shafts — are offered
/// as cutouts through the warning tray. Never deducted by themselves: a closed outline inside a
/// room is only a hole in its floor when a person says so. Accepting runs the ordinary cutout
/// command, once per island, each its own undo step like a cutout drawn by hand.
extension ZenitPDFProjectDocument {

    /// A traced area was committed: find the committed record, offer its islands as cutouts
    /// (NL-AUTO-10), and offer the room name printed inside it as its subject (NL-AUTO-21). Both
    /// are offers in the warning tray; neither changes anything by itself.
    func offerIslandCutouts(pageID: PageID, ring: [PDFPoint], islands: [[PDFPoint]], metresPerPoint: Double?) {
        guard let core else { return }
        Task { @MainActor [weak self] in
            // The committed area is the one whose outline is the traced ring, whatever vertex the
            // presenter starts it at. The commit reaches the session through the command bus a
            // moment after the trace, so it is waited for — briefly, and never forever.
            let traced = Set(ring)
            var parent: MarkupRecord?
            for _ in 0..<150 {
                await core.commands.settle()
                parent = await core.session.orderedMarkups.last(where: {
                    $0.pageID == pageID && Set($0.geometry?.polygons.first?.outer.uniquePoints ?? []) == traced
                })
                if parent != nil { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let self, let parent else { return }
            await self.offerSubjectFromLabel(parent: parent, ring: ring, core: core)
            // r2-platform (NL-AUTO-21): the drawing layer the room was traced on suggests a
            // subject from the Tool Library and a Project Zone — offers only.
            await self.offerContextFromLayer(parent: parent, ring: ring, core: core)
            guard !islands.isEmpty else { return }
            let warningID = UUID()
            self.automation.pendingIslandOffers[warningID] = DocumentAutomationState.IslandOffer(
                parent: parent.id, pageID: pageID, islands: islands
            )
            let area = islands.reduce(0.0) { $0 + Self.ringArea($1) }
            let areaText: String
            if let metresPerPoint {
                areaText = String(
                    format: NSLocalizedString("%.2f m²", comment: "An area in square metres"),
                    area * metresPerPoint * metresPerPoint
                )
            } else {
                areaText = String(format: NSLocalizedString("%.0f pt²", comment: "Difference area in square PDF points"), area)
            }
            core.document.post(AppWarning(
                id: warningID,
                severity: .info,
                title: String(
                    format: NSLocalizedString(
                        "%1$d closed outline(s) stand inside the traced area (%2$@).",
                        comment: "Island offer title: how many islands, their total area"
                    ),
                    islands.count, areaText
                ),
                message: NSLocalizedString(
                    "Columns and shafts are usually deducted. The traced area includes them until you choose.",
                    comment: "Island offer detail"
                ),
                source: NSLocalizedString("Auto-trace", comment: "Warning source: auto-trace"),
                actionTitle: NSLocalizedString("Deduct as Cutouts", comment: "Island offer action"),
                isDismissible: true,
                timestamp: Date()
            ))
        }
    }

    /// Suggests the room name printed inside a traced area as its subject — never set unasked.
    func offerSubjectFromLabel(parent: MarkupRecord, ring: [PDFPoint], core: AppCoreEnvironment) async {
        guard let drawing = loadedDrawing(forPage: parent.pageID.rawValue),
              let page = drawing.pages.first(where: { $0.id == parent.pageID }) else { return }
        let lines = await PageTextLoader.embeddedLines(source: drawing.rasterSource, pageIndex: page.index)
        guard let name = RoomLabelPairing.label(for: ring, lines: lines).name,
              name.caseInsensitiveCompare(parent.subject) != .orderedSame else { return }
        let warningID = UUID()
        automation.pendingSubjectOffers[warningID] = (parent.id, name)
        core.document.post(AppWarning(
            id: warningID,
            severity: .info,
            title: String(
                format: NSLocalizedString(
                    "Name this area “%@”?",
                    comment: "Subject suggestion offer after auto-trace; the room name read inside the area"
                ),
                name
            ),
            message: NSLocalizedString(
                "The name is printed inside the traced room. Nothing changes unless you use it.",
                comment: "Subject suggestion detail"
            ),
            source: NSLocalizedString("Auto-trace", comment: "Warning source: auto-trace"),
            actionTitle: NSLocalizedString("Use as Subject", comment: "Subject suggestion action"),
            isDismissible: true,
            timestamp: Date()
        ))
    }

    /// Handles the tray action when it belongs to automation. `false` when it does not.
    func handleAutomationWarningAction(_ warningID: UUID) -> Bool {
        if let offer = automation.pendingZoneOffers.removeValue(forKey: warningID) {
            guard let core else { return true }
            Task { @MainActor in
                _ = try? await core.commands.perform(.setMarkupZone(ids: [offer.markup], zoneID: offer.zone))
                core.document.dismissWarning(id: warningID)
                await core.refresh()
            }
            return true
        }
        if let offer = automation.pendingSubjectOffers.removeValue(forKey: warningID) {
            guard let core else { return true }
            Task { @MainActor in
                _ = try? await core.commands.perform(.editSubject(id: offer.markup, subject: offer.subject))
                core.document.dismissWarning(id: warningID)
                await core.refresh()
            }
            return true
        }
        guard let offer = automation.pendingIslandOffers.removeValue(forKey: warningID) else { return false }
        guard let core else { return true }
        Task { @MainActor in
            let documentID = await core.session.documentID
            let now = Date()
            for island in offer.islands {
                let cutout = MarkupRecord(
                    id: MarkupID(UUID()),
                    documentID: documentID,
                    pageID: offer.pageID,
                    kind: .polygon,
                    tool: .polygonCutout,
                    subject: NSLocalizedString("Cutout", comment: "Subject of a cutout deducted from a traced area"),
                    geometry: MeasurementGeometry(
                        pageID: offer.pageID,
                        polygons: [PolygonGeometry(outer: PolygonRing(points: island, isClosed: true))]
                    ),
                    createdAt: now,
                    modifiedAt: now
                )
                _ = try? await core.commands.perform(.addCutout(parent: offer.parent, cutout: cutout))
            }
            core.document.dismissWarning(id: warningID)
            await core.refresh()
        }
        return true
    }

    static func ringArea(_ ring: [PDFPoint]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var total = 0.0
        var previous = ring[ring.count - 1]
        for point in ring {
            total += previous.x * point.y - point.x * previous.y
            previous = point
        }
        return abs(total) / 2
    }
}
