import Foundation

/// What a measurement's pill says and where it sits (NL-MEASURE-09, ADR-0030 §3).
///
/// Display only. Nothing here is a stored quantity: the fields are read from the markup's own
/// ``MeasurementResult`` through the one ledger formatter, and segment lengths are derived from the
/// stored geometry at draw time. Absent (`MarkupStyle.measurementCaption == nil`) means what every
/// markup has always shown — the label and the tool's headline value, at the automatic position.
public struct MeasurementCaption: Codable, Hashable, Sendable {
    /// The fields the pill shows, in this order. Empty means the tool's headline field alone.
    public var fields: [MeasurementField]
    /// Whether a linear or areal markup also draws a length beside every segment.
    public var showsSegmentLengths: Bool
    /// Where the pill was dragged to, in PDF points from its automatic position; `nil` for the
    /// automatic position.
    public var labelOffset: PDFPoint?

    public init(fields: [MeasurementField] = [], showsSegmentLengths: Bool = false, labelOffset: PDFPoint? = nil) {
        self.fields = fields
        self.showsSegmentLengths = showsSegmentLengths
        self.labelOffset = labelOffset
    }

    /// True when it says nothing the default does not: no extra field, no segments, no offset.
    public var isDefault: Bool { fields.isEmpty && !showsSegmentLengths && labelOffset == nil }
}
