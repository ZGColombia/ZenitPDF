import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation

/// The project's markup layers as the layered export carries them (ADR-0042, L-22).
///
/// File ▸ Export with Markups as a PDF Layer used to put every markup in one optional-content
/// group, "Zenit Markups", so a person who had sorted a review onto its own layer sent a file in
/// which it could not be switched on its own. Now each markup layer that has a markup on an
/// exported sheet is its own group:
///
/// - **named after the layer**, verbatim — except a project that holds only the default layer
///   under its stock name, which keeps ADR-0013's "Zenit Markups" (a recipient's layer panel
///   reading "Default" says nothing);
/// - **in layer order**, top layer first in the reader's layer panel; the ink is painted in draw
///   order (ADR-0036), so an upper layer still draws over a lower one;
/// - **on or off as the layer is shown or hidden**. A hidden layer is exported as a group that is
///   off by default, so the recipient sees what the sender saw and can switch it on. A layer kept
///   off paper ("Don't Print Layer") and a markup hidden on its own are left out, as in every
///   other output.
enum LayeredExportLayers {

    /// The exporter's layers for `records` — the markups the job was built from, in any order.
    static func layers(
        for records: [MarkupRecord],
        in list: MarkupLayerSet
    ) -> [LayeredMarkupExporter.Layer] {
        var members: [LayerID: Set<MarkupID>] = [:]
        for record in records {
            members[list.resolvedLayerID(of: record), default: []].insert(record.id)
        }
        let onlyStockDefault = list.layers.count == 1
            && list.layers[0].isDefault
            && list.layers[0].name == MarkupLayer.defaultName
        return list.layers.compactMap { layer in
            guard layer.printable, let ids = members[layer.id], !ids.isEmpty else { return nil }
            return LayeredMarkupExporter.Layer(
                name: onlyStockDefault ? defaultGroupName : layer.name,
                visibleByDefault: layer.visible,
                markupIDs: ids
            )
        }
    }

    /// The single group's name, localised at export time and stored verbatim (ADR-0013 §2).
    static var defaultGroupName: String {
        NSLocalizedString("Zenit Markups", comment: "Name of the PDF layer that holds the markups when the project has no markup layers of its own")
    }

    /// The layered export's job and exporter options, gathered off the document: hidden layers'
    /// markups included, each markup layer its own group.
    @MainActor
    static func prepare(
        for document: ZenitPDFProjectDocument,
        artwork resolve: ((String) async -> ArtworkGeometry?)?,
        set: DrawingSetOutput?
    ) async throws -> (job: FlattenedDrawingExport.Job, options: LayeredMarkupExporter.Options) {
        let job = try await FlattenedDrawingExport.job(for: document, artwork: resolve, set: set, keepingHiddenLayers: true)
        var options = LayeredMarkupExporter.Options(layerName: defaultGroupName)
        if let session = document.core?.session {
            options.layers = layers(for: await session.drawOrderedMarkups, in: await session.markupLayerList)
        }
        // Zenit's earlier annotations for this project's markups only, never a colleague's (L-23).
        options.supersededAnnotationNames = await ZenitAnnotationSupersession.names(for: document)
        return (job, options)
    }

    /// The status note after the export, for every count (L-26: "1 markups on layer …").
    static func statusNote(for outcome: LayeredExportOutcome) -> String {
        let groups = outcome.groups
        guard groups.count > 1 else {
            let count = groups.first?.markupCount ?? outcome.paintedMarkupCount
            return LocalizedPlural.string(
                "Layered PDF written: %1$lld markups on layer “%2$@”",
                count: count,
                one: NSLocalizedString(
                    "Layered PDF written: %1$lld markup on layer “%2$@”",
                    comment: "Status note after the layered export, one markup; count and layer name"
                ),
                other: NSLocalizedString(
                    "Layered PDF written: %1$lld markups on layer “%2$@”",
                    comment: "Status note after the layered export, several markups; count and layer name"
                ),
                arguments: [outcome.layerName]
            )
        }
        // Two layers or more each hold a markup, so both counts are plural.
        return String(
            format: NSLocalizedString(
                "Layered PDF written: %1$lld markups on %2$lld layers",
                comment: "Status note after the layered export with one PDF layer per markup layer; markup count and layer count"
            ),
            Int64(outcome.layeredMarkupCount),
            Int64(groups.count)
        )
    }
}
