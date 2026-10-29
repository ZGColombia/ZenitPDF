import Foundation

/// The values an Inspector stepper has asked for that the snapshot has not shown yet
/// (V-043, BH-802).
///
/// A stepper's edit is asynchronous: the application performs it and refreshes the snapshot
/// later. Each click must step from the value it last asked for, not from the snapshot, or two
/// quick clicks ask for the same value twice. Keeping only the *last* ask and dropping it on any
/// snapshot change was not enough: with asks 2 and 3 in flight, the refresh for 2 landed, the
/// pending 3 was forgotten, and the next click stepped from 2 and asked for 3 again — a
/// duplicate undo step and audit row, and a lost click. That is what a held stepper does
/// whenever the edit and its refresh take longer than the auto-repeat interval.
///
/// So every ask still in flight is kept, in order. The edits land in the order they were asked,
/// so a snapshot value equal to one of them means every ask up to it has landed: those are
/// dropped and the rest stay in flight. A snapshot value that was never asked for — an undo,
/// another window's edit, a different selection — is the truth moving underneath the stepper,
/// and it drops them all, so the next click steps from the snapshot.
struct InspectorStepsInFlight<Value> {

    /// The asks still in flight, oldest first.
    private(set) var asks: [Value] = []

    init() {}

    /// The value the last click asked for while it is still in flight: the base of the next
    /// click and the value the control shows.
    var last: Value? { asks.last }

    /// Records a click's ask.
    mutating func asked(_ value: Value) {
        asks.append(value)
    }

    /// The application refused an ask (W-039). A refused edit never reaches the snapshot, so
    /// waiting for it would hold the control on a value that was never stored; every ask is
    /// dropped and the next click steps from the snapshot.
    mutating func refused() {
        asks.removeAll()
    }

    /// The snapshot now holds `landed` (`nil` for a mixed selection).
    ///
    /// The earliest matching ask is taken as the one that landed: edits land in order, so a
    /// later equal ask (a click back to a value) is still in flight.
    mutating func snapshotMoved(to landed: Value?, matches: (Value, Value) -> Bool) {
        guard let landed, let index = asks.firstIndex(where: { matches($0, landed) }) else {
            asks.removeAll()
            return
        }
        asks.removeFirst(index + 1)
    }
}

extension InspectorStepsInFlight where Value: Equatable {

    /// ``snapshotMoved(to:matches:)`` by equality.
    mutating func snapshotMoved(to landed: Value?) {
        snapshotMoved(to: landed, matches: ==)
    }
}
