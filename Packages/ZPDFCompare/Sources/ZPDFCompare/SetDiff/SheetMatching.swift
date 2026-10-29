import Foundation

/// Why the matcher believes two sheets are the same drawing.
///
/// Every pair carries one of these, and it is not decoration. Invariant: sheets are never
/// matched silently, because a guessed pairing that is wrong reports changes on the wrong
/// drawing. A basis is how a pairing stops being silent: the
/// interface can show it, sort by it, and let a person correct the weak ones.
public enum MatchBasis: String, Sendable, Hashable, Codable, CaseIterable {

    /// The two labels are byte-for-byte identical, and neither label repeats anywhere in
    /// its own set. The strongest evidence available without opening a page.
    case exactLabel

    /// The two labels agree after normalisation — trimmed, case-folded, internal
    /// whitespace collapsed, and possibly with one trailing revision suffix removed on
    /// one or both sides. `A-101` paired with `A-101-B` lands here. See ``SheetLabel``.
    case normalisedLabel

    /// No label evidence at all. The two sheets are the same paper size and occupy the
    /// same position among the sheets nothing else could match, so they are paired on
    /// that alone. This is the weakest pairing the engine will produce and the one an
    /// interface should push hardest to have confirmed.
    case positionFallback

    /// A person said so, through ``SheetMatching/overriding(pairOldIndex:newIndex:)``.
    /// Not a guess, and never produced by ``SheetMatcher``.
    case manualOverride

    /// `true` when the engine inferred the pairing rather than being told it or reading
    /// it off identical labels.
    ///
    /// This is the flag an interface should hang a "confirm this" affordance on.
    public var isGuess: Bool {
        switch self {
        case .exactLabel, .manualOverride: return false
        case .normalisedLabel, .positionFallback: return true
        }
    }
}

/// One old sheet paired with one new sheet, and the reason.
public struct SheetPair: Sendable, Hashable, Codable {
    /// ``SetSheet/index`` of the sheet in the old set.
    public var old: Int
    /// ``SetSheet/index`` of the sheet in the new set.
    public var new: Int
    public var basis: MatchBasis

    public init(old: Int, new: Int, basis: MatchBasis) {
        self.old = old
        self.new = new
        self.basis = basis
    }
}

/// Why a matching could not be produced or corrected.
public enum SheetMatchingFault: Error, Sendable, Hashable, CustomStringConvertible {
    /// Two descriptors in one set claim the same ``SetSheet/index``. The matcher refuses
    /// rather than dropping one, because a dropped sheet is a sheet whose changes are
    /// never reported.
    case duplicateSheetIndex(side: SetSide, index: Int)
    /// An override named an old index the matching was not built over.
    case unknownOldSheet(index: Int)
    /// An override named a new index the matching was not built over.
    case unknownNewSheet(index: Int)

    public var description: String {
        switch self {
        case let .duplicateSheetIndex(side, index):
            return "the \(side.rawValue) set lists page index \(index) more than once"
        case let .unknownOldSheet(index):
            return "page index \(index) is not in the old set of this matching"
        case let .unknownNewSheet(index):
            return "page index \(index) is not in the new set of this matching"
        }
    }
}

/// What the matcher concluded about two whole drawing sets.
///
/// Three lists that partition the two sets between them, plus the honesty flags. Nothing
/// in here has looked at a single pixel or a single path: this is the answer to *"which
/// sheet is which"*, produced before the per-page comparison in ``RevisionComparator``
/// is pointed at anything.
public struct SheetMatching: Sendable, Hashable, Codable {

    /// The pairings, ascending by ``SheetPair/old``.
    public let pairs: [SheetPair]
    /// ``SetSheet/index`` values in the new set with no counterpart in the old set,
    /// ascending. These are the sheets that were added.
    public let addedInNew: [Int]
    /// ``SetSheet/index`` values in the old set with no counterpart in the new set,
    /// ascending. These are the sheets that were removed — and the ones that can orphan
    /// measurements.
    public let removedFromOld: [Int]

    /// `true` when some label occurs more than once within a set, after normalisation.
    ///
    /// A duplicated label destroys the only cheap evidence the matcher has. When this is
    /// set, the pairings among the duplicates were made on position and paper size
    /// alone — see ``MatchBasis/positionFallback`` — and an interface that presents them
    /// without saying so is presenting a guess as a fact.
    public let isAmbiguous: Bool

    /// The normalised labels that occur more than once, ascending, so an interface can
    /// name them rather than only flagging that something is wrong.
    public let ambiguousLabels: [String]

    /// Every ``SetSheet/index`` the matching was built over, on the old side, ascending.
    public let oldSheetIndices: [Int]
    /// Every ``SetSheet/index`` the matching was built over, on the new side, ascending.
    public let newSheetIndices: [Int]

    public init(
        pairs: [SheetPair],
        addedInNew: [Int],
        removedFromOld: [Int],
        isAmbiguous: Bool,
        ambiguousLabels: [String] = [],
        oldSheetIndices: [Int],
        newSheetIndices: [Int]
    ) {
        self.pairs = pairs.sorted { $0.old < $1.old }
        self.addedInNew = addedInNew.sorted()
        self.removedFromOld = removedFromOld.sorted()
        self.isAmbiguous = isAmbiguous
        self.ambiguousLabels = ambiguousLabels.sorted()
        self.oldSheetIndices = oldSheetIndices.sorted()
        self.newSheetIndices = newSheetIndices.sorted()
    }

    /// An empty matching over two empty sets.
    public static let empty = SheetMatching(
        pairs: [],
        addedInNew: [],
        removedFromOld: [],
        isAmbiguous: false,
        oldSheetIndices: [],
        newSheetIndices: []
    )

    // MARK: - Reading

    /// The pairs the engine inferred rather than read off identical labels or was told.
    ///
    /// The worklist for a review pass: these, and only these, are the pairings that must
    /// never stay silent.
    public var guessedPairs: [SheetPair] { pairs.filter { $0.basis.isGuess } }

    /// The new-side counterpart of an old sheet, if it has one.
    public func newIndex(forOldIndex index: Int) -> Int? {
        pairs.first { $0.old == index }?.new
    }

    /// Why these two are paired, or `nil` when they are not paired with each other.
    public func basis(oldIndex: Int, newIndex: Int) -> MatchBasis? {
        pairs.first { $0.old == oldIndex && $0.new == newIndex }?.basis
    }

    /// `true` when the three lists partition the two rosters exactly: no sheet paired
    /// twice, no sheet both paired and unmatched, no sheet unaccounted for.
    ///
    /// The invariant every producer here maintains, exposed so a test can assert it
    /// rather than infer it from three separate comparisons.
    public var isWellFormed: Bool {
        let pairedOld = pairs.map(\.old)
        let pairedNew = pairs.map(\.new)
        let oldSet = Set(pairedOld)
        let newSet = Set(pairedNew)
        guard oldSet.count == pairedOld.count, newSet.count == pairedNew.count else { return false }
        guard oldSet.isDisjoint(with: removedFromOld), newSet.isDisjoint(with: addedInNew) else {
            return false
        }
        guard Set(removedFromOld).count == removedFromOld.count else { return false }
        guard Set(addedInNew).count == addedInNew.count else { return false }
        return oldSet.union(removedFromOld) == Set(oldSheetIndices)
            && newSet.union(addedInNew) == Set(newSheetIndices)
    }

    // MARK: - Correcting

    /// `true` when both indices belong to this matching, so an override would be accepted.
    public func canOverride(pairOldIndex oldIndex: Int, newIndex: Int) -> Bool {
        oldSheetIndices.contains(oldIndex) && newSheetIndices.contains(newIndex)
    }

    /// The same matching with `oldIndex` paired to `newIndex` on a
    /// ``MatchBasis/manualOverride`` basis.
    ///
    /// This is the correctable half of that invariant. A guessed pairing is only
    /// harmless if somebody can undo it, and undoing one pairing necessarily disturbs
    /// two others: whatever `oldIndex` used to be paired with, and whatever `newIndex`
    /// used to be paired with. Both are **displaced back to unmatched** — the new-side
    /// orphan joins ``addedInNew``, the old-side orphan joins ``removedFromOld`` — rather
    /// than being re-paired with each other behind the user's back. Re-pairing them would
    /// be exactly the silent guess this rule forbids; if that is what the user wants, it
    /// is a second override and it says so.
    ///
    /// ``isAmbiguous`` and ``ambiguousLabels`` survive unchanged. They describe the
    /// labels in the two sets, not the state of the matching, and correcting one pairing
    /// does not un-duplicate a label.
    ///
    /// - Throws: ``SheetMatchingFault/unknownOldSheet(index:)`` or
    ///   ``SheetMatchingFault/unknownNewSheet(index:)`` when an index is not part of this
    ///   matching. A silently ignored override would leave the interface showing a
    ///   correction that never happened.
    public func overriding(pairOldIndex oldIndex: Int, newIndex: Int) throws -> SheetMatching {
        guard oldSheetIndices.contains(oldIndex) else {
            throw SheetMatchingFault.unknownOldSheet(index: oldIndex)
        }
        guard newSheetIndices.contains(newIndex) else {
            throw SheetMatchingFault.unknownNewSheet(index: newIndex)
        }

        var kept: [SheetPair] = []
        kept.reserveCapacity(pairs.count + 1)
        var displacedOld: [Int] = []
        var displacedNew: [Int] = []

        for pair in pairs {
            if pair.old == oldIndex, pair.new == newIndex {
                // Already this pairing. It is rebuilt below on a manual basis, because a
                // person confirming a guess is information the guess did not carry.
                continue
            }
            if pair.old == oldIndex {
                displacedNew.append(pair.new)
                continue
            }
            if pair.new == newIndex {
                displacedOld.append(pair.old)
                continue
            }
            kept.append(pair)
        }
        kept.append(SheetPair(old: oldIndex, new: newIndex, basis: .manualOverride))

        var added = Set(addedInNew)
        added.formUnion(displacedNew)
        added.remove(newIndex)
        var removed = Set(removedFromOld)
        removed.formUnion(displacedOld)
        removed.remove(oldIndex)

        return SheetMatching(
            pairs: kept,
            addedInNew: Array(added),
            removedFromOld: Array(removed),
            isAmbiguous: isAmbiguous,
            ambiguousLabels: ambiguousLabels,
            oldSheetIndices: oldSheetIndices,
            newSheetIndices: newSheetIndices
        )
    }

    /// The same matching with the pairing for `oldIndex` removed, both sheets returned to
    /// unmatched.
    ///
    /// The other half of correctable: a person who can see that two sheets are *not* the
    /// same drawing needs to be able to say so without inventing a different partner.
    ///
    /// - Throws: ``SheetMatchingFault/unknownOldSheet(index:)`` when `oldIndex` is not
    ///   part of this matching. Unpairing a sheet that is already unpaired is not a
    ///   fault; it returns the matching unchanged.
    public func unpairing(oldIndex: Int) throws -> SheetMatching {
        guard oldSheetIndices.contains(oldIndex) else {
            throw SheetMatchingFault.unknownOldSheet(index: oldIndex)
        }
        guard let existing = pairs.first(where: { $0.old == oldIndex }) else { return self }
        return SheetMatching(
            pairs: pairs.filter { $0.old != oldIndex },
            addedInNew: addedInNew + [existing.new],
            removedFromOld: removedFromOld + [oldIndex],
            isAmbiguous: isAmbiguous,
            ambiguousLabels: ambiguousLabels,
            oldSheetIndices: oldSheetIndices,
            newSheetIndices: newSheetIndices
        )
    }
}
