import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// What a measurement's pill says (NL-MEASURE-09, ADR-0030 §3): the label, the chosen fields in
/// the one ledger formatter's words, and per-segment lengths derived from the stored geometry.
/// Display only — no value here is stored.
public enum MeasurementCaptionText {

    /// The short prefix a secondary field carries in a pill ("P" for Perimeter). The headline
    /// field carries none, as it always has.
    public static func abbreviation(_ field: Shown.Field) -> String {
        switch field {
        case .perimeter: return NSLocalizedString("P", comment: "Caption prefix: perimeter")
        case .planLength: return NSLocalizedString("L", comment: "Caption prefix: plan length")
        case .trueLength: return NSLocalizedString("TL", comment: "Caption prefix: true length")
        case .planArea: return NSLocalizedString("GA", comment: "Caption prefix: gross area")
        case .netArea: return NSLocalizedString("A", comment: "Caption prefix: plan (net) area")
        case .trueArea: return NSLocalizedString("TA", comment: "Caption prefix: true area")
        case .volume: return NSLocalizedString("V", comment: "Caption prefix: volume")
        default: return field.displayName
        }
    }

    /// The pill text: "Area C: 21.34 m² · P 18.60 m". `nil` when there is nothing to show.
    ///
    /// - Parameters:
    ///   - fields: the markup's formatted fields (``MarkupSummary/measurementFields``).
    ///   - primary: the tool's headline field.
    ///   - chosen: the caption's fields; empty for the headline alone.
    ///   - repetition: the ×N badge, when the markup repeats.
    public static func text(
        label: String,
        fields: [MeasurementFieldSummary],
        primary: Shown.Field?,
        chosen: [Shown.Field],
        repetition: String?
    ) -> String? {
        let order = chosen.isEmpty ? primary.map { [$0] } ?? [] : chosen
        var parts: [String] = []
        for field in order {
            guard let summary = fields.first(where: { $0.field == field }), !summary.displayTextWithUnit.isEmpty else { continue }
            parts.append(field == primary || parts.isEmpty && chosen.isEmpty
                ? summary.displayTextWithUnit
                : "\(abbreviation(field)) \(summary.displayTextWithUnit)")
        }
        guard !parts.isEmpty else { return nil }
        let values = parts.joined(separator: " · ")
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let text = trimmed.isEmpty ? values : "\(trimmed): \(values)"
        guard let repetition else { return text }
        return "\(text) \(repetition)"
    }

    /// One labelled segment: its ends in page space and its real length in metres.
    public struct Segment: Hashable, Sendable {
        public let start: PDFPoint
        public let end: PDFPoint
        public let metres: Decimal
    }

    /// The segments a linear or areal markup is labelled along, with their real lengths.
    ///
    /// On a uniform scale each length is the stored total (Plan Length, or Perimeter for an area)
    /// split in proportion to the segment's page length — so the labels add up to the stored
    /// total exactly as it is shown, whatever scale (page or Scale Region) the markup was measured
    /// under. On a separate X/Y scale each segment is `√((dx·sx)² + (dy·sy)²)` through the page's
    /// factors. An empty list for a markup that has no segments.
    public static func segments(of record: MarkupRecord, metresPerPoint: (x: Double, y: Double)?) -> [Segment] {
        guard let geometry = record.geometry else { return [] }
        let chain: [(PDFPoint, PDFPoint)]
        let totalField: ZPDFContracts.MeasurementField
        if let ring = geometry.polygons.first?.outer.segments, !ring.isEmpty {
            chain = ring.map { ($0.start, $0.end) }
            totalField = .perimeter
        } else if geometry.points.count >= 2 {
            chain = zip(geometry.points, geometry.points.dropFirst()).map { ($0, $1) }
            totalField = .planLength
        } else {
            return []
        }
        let pageLengths = chain.map { $0.0.distance(to: $0.1) }
        let pageTotal = pageLengths.reduce(0, +)
        guard pageTotal > 0 else { return [] }
        let uniform = metresPerPoint.map { Swift.abs($0.x - $0.y) <= 1e-12 * Swift.max($0.x, $0.y) } ?? true
        if uniform, let total = record.measurement?[totalField]?.value {
            let totalDouble = NumericPolicy.double(from: total)
            return zip(chain, pageLengths).map { pair, length in
                let share = (try? NumericPolicy.decimal(from: totalDouble * length / pageTotal)) ?? 0
                return Segment(start: pair.0, end: pair.1, metres: share)
            }
        }
        guard let factors = metresPerPoint else { return [] }
        return chain.map { start, end in
            let dx = (end.x - start.x) * factors.x, dy = (end.y - start.y) * factors.y
            let metres = (try? NumericPolicy.decimal(from: (dx * dx + dy * dy).squareRoot())) ?? 0
            return Segment(start: start, end: end, metres: metres)
        }
    }

    /// The tools whose segments can be labelled.
    public static func offersSegmentLengths(_ tool: MeasurementTool?) -> Bool {
        switch tool {
        case .length, .polylength, .perimeter, .area, .rectangleArea, .volume, .wallArea,
             .trueSlopedLength, .trueSlopedArea, .polygonCutout: return true
        default: return false
        }
    }

    // MARK: Editing (the Inspector's Caption row)

    /// The commands that write `edit` into every record's caption, one `changeStyle` each; a
    /// caption that ends up saying nothing new is removed rather than stored.
    public static func commands(
        on records: [MarkupRecord],
        _ edit: (inout MeasurementCaption) -> Void
    ) -> [DocumentCommand] {
        records.compactMap { record in
            guard record.tool != nil else { return nil }
            var caption = record.style.measurementCaption ?? MeasurementCaption()
            edit(&caption)
            var style = record.style
            style.measurementCaption = caption.isDefault ? nil : caption
            guard style != record.style else { return nil }
            return .changeStyle(id: record.id, style: style)
        }
    }
}
