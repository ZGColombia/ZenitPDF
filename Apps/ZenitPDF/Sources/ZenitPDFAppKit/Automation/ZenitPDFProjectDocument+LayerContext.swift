import CoreGraphics
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// NL-AUTO-21 (r2-platform): a traced area's drawing layer as context. The layer most of the
/// area's outline was traced on is matched against the Tool Library and the Project Zones; a
/// match is offered in the warning tray — "Subject: Floor finish (layer A-FLOOR-FINI)?",
/// "Put it in zone Level 2?" — and applied only on the person's click.
extension ZenitPDFProjectDocument {

    /// The layer most of `ring`'s edges lie on, among the extraction's straight segments: each
    /// edge votes for the layer of every segment that runs along it within `tolerance` points.
    nonisolated static func dominantLayer(of ring: [PDFPoint], in primitives: [VectorPrimitive], tolerance: Double = 1.5) -> String? {
        guard ring.count >= 3 else { return nil }
        var votes: [String: Double] = [:]
        let edges = zip(ring, ring.dropFirst() + [ring[0]]).map { ($0, $1) }
        for primitive in primitives {
            guard let layer = primitive.layerID, let segment = GeometryQuerySegment(primitive: primitive) else { continue }
            for (a, b) in edges {
                let length = a.distance(to: b)
                guard length > 0 else { continue }
                func offset(_ p: CGPoint) -> Double {
                    abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / length
                }
                guard offset(segment.start) <= tolerance, offset(segment.end) <= tolerance else { continue }
                votes[layer, default: 0] += hypot(segment.end.x - segment.start.x, segment.end.y - segment.start.y)
            }
        }
        return votes.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    func offerContextFromLayer(parent: MarkupRecord, ring: [PDFPoint], core: AppCoreEnvironment) async {
        // The traced sheet's own drawing and extraction (U-007): the page-index form read the
        // primary drawing's same-index sheet.
        guard let page = pageDescriptor(forPage: parent.pageID.rawValue),
              let extraction = await automationExtraction(forPage: page),
              let layer = Self.dominantLayer(of: ring, in: extraction.primitives) else { return }
        let suggestion = LayerContextSuggester.suggest(
            layerName: layer, presets: core.toolLibrary.presets, zones: core.snapshot.zones, currentSubject: parent.subject)
        if let subject = suggestion.subject {
            let warningID = UUID()
            automation.pendingSubjectOffers[warningID] = (parent.id, subject)
            core.document.post(AppWarning(
                id: warningID, severity: .info,
                title: String(format: NSLocalizedString("Subject “%1$@”? The area was traced on layer %2$@.", comment: "Layer subject suggestion; subject, layer name"), subject, layer),
                message: String(format: NSLocalizedString("The layer's name matches the tool “%@”. Nothing changes unless you use it.", comment: "Layer subject suggestion detail; preset name"), suggestion.presetName ?? subject),
                source: NSLocalizedString("Auto-trace", comment: "Warning source: auto-trace"),
                actionTitle: NSLocalizedString("Use as Subject", comment: "Subject suggestion action"),
                isDismissible: true, timestamp: Date()))
        }
        if let zoneID = suggestion.zoneID, let zoneName = suggestion.zoneName, parent.zoneID?.rawValue != zoneID {
            let warningID = UUID()
            automation.pendingZoneOffers[warningID] = (parent.id, ZoneID(zoneID))
            core.document.post(AppWarning(
                id: warningID, severity: .info,
                title: String(format: NSLocalizedString("Put this area in zone “%1$@”? It was traced on layer %2$@.", comment: "Layer zone suggestion; zone, layer name"), zoneName, layer),
                message: NSLocalizedString("The layer's name matches the Project Zone. Nothing changes unless you use it.", comment: "Layer zone suggestion detail"),
                source: NSLocalizedString("Auto-trace", comment: "Warning source: auto-trace"),
                actionTitle: NSLocalizedString("Put in Zone", comment: "Layer zone suggestion action"),
                isDismissible: true, timestamp: Date()))
        }
    }
}
