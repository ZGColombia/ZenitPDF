import Foundation
import ZPDFAppCore
import ZPDFUIPresentation

/// The one rule a whole-selection Move, nudge and Delete share (X-001, X-003, iteration 7).
///
/// The session moves and removes a parent area's cutouts **with** the parent
/// (`TakeoffSession.applyMove`, BH-008; `applyRemove`). A cutout is also its own shape on the
/// canvas, so a marquee or Select All catches it beside its parent, and a command for it on top
/// of the parent's acts on it twice: a move put the hole 2 × the offset away from where its
/// parent went, and a Delete threw `unknownMarkup` for the cutout the parent had already taken
/// and rolled the whole batch back. Cut has had the same rule since NL-MARKUP ("Parents only",
/// `MarkupClipboard.cutMarkups`).
///
/// A cutout selected **without** its parent stays: it is the thing the person asked to move or
/// delete.
enum CarriedCutouts {
    /// `ids` without every cutout whose parent is also in `ids`, order kept.
    static func roots(of ids: [UUID], parentOf: (UUID) -> UUID?) -> [UUID] {
        let selected = Set(ids)
        return ids.filter { id in
            guard let parent = parentOf(id) else { return true }
            return !selected.contains(parent)
        }
    }

    /// The parent of each cutout the snapshot holds, for ``roots(of:parentOf:)``.
    static func parents(in markups: [MarkupSummary]) -> [UUID: UUID] {
        var parents: [UUID: UUID] = [:]
        for markup in markups {
            if let parent = markup.parentID { parents[markup.id] = parent }
        }
        return parents
    }
}
