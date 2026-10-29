import Foundation
import ZPDFContracts

/// Sequential numbering of a count's marks (NL-MEASURE-12, spec 12.13).
///
/// The contract already has the slot: ``ZPDFContracts/CountPoint/sequenceNumber`` is "position in
/// the sequential numbering, when numbering is switched on". A count is numbered when **every**
/// mark carries its number, 1…n in placement order (the order the marks are stored in). Turning
/// numbering on or off is an `editVertices` on the same record — same marks, same positions, same
/// count — so it is one undo step, saved with the geometry, and never changes the quantity.
public enum CountNumbering {

    /// Whether the count's marks are numbered.
    public static func isNumbered(_ geometry: MeasurementGeometry?) -> Bool {
        guard let points = geometry?.countPoints, !points.isEmpty else { return false }
        return points.allSatisfy { $0.sequenceNumber != nil }
    }

    /// The same geometry with the marks numbered 1…n in placement order, or with the numbers
    /// removed. Positions, identities, groups and symbols are untouched.
    public static func numbered(_ geometry: MeasurementGeometry, on: Bool) -> MeasurementGeometry {
        var copy = geometry
        copy.countPoints = geometry.countPoints.enumerated().map { index, point in
            var mark = point
            mark.sequenceNumber = on ? index + 1 : nil
            return mark
        }
        return copy
    }

    /// Each mark's running number, parallel to the marks, or empty when the count is not
    /// numbered. What the canvas draws.
    public static func numbers(of record: MarkupRecord) -> [Int] {
        guard record.tool == .count, isNumbered(record.geometry), let points = record.geometry?.countPoints else { return [] }
        return points.map { $0.sequenceNumber ?? 0 }
    }

    /// The commands that switch numbering for these counts: on for all when any is unnumbered,
    /// off for all when every one is numbered. Records that are not counts are skipped.
    public static func toggleCommands(for records: [MarkupRecord]) -> (commands: [DocumentCommand], turnsOn: Bool) {
        // A count whose marks sit in `points` (placed from a preset before V-031) is numbered
        // too: its marks move into `countPoints` in the same edit, same positions, same count.
        let counts = records.compactMap { record -> (MarkupRecord, MeasurementGeometry)? in
            guard record.tool == .count, let geometry = record.geometry?.countMarksInCountPoints(),
                  !geometry.countPoints.isEmpty else { return nil }
            return (record, geometry)
        }
        let turnsOn = !counts.allSatisfy { isNumbered($0.1) }
        let commands = counts.map { record, geometry -> DocumentCommand in
            .editVertices(id: record.id, geometry: numbered(geometry, on: turnsOn))
        }
        return (commands, turnsOn)
    }
}

extension MeasurementGeometry {

    /// A count's geometry with its marks in ``countPoints``, where the Count tool writes them.
    ///
    /// A count placed from a Tool Library preset before V-031 kept its mark in ``points``, and a
    /// save wrote such a geometry as a polyline blob, so it reopened the same way. The calculator
    /// counts either, but Continue, Number Marks and the canvas's marks read only ``countPoints``.
    /// Each point becomes a mark with a fresh identity at the same position, and ``points`` is
    /// emptied, so the count is unchanged. A geometry that already has marks, or has no points,
    /// is returned as it is. Call it only on a count's geometry.
    public func countMarksInCountPoints(makeID: () -> UUID = UUID.init) -> MeasurementGeometry {
        guard countPoints.isEmpty, !points.isEmpty else { return self }
        var copy = self
        copy.countPoints = points.map { CountPoint(id: CountPointID(makeID()), position: $0) }
        copy.points = []
        copy.pointBulges = nil
        return copy
    }
}
