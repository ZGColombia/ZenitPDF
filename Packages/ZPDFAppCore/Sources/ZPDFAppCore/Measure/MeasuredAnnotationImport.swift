import Foundation
import ZPDFContracts

/// Measurement annotations from another PDF reader become live Zenit measurements
/// (NL-MEASURE-16, the import half).
///
/// A Line, PolyLine or Polygon annotation whose `/IT` says it measures (`LineDimension`,
/// `PolyLineDimension`, `PolygonDimension` — ISO 32000-1 §12.5.6.7, what Zenit's own annotated
/// export writes) imports as a Length, Polylength or Area on the same geometry, measured by
/// Zenit's engine at the scale where it lies: inside one Scale Region that region's, elsewhere
/// the page's own (the review import places it, T-025). The file's number (its `/Contents`,
/// e.g. "5.40 m") is kept beside Zenit's in the markup's note — shown, never trusted over it. A
/// page with no scale cannot be measured, so there the annotation stays the plain markup the
/// review import makes.
public enum MeasuredAnnotationImport {

    /// The measuring intents and the tool each becomes.
    public static let tools: [String: MeasurementTool] = [
        "LineDimension": .length,
        "PolyLineDimension": .polylength,
        "PolygonDimension": .area
    ]

    /// The plan with every measuring annotation on a calibrated page turned into a measurement.
    public static func converting(
        _ plan: AnnotationImportPlan,
        annotations: [ImportedAnnotation],
        fileDigest: String,
        calibratedPages: Set<PageID>
    ) -> AnnotationImportPlan {
        var byID: [MarkupID: ImportedAnnotation] = [:]
        for annotation in annotations where annotation.inReplyToIndex == nil {
            byID[AnnotationImportPlanner.identity(of: annotation, fileDigest: fileDigest)] = annotation
        }
        var converted = plan
        converted.newMarkups = plan.newMarkups.map { record in
            guard let annotation = byID[record.id], calibratedPages.contains(record.pageID),
                  let measured = measurement(from: annotation, record: record) else { return record }
            return measured
        }
        return converted
    }

    /// The measurement one annotation becomes, or `nil` when it does not measure.
    static func measurement(from annotation: ImportedAnnotation, record: MarkupRecord) -> MarkupRecord? {
        guard let intent = annotation.intent, let tool = tools[intent] else { return nil }
        let points = annotation.points.filter(\.isFinite)
        var measured = record
        switch tool {
        case .length:
            guard points.count >= 2 else { return nil }
            measured.geometry = MeasurementGeometry(pageID: record.pageID, points: Array(points.prefix(2)))
        case .polylength:
            guard points.count >= 2 else { return nil }
            measured.geometry = MeasurementGeometry(pageID: record.pageID, points: points)
        default:
            guard points.count >= 3 else { return nil }
            measured.geometry = MeasurementGeometry(
                pageID: record.pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: points, isClosed: true))]
            )
        }
        measured.kind = .measurement
        measured.tool = tool
        measured.parameters = .default
        measured.measurement = nil
        let fileValue = (annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Written before the review import places the record, and a stored note never follows a
        // later move into or out of a region, so it names no particular scale: a note saying
        // "this page's scale" on a measurement taken at a Scale Region's was wrong provenance
        // (T-025). The Inspector shows the scale the measurement actually uses.
        let note = fileValue.isEmpty
            ? NSLocalizedString("Measured from a PDF measurement annotation.", comment: "Imported measurement note: the file stated no value")
            : String(format: NSLocalizedString(
                "The file said: %@. Zenit measured it again at the scale where it lies (its Scale Region’s, or the page’s).",
                comment: "Imported measurement note: the file's own value; Zenit re-measured at the Scale Region's scale or, outside every region, the page's"
            ), String(fileValue.prefix(200)))
        measured.comment = note
        // ADR-0031: the geometry was read from the file, and the measurement says so.
        return CaptureStamp.stamped(measured, method: CaptureMethod(kind: .importedAnnotation))
    }
}
