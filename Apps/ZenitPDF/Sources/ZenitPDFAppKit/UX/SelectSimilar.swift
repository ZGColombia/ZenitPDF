import AppKit
import ZPDFUIPresentation

/// Edit ▸ Select Same Subject / Select Same Kind / Select All in Document (NL-UX-07).
///
/// "Every door count on this sheet", "every cloud in the set" — one command instead of a
/// hundred ⇧-clicks. Hidden markups are never selected (Delete must not act on what nobody can
/// see): a markup on a hidden layer counts as hidden, and so does one the ledger filter's Hide
/// took off the sheet (`AppCanvasPresenter.filterHiddenMarkupIDs`, V-003's one rule — W-003).
enum SelectSimilar {

    /// What two markups must share.
    enum Criterion: Equatable {
        case subject
        case kind
        /// Everything, the document-wide Select All.
        case any
    }

    /// Where to look.
    enum Scope: Equatable {
        case page(UUID)
        case document
    }

    /// The markups matching the selection by `criterion` within `scope`, leaving out hidden
    /// markups and `filterHidden` (what the ledger filter's Hide removed from view). Pure, for
    /// tests.
    static func matches(
        in markups: [MarkupSummary],
        selected: Set<UUID>,
        criterion: Criterion,
        scope: Scope,
        filterHidden: Set<UUID>
    ) -> Set<UUID> {
        let chosen = markups.filter { selected.contains($0.id) }
        let subjects = Set(chosen.map(\.subject).filter { !$0.isEmpty })
        let kinds = Set(chosen.map { KindKey(kind: $0.kind, measurement: $0.measurementKind) })
        return Set(markups.filter { markup in
            guard !markup.hidden, !filterHidden.contains(markup.id) else { return false }
            if case let .page(pageID) = scope, markup.pageID != pageID { return false }
            switch criterion {
            case .subject: return !markup.subject.isEmpty && subjects.contains(markup.subject)
            case .kind: return kinds.contains(KindKey(kind: markup.kind, measurement: markup.measurementKind))
            case .any: return true
            }
        }.map(\.id))
    }

    /// A markup's kind for "same kind": the measurement tool for measurements (every Area),
    /// the markup kind otherwise (every cloud).
    struct KindKey: Hashable {
        let kind: MarkupKind
        let measurement: MeasurementKind?
    }
}

extension ProjectWindowController {

    /// Runs one Select Similar command on a document.
    func selectSimilar(_ criterion: SelectSimilar.Criterion, scope: SelectSimilar.Scope?, in document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        let resolvedScope: SelectSimilar.Scope
        if let scope {
            resolvedScope = scope
        } else if let page = core.document.currentPageID {
            resolvedScope = .page(page)
        } else {
            resolvedScope = .document
        }
        let ids = SelectSimilar.matches(
            in: core.snapshot.markups,
            selected: core.canvas.selectedMarkupIDs,
            criterion: criterion,
            scope: resolvedScope,
            filterHidden: core.canvas.filterHiddenMarkupIDs
        )
        core.canvas.select(markupIDs: ids, additive: false)
    }
}
