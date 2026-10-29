import Foundation
import ZPDFCollaboration
import ZPDFContracts
import ZPDFMeasurementEngine

/// A markup written by another build, as this build takes it in (X-042, cycle 2).
///
/// Before X-042 an Arc Length could be committed with more than three points; the engine measured
/// the arc through the first three and ignored the rest. Today's engine refuses a fourth point,
/// which is right for a commit and wrong for a record somebody saved yesterday: refused, it fails
/// the whole step it arrives in. Such records do not only come from this machine's project file.
/// They come from a Shared Review Folder and a `.zpdfreview` file (a colleague on an older build,
/// adding or moving one), from a Measurements Overlay, and from the pasteboard (copied before an
/// update, pasted after). Every one of those doors calls this, so a saved record opens as the
/// three points it was measured on wherever it comes from, while a live four-point commit is
/// still refused by the engine.
public enum SavedMarkupRepair {

    /// `record` as this build opens it: an Arc Length saved with more than three points becomes
    /// its first three distinct points (``ArcLengthCalculator/storedGeometry(_:options:)``) — the
    /// same value, now drawn and snapped as that arc. Every other record is returned unchanged.
    public static func opened(_ record: MarkupRecord) -> MarkupRecord {
        guard record.tool == .arcLength, let geometry = record.geometry else { return record }
        let repaired = ArcLengthCalculator.storedGeometry(geometry)
        guard repaired != geometry else { return record }
        var opened = record
        opened.geometry = repaired
        return opened
    }

    /// Markups held as registers — a Shared Review Folder's merged state, a review file's, or a
    /// participant's base — with each record's shape opened as ``opened(_:)`` opens it.
    ///
    /// The merged state and the base have to be opened alike, and alike with the document,
    /// whose records `hydrate` already opened. A merged state left at four points would differ
    /// from the document's three on every sync, and be reported as changed by somebody else
    /// every time. A base left at four points would make this machine publish the repair as an
    /// edit of its own, with a clock newer than a colleague's move, so the move would be lost on
    /// every machine.
    ///
    /// Only the shape register of a record the repair changes is rewritten; every other register
    /// keeps its bytes. The byte test on the identity register only skips work: a record whose
    /// identity does not spell the tool is not an Arc Length, and one that does is decoded.
    static func opened(_ registers: [MarkupID: MarkupRegisters]) -> [MarkupID: MarkupRegisters] {
        let arcLengthTool = Data("\"\(MeasurementTool.arcLength.rawValue)\"".utf8)
        var result = registers
        for (id, entry) in registers {
            guard let identity = entry.values[.identity], identity.range(of: arcLengthTool) != nil,
                  let record = entry.record(modifiedAt: Date(timeIntervalSince1970: 0)) else { continue }
            let repaired = opened(record)
            guard repaired.geometry != record.geometry,
                  let shape = MarkupRegisters(record: repaired).values[.shape] else { continue }
            result[id]?.values[.shape] = shape
        }
        return result
    }
}
