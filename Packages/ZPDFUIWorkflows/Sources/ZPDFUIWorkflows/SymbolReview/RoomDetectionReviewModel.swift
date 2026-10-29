import Foundation
import Observation
import ZPDFUIPresentation

/// One detected room in the review (NL-AUTO-08).
public struct RoomDetectionReviewRow: Identifiable, Hashable, Sendable {
    public let id: Int
    public var name: String
    /// The measured area in words the app tier wrote: "12.40 m²".
    public let areaText: String
    /// Closed openings, printed-area disagreement — in words; empty when there is nothing to say.
    public let notes: [String]
    public let bounds: PDFRectValue

    public init(id: Int, name: String, areaText: String, notes: [String], bounds: PDFRectValue) {
        self.id = id
        self.name = name
        self.areaText = areaText
        self.notes = notes
        self.bounds = bounds
    }
}

/// The rooms accepted, with their names as finally typed.
public struct RoomDetectionReviewOutcome: Hashable, Sendable {
    public let names: [Int: String]
}

/// Drives the room review: every detected room listed with its area and what the detector
/// assumed, names editable, and only the ticked rooms landing — in one undoable step.
@MainActor @Observable
public final class RoomDetectionReviewModel {

    public var rows: [RoomDetectionReviewRow]
    public var includedIDs: Set<Int>
    /// Said when the detector stopped early or refused the sheet.
    public let caveat: String?

    @ObservationIgnored private let onAccept: @MainActor (RoomDetectionReviewOutcome) -> Void
    @ObservationIgnored private let onCancel: @MainActor () -> Void
    @ObservationIgnored private let onReveal: @MainActor (RoomDetectionReviewRow) -> Void

    public init(
        rows: [RoomDetectionReviewRow],
        caveat: String? = nil,
        onAccept: @escaping @MainActor (RoomDetectionReviewOutcome) -> Void,
        onCancel: @escaping @MainActor () -> Void,
        onReveal: @escaping @MainActor (RoomDetectionReviewRow) -> Void = { _ in }
    ) {
        self.rows = rows
        self.includedIDs = Set(rows.map(\.id))
        self.caveat = caveat
        self.onAccept = onAccept
        self.onCancel = onCancel
        self.onReveal = onReveal
    }

    public func setIncluded(_ included: Bool, id: Int) {
        if included { includedIDs.insert(id) } else { includedIDs.remove(id) }
    }

    public func reveal(_ row: RoomDetectionReviewRow) { onReveal(row) }

    public var summaryText: String {
        var text = String(
            format: NSLocalizedString(
                "%1$@; %2$lld ticked. Nothing is measured until you add them.",
                comment: "Room detection review summary: the rooms found as '5 rooms found', the ticked count"
            ),
            WorkflowPlurals.roomsFound(rows.count), includedIDs.count
        )
        if let caveat { text += " " + caveat }
        return text
    }

    public var canAccept: Bool { !includedIDs.isEmpty }

    public func accept() {
        guard canAccept else { return }
        var names: [Int: String] = [:]
        for row in rows where includedIDs.contains(row.id) {
            names[row.id] = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        onAccept(RoomDetectionReviewOutcome(names: names))
    }

    public func cancel() { onCancel() }
}
