import Foundation
import ZPDFContracts

/// The session's markups by identity, remembering which ones were written since each cache
/// last looked.
///
/// A plain dictionary with a record of the keys its subscript and `removeValue` touched. Every
/// write in ``TakeoffSession`` already goes through one of those two, so the change sets the
/// snapshot caches need (IM-001, IM-002) come for free and cannot be forgotten by a new command:
/// there is no other way to change a markup.
///
/// Two independent change sets, because two caches consume them at different moments — the
/// ledger view on every filter keystroke, the canvas summaries on every snapshot — and one
/// consumer must not swallow the other's news. Restoring a saved table (a command rolled back
/// part-way) restores its change sets too, which is correct: the rows are back to what the
/// caches last saw.
struct MarkupTable: Sendable, ExpressibleByDictionaryLiteral {

    private(set) var storage: [MarkupID: MarkupRecord]
    private var ledgerChanges: Set<MarkupID> = []
    private var summaryChanges: Set<MarkupID> = []
    /// Bumped by every write; a caller that saw revision `n` has seen every change up to it.
    private(set) var revision: UInt64 = 0

    init(dictionaryLiteral elements: (MarkupID, MarkupRecord)...) {
        storage = Dictionary(elements, uniquingKeysWith: { _, last in last })
    }

    subscript(id: MarkupID) -> MarkupRecord? {
        get { storage[id] }
        set {
            storage[id] = newValue
            revision &+= 1
            ledgerChanges.insert(id)
            summaryChanges.insert(id)
        }
    }

    @discardableResult
    mutating func removeValue(forKey id: MarkupID) -> MarkupRecord? {
        ledgerChanges.insert(id)
        summaryChanges.insert(id)
        revision &+= 1
        return storage.removeValue(forKey: id)
    }

    var values: Dictionary<MarkupID, MarkupRecord>.Values { storage.values }
    var keys: Dictionary<MarkupID, MarkupRecord>.Keys { storage.keys }
    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    /// The markups written since the ledger cache last asked, and forgets them.
    mutating func takeLedgerChanges() -> Set<MarkupID> {
        defer { ledgerChanges = [] }
        return ledgerChanges
    }

    /// The markups written since the summary cache last asked, and forgets them.
    mutating func takeSummaryChanges() -> Set<MarkupID> {
        defer { summaryChanges = [] }
        return summaryChanges
    }
}
