import Foundation
import Observation
import SwiftUI
import ZPDFCompare
import ZPDFDesignSystem
import ZPDFPersistence

/// The review of how a revision's sheets pair with the set's (NL-DOCS-11): every pairing shown
/// with the evidence it rests on, the weak ones flagged, every one correctable, nothing stored
/// until the person confirms. "Match sheets silently" is the thing this exists to prevent.
@MainActor
@Observable
final class SheetMatchReviewModel {

    struct Row: Identifiable, Equatable {
        /// The set sheet's place in the set.
        let setIndex: Int
        let pageID: String
        let setLabel: String
        /// The revision page it pairs with, or `nil` for a sheet the revision drops.
        let partner: Int?
        let basis: MatchBasis?
        var id: Int { setIndex }
    }

    let revisionName: String
    let revisionLabels: [String]
    private let setSheets: [(pageID: String, label: String)]
    /// The pairing under review: the set is the old side, by set position, and the revision the
    /// new side, by page. Every correction goes through the engine's own rule
    /// (``SheetMatching/overriding(pairOldIndex:newIndex:)`` and
    /// ``SheetMatching/unpairing(oldIndex:)``), so the sheet and the tested engine cannot drift
    /// apart on how a manual pairing displaces earlier partners (V-081).
    private(set) var matching: SheetMatching
    var onAccept: (@MainActor ([RevisionSheetRecord]) -> Void)?
    var onCancel: (@MainActor () -> Void)?

    init(revisionName: String, setSheets: [(pageID: String, label: String)], revisionLabels: [String], matching: SheetMatching) {
        self.revisionName = revisionName
        self.revisionLabels = revisionLabels
        self.setSheets = setSheets
        self.matching = Self.covering(matching, setCount: setSheets.count, revisionCount: revisionLabels.count)
    }

    /// `matching` over exactly the set's sheets and the revision's pages. A matching built over
    /// other rosters — the matcher's empty answer after a refusal, or one with pairs outside
    /// the two lists — keeps only its pairs between sheets both lists have, and every other
    /// sheet is unmatched, so a correction is never refused for an index the review shows.
    static func covering(_ matching: SheetMatching, setCount: Int, revisionCount: Int) -> SheetMatching {
        let old = Array(0..<max(0, setCount)), new = Array(0..<max(0, revisionCount))
        if matching.isWellFormed, matching.oldSheetIndices == old, matching.newSheetIndices == new { return matching }
        let pairs = matching.pairs.filter { old.contains($0.old) && new.contains($0.new) }
        return SheetMatching(
            pairs: pairs,
            addedInNew: new.filter { index in !pairs.contains { $0.new == index } },
            removedFromOld: old.filter { index in !pairs.contains { $0.old == index } },
            isAmbiguous: matching.isAmbiguous,
            ambiguousLabels: matching.ambiguousLabels,
            oldSheetIndices: old,
            newSheetIndices: new
        )
    }

    /// One row per set sheet, in set order, read off ``matching``.
    var rows: [Row] {
        setSheets.enumerated().map { index, sheet in
            let partner = matching.newIndex(forOldIndex: index)
            return Row(
                setIndex: index, pageID: sheet.pageID, setLabel: sheet.label,
                partner: partner, basis: partner.flatMap { matching.basis(oldIndex: index, newIndex: $0) }
            )
        }
    }

    /// Revision pages no set sheet pairs with: sheets the revision adds.
    var addedRevisionPages: [Int] { matching.addedInNew }

    /// Set sheets with no partner: sheets the revision drops.
    var removedSheets: [Row] {
        let removed = Set(matching.removedFromOld)
        return rows.filter { removed.contains($0.setIndex) }
    }

    /// Pairings the matcher inferred rather than read off identical sheet numbers.
    var guessedRows: [Row] {
        let guessed = Set(matching.guessedPairs.map(\.old))
        return rows.filter { guessed.contains($0.setIndex) }
    }

    /// Pairs a set sheet with a revision page, or with none. A person's choice is manual
    /// evidence; a page already paired elsewhere is taken from that sheet, and both former
    /// partners are left unmatched rather than re-paired behind the person's back — the
    /// engine's rule, applied by the engine.
    func setPartner(_ revisionIndex: Int?, forSetIndex setIndex: Int) {
        if let revisionIndex {
            guard matching.canOverride(pairOldIndex: setIndex, newIndex: revisionIndex),
                  let corrected = try? matching.overriding(pairOldIndex: setIndex, newIndex: revisionIndex)
            else { return }
            matching = corrected
        } else if let corrected = try? matching.unpairing(oldIndex: setIndex) {
            matching = corrected
        }
    }

    /// "29 matched · 1 to check · 1 added · 0 dropped".
    var summaryText: String {
        String(
            format: NSLocalizedString(
                "%1$d matched · %2$d to check · %3$d added · %4$d dropped",
                comment: "Sheet match review summary: matched, guessed pairs to check, added sheets, dropped sheets"
            ),
            rows.filter { $0.partner != nil }.count, guessedRows.count, addedRevisionPages.count, removedSheets.count
        )
    }

    /// The evidence a basis is stored as.
    static func evidence(for basis: MatchBasis?) -> RevisionSheetRecord.Evidence {
        switch basis {
        case .exactLabel?, .normalisedLabel?: .label
        case .positionFallback?: .position
        case .manualOverride?: .manual
        case nil: .added
        }
    }

    /// Words for a basis, shown beside each pair.
    static func evidenceText(_ basis: MatchBasis?) -> String {
        switch basis {
        case .exactLabel?: NSLocalizedString("Same sheet number", comment: "Sheet match evidence: identical sheet numbers")
        case .normalisedLabel?: NSLocalizedString("Sheet number with a revision mark — check", comment: "Sheet match evidence: numbers agree after removing a revision suffix; a guess")
        case .positionFallback?: NSLocalizedString("Same place and paper size, no number — check", comment: "Sheet match evidence: paired by position; a guess")
        case .manualOverride?: NSLocalizedString("Paired by you", comment: "Sheet match evidence: a person chose the pair")
        case nil: NSLocalizedString("No match in the revision", comment: "Sheet match evidence: the revision has no such sheet")
        }
    }

    /// The pairings to store: one per revision page, with its evidence.
    func pairings(revisionID: String) -> [RevisionSheetRecord] {
        revisionLabels.indices.map { index in
            if let row = rows.first(where: { $0.partner == index }) {
                return RevisionSheetRecord(revisionId: revisionID, revisionPageIndex: index, pageId: row.pageID, evidence: Self.evidence(for: row.basis).rawValue)
            }
            return RevisionSheetRecord(revisionId: revisionID, revisionPageIndex: index, pageId: nil, evidence: RevisionSheetRecord.Evidence.added.rawValue)
        }
    }

    func accept(revisionID: String) { onAccept?(pairings(revisionID: revisionID)) }
    func cancel() { onCancel?() }
}

/// The sheet match review as a sheet over the window.
struct SheetMatchReviewView: View {
    @Bindable var model: SheetMatchReviewModel
    let revisionID: String

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(String(format: NSLocalizedString("Match the sheets of %@", comment: "Sheet match review title; the revision name"), model.revisionName))
                .zpdfText(.windowTitle, .textPrimary)
            Text(model.summaryText).zpdfText(.caption, .textSecondary)
            List {
                ForEach(model.rows) { row in
                    HStack(spacing: ZPDFSpacing.s) {
                        Text(row.setLabel).zpdfText(.body, .textPrimary).frame(width: 120, alignment: .leading)
                        Picker(selection: Binding(
                            get: { row.partner ?? -1 },
                            set: { model.setPartner($0 < 0 ? nil : $0, forSetIndex: row.setIndex) }
                        )) {
                            Text(NSLocalizedString("None", comment: "Sheet match review: no partner")).tag(-1)
                            ForEach(model.revisionLabels.indices, id: \.self) { index in
                                Text(model.revisionLabels[index]).tag(index)
                            }
                        } label: { EmptyView() }
                        .labelsHidden()
                        .frame(width: 160)
                        .accessibilityLabel(Text(String(
                            format: NSLocalizedString("Revision sheet for %@", comment: "Accessibility label: the revision sheet paired with a set sheet"),
                            row.setLabel
                        )))
                        Text(SheetMatchReviewModel.evidenceText(row.basis))
                            .zpdfText(.caption, row.basis?.isGuess == true ? .textPrimary : .textSecondary)
                    }
                }
                if !model.addedRevisionPages.isEmpty {
                    Section(NSLocalizedString("Added in the revision", comment: "Sheet match review: revision sheets with no partner")) {
                        ForEach(model.addedRevisionPages, id: \.self) { index in
                            Text(model.revisionLabels[index]).zpdfText(.body, .textSecondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer(minLength: 0)
                Button(NSLocalizedString("Cancel", comment: "Alert button")) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("Confirm Pairings", comment: "Sheet match review: store the pairings")) { model.accept(revisionID: revisionID) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ZPDFSpacing.l)
        .frame(minWidth: 620, minHeight: 420)
        .background(ZPDFColor.background)
    }
}
