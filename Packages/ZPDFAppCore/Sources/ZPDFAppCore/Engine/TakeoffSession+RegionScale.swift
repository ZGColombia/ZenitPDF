import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// A drawing ratio for one part of a sheet (NL-AUTO-19, NL-MEASURE-16).
///
/// A sheet that holds a 1:100 plan and a 1:20 detail has one page scale and needs a second scale
/// inside the detail's outline. ``TakeoffSession/addRegionPresetScale(page:ratioNumerator:ratioDenominator:label:boundary:name:colorRGBA:)``
/// installs that second scale and the Scale Region that uses it as **one** undoable step, and it
/// never touches the page's own scale: the new scale has a fresh identifier, and the session only
/// promotes a scale to the page scale when the page has none (which this entry point refuses).
extension TakeoffSession {

    /// Installs a preset scale (`source == .preset`, no evidence) under a fresh identifier and
    /// adds a Scale Region over `boundary` that measures with it, as one step.
    ///
    /// - Parameters:
    ///   - boundary: the region's closed outline in page space, first point not repeated; at
    ///     least three distinct points.
    ///   - name: what the region is called ("Detail 3"); the ratio text when empty.
    /// - Returns: the batch outcome (one ⌘Z removes the region and the scale together) and the
    ///   new scale's identifier.
    /// - Throws: ``DocumentCommandError/noScale(_:)`` when the page has no scale of its own yet
    ///   — a region scale installed first would become the whole sheet's scale (BH-432), so the
    ///   sheet's scale is set first; ``DocumentCommandError/unknownPage(_:)`` for a page this
    ///   document does not hold; ``DocumentCommandError/measurementFailed(_:)`` for a boundary
    ///   with fewer than three distinct points. Any refusal leaves the document as it was.
    public func addRegionPresetScale(
        page: PageID,
        ratioNumerator: Decimal = 1,
        ratioDenominator: Decimal,
        label: String? = nil,
        boundary: [PDFPoint],
        name: String,
        colorRGBA: ColorRGBA = ColorRGBA.Zenit.Dark.cyan
    ) throws -> (outcome: DocumentBatchOutcome, scaleID: ScaleID, regionID: ScaleRegionID) {
        guard let descriptor = pageDescriptors.first(where: { $0.id == page }) else {
            throw DocumentCommandError.unknownPage(page)
        }
        guard pageScale(page) != nil else { throw DocumentCommandError.noScale(page) }
        let distinct = PolygonRing(points: boundary, isClosed: true).uniquePoints
        guard distinct.count >= 3, distinct.allSatisfy(\.isFinite) else {
            throw DocumentCommandError.measurementFailed("a Scale Region needs at least three distinct corners")
        }
        let scaleID = ScaleID(UUID())
        let scale = try ScaleTransform.preset(
            id: scaleID,
            page: descriptor,
            version: 1,
            ratioNumerator: ratioNumerator,
            ratioDenominator: ratioDenominator,
            units: scaleUnitPolicy,
            label: label,
            allowExtreme: false
        )
        var regions = scaleRegionDefinitions
        let priority = (regions.filter { $0.pageID == page }.map(\.priority).max() ?? 0) + 1
        let regionID = ScaleRegionID(UUID())
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        regions.append(ScaleRegionDefinition(
            id: regionID,
            pageID: page,
            name: trimmed.isEmpty
                ? (label ?? ScaleBridge.ratioText(for: scale, userUnit: descriptor.userUnit, localeIdentifier: localeIdentifier))
                : trimmed,
            boundary: distinct,
            scaleID: scaleID,
            priority: priority,
            colorRGBA: colorRGBA
        ))
        let outcome = try applyBatch([.changeScale(scale), .setScaleRegions(regions)])
        return (outcome, scaleID, regionID)
    }
}
