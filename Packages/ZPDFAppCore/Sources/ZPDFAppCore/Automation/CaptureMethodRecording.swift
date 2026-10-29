import Foundation
import ZPDFContracts
import ZPDFMeasurementEngine

/// Recording how a measurement was captured (NL-AUTO-18, ADR-0031).
///
/// A detector's accepted proposal enters the session as an ordinary `addMarkup` whose record
/// carries a *capture stamp*: a measurement result with no values whose provenance names the
/// capture method and the digest of the geometry it describes. The session recomputes the
/// record as it recomputes every record, and ``CaptureMethodCarry`` keeps the method on the new
/// provenance because the geometry digest matches. From then on the method rides with the
/// geometry through every recalculation, and is dropped the moment the geometry changes by hand.
public enum CaptureStamp {

    /// `record` carrying `method` into the session. The values are left empty on purpose: the
    /// session computes them; a stamp never supplies a number.
    public static func stamped(_ record: MarkupRecord, method: CaptureMethod) -> MarkupRecord {
        guard let geometry = record.geometry else { return record }
        var stamped = record
        let stub = MeasurementProvenance(
            geometryDigest: GeometryDigest.digest(of: geometry),
            scaleID: record.scaleID ?? ScaleID(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!),
            scaleVersion: 0, scaleSource: .preset, slope: .none, parameters: record.parameters ?? .default,
            formulaVersion: 0, engineVersion: "capture-stamp", computedAt: Date(timeIntervalSince1970: 0),
            captureMethod: method)
        stamped.measurement = MeasurementResult(values: [:], provenance: stub)
        return stamped
    }
}

/// Keeps a capture method across a recalculation (ADR-0031).
public enum CaptureMethodCarry {

    /// The new provenance with the previous capture method, when there is one to keep and the
    /// geometry is the one it described; `nil` when nothing is to be carried.
    public static func carried(previous: MeasurementProvenance?, into new: MeasurementProvenance?) -> MeasurementProvenance? {
        guard let previous, let method = previous.captureMethod, method.kind != .manual,
              let new, new.captureMethod == nil, new.geometryDigest == previous.geometryDigest else { return nil }
        return new.with(captureMethod: method)
    }

    /// The stamp to keep while a markup waits on an uncalibrated page: `previous` when it carries
    /// a detector's method for exactly `geometry`, otherwise `nil`.
    public static func setAside(_ previous: MeasurementProvenance?, geometry: MeasurementGeometry) -> MeasurementProvenance? {
        guard let previous, let method = previous.captureMethod, method.kind != .manual,
              previous.geometryDigest == GeometryDigest.digest(of: geometry) else { return nil }
        return previous
    }
}

extension TakeoffSession.TakeoffState {
    /// The state with the capture methods set aside on uncalibrated pages (ADR-0031).
    func settingAsideCaptures(_ captures: [MarkupID: CaptureMethod]) -> Self {
        var state = self
        state.uncalibratedCaptures = captures
        return state
    }
}

/// The capture method in words, for the derivation panel and the export's trace column.
public enum CaptureDescription {

    public static func text(_ method: CaptureMethod) -> String {
        switch method.kind {
        case .manual:
            return NSLocalizedString("drawn by hand", comment: "Capture method: a person drew it")
        case .autoTraced:
            let widths = method.closureWidthsPoints ?? []
            guard !widths.isEmpty else {
                return NSLocalizedString("traced, no closing lines", comment: "Capture method: traced without bridging a gap")
            }
            let listed = widths.map { points($0) }.joined(separator: ", ")
            return widths.count == 1
                ? String(format: NSLocalizedString("traced, 1 closing line %@ pt", comment: "Capture method: traced with one closing line; its width"), listed)
                : String(format: NSLocalizedString("traced, %1$d closing lines %2$@ pt", comment: "Capture method: traced with closing lines; count, widths"), widths.count, listed)
        case .symbolMatched:
            var text = String(format: NSLocalizedString("matched, residual %@", comment: "Capture method: symbol match; its residual"),
                              decimal(method.residualRatio ?? 0, places: 3))
            if method.isMirrored == true { text += NSLocalizedString(", mirrored", comment: "Capture method: the match was mirrored") }
            return text
        case .exactBlock:
            return NSLocalizedString("exact block", comment: "Capture method: an exact repeat of a CAD block")
        case .roomDetected:
            return NSLocalizedString("room detected", comment: "Capture method: found by the room detector")
        case .fromScan:
            return String(format: NSLocalizedString("from the scan, %d %% sure", comment: "Capture method: from a scanned sheet; confidence percent"),
                          Int(((method.confidence ?? 0) * 100).rounded()))
        case .wallCentreline:
            let millimetres = method.wallThicknessMetres.map { NSDecimalNumber(decimal: $0 * 1000).intValue }
            return millimetres.map { String(format: NSLocalizedString("wall centreline, %d mm wall", comment: "Capture method: wall centreline; thickness in mm"), $0) }
                ?? NSLocalizedString("wall centreline", comment: "Capture method: wall centreline")
        case .importedAnnotation:
            return NSLocalizedString("read from file", comment: "Capture method: geometry read from a PDF measurement annotation")
        case .unrecognised:
            return NSLocalizedString("captured by a method this version does not know", comment: "Capture method written by a newer build")
        }
    }

    static func points(_ value: Double) -> String { decimal(value, places: 1) }

    static func decimal(_ value: Double, places: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        formatter.minimumIntegerDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// The capture method in the project file (ADR-0031, schema v17 `markup_extra.capture_json`).
///
/// The session recomputes every measurement on open, so a capture method that lived only in the
/// computed provenance would be lost at the first reopen. It is written beside the geometry —
/// only for a detector's capture; a person's drawing writes nothing — and read back as a capture
/// stamp the recompute keeps.
public enum CaptureArchive {

    /// `setAside` is the method the session keeps for a markup on a page with no scale yet.
    public static func json(of record: MarkupRecord, setAside: CaptureMethod? = nil) throws -> String? {
        guard let method = record.measurement?.provenance?.captureMethod ?? setAside, method.kind != .manual else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(method), as: UTF8.self)
    }

    /// `record` with its stored capture restored as a stamp. A column that does not decode is
    /// ignored: the markup reads as drawn by hand rather than failing to open.
    public static func restoring(json: String?, into record: MarkupRecord) -> MarkupRecord {
        guard let json, let method = try? JSONDecoder().decode(CaptureMethod.self, from: Data(json.utf8)) else { return record }
        return CaptureStamp.stamped(record, method: method)
    }
}
