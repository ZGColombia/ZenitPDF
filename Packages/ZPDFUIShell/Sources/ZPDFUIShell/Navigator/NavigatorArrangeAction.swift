import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The page card's arrange items (NL-DOCS-07): move the page — or, when the page is part of a
/// multi-page selection, the whole selection as one block — within the set. Arranging is data
/// (ADR-0022): the issued PDF is never rewritten, every move is one undo step.
enum NavigatorArrangeAction: String, CaseIterable, Identifiable {
    case moveToTop
    case moveUp
    case moveDown
    case moveToBottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moveToTop: return NSLocalizedString("Move to Top", comment: "Navigator page menu: move the page to the start of the set")
        case .moveUp: return NSLocalizedString("Move Up", comment: "Navigator page menu: move the page one place earlier")
        case .moveDown: return NSLocalizedString("Move Down", comment: "Navigator page menu: move the page one place later")
        case .moveToBottom: return NSLocalizedString("Move to Bottom", comment: "Navigator page menu: move the page to the end of the set")
        }
    }

    var glyph: ZPDFGlyph {
        switch self {
        case .moveToTop, .moveUp: return .symbol(.chevronUp)
        case .moveDown, .moveToBottom: return .symbol(.chevronDown)
        }
    }

    /// "Extract Page…" / "Extract 3 Pages…".
    static func extractTitle(count: Int) -> String {
        count == 1
            ? NSLocalizedString("Extract Page…", comment: "Navigator page menu: write this page to a new PDF")
            : String(
                format: NSLocalizedString("Extract %lld Pages…", comment: "Navigator page menu: write the selected pages to a new PDF"),
                Int64(count)
            )
    }

    /// Where `block` — the card's page, or a selection that need not be contiguous — lands in
    /// `order`, or `nil` when the move would change nothing (the item is then disabled). The one
    /// arrange entry point (W-050: a second, contiguous-only one had no caller but its tests).
    ///
    /// V-045: the rule was "the target is not the block's first place", which is only true of a
    /// contiguous block. [A B C D] with A and C selected has its first page at 0, so Move to Top
    /// and Move Up read as no-ops and were disabled, though gathering the two gives [A C B D].
    /// The drag path already asked whether the order changes (U-044); now both paths do.
    func target<ID: Hashable>(moving block: [ID], in order: [ID]) -> Int? {
        guard let target = rawTarget(moving: block, in: order) else { return nil }
        return Self.changesOrder(order, moving: block, to: target) ? target : nil
    }

    /// The block's new first place among the sheets that stay — the place ``reordered(_:moving:to:)``
    /// inserts it at — before the no-op check, or `nil` for a block with no sheet in `order`.
    ///
    /// Move Up lands the gathered block one place before its first member; Move Down one place
    /// after its last, past the first sheet that follows it. For a contiguous block both are the
    /// old "one place" rules. W-044: Move Down used to count from the block's FIRST member, so on
    /// a scattered selection it moved the later members up the set: [A B C D E] with A and E
    /// gave [B A E C D], E from fifth to third.
    private func rawTarget<ID: Hashable>(moving block: [ID], in order: [ID]) -> Int? {
        let moving = Set(block)
        guard let first = order.firstIndex(where: moving.contains),
              let last = order.lastIndex(where: moving.contains) else { return nil }
        let staying = order.count - order.lazy.filter(moving.contains).count
        switch self {
        case .moveToTop:
            return 0
        case .moveUp:
            // Nothing selected sits before the first member, so its index counts the sheets that
            // stay ahead of it.
            return max(0, first - 1)
        case .moveDown:
            let stayingThroughLast = order[...last].lazy.filter { !moving.contains($0) }.count
            let hasFollower = order[(last + 1)...].contains { !moving.contains($0) }
            return min(staying, stayingThroughLast + (hasFollower ? 1 : 0))
        case .moveToBottom:
            return staying
        }
    }

    /// Whether moving `block` to start at `target` changes the order at all: the one no-op rule
    /// of the card menu and the card drag (U-044, V-045).
    static func changesOrder<ID: Hashable>(_ order: [ID], moving block: [ID], to target: Int) -> Bool {
        reordered(order, moving: block, to: target) != order
    }

    /// The pages a move from `pageID`'s card acts on: the whole selection when the page is in a
    /// selection of more than one, else the page alone; in set order.
    static func block(
        for pageID: PageDescriptor.ID,
        selection: [PageDescriptor.ID],
        pages: [PageDescriptor]
    ) -> [PageDescriptor.ID] {
        guard selection.count > 1, selection.contains(pageID) else { return [pageID] }
        let chosen = Set(selection)
        return pages.map(\.id).filter { chosen.contains($0) }
    }

    /// The set order after moving `block` to start at `target`. Pure, so the app's command
    /// translation and the tests agree on one definition.
    static func reordered<ID: Hashable>(
        _ order: [ID],
        moving block: [ID],
        to target: Int
    ) -> [ID] {
        let moving = Set(block)
        let kept = order.filter { !moving.contains($0) }
        let inOrder = order.filter { moving.contains($0) }
        let at = min(max(0, target), kept.count)
        return Array(kept[..<at]) + inOrder + Array(kept[at...])
    }
}

/// The arrange items, for the card's ⋯ menu and its context menu. Shown only when the app wired
/// ``ProjectShellEnvironment/onMovePages``.
struct NavigatorArrangeItems: View {

    let environment: ProjectShellEnvironment
    let pageID: PageDescriptor.ID

    var body: some View {
        if let move = environment.onMovePages {
            let pages = environment.document.pages
            let block = NavigatorArrangeAction.block(
                for: pageID, selection: environment.document.selectedPageIDs, pages: pages
            )
            let order = pages.map(\.id)
            Divider()
            if let extract = environment.onExtractPages {
                Button {
                    extract(block)
                } label: {
                    Label {
                        Text(NavigatorArrangeAction.extractTitle(count: block.count))
                    } icon: {
                        ZPDFGlyphView(.symbol(.export), size: ZPDFSpacing.Control.icon)
                    }
                }
            }
            ForEach(NavigatorArrangeAction.allCases) { action in
                let target = action.target(moving: block, in: order)
                Button {
                    if let target { move(block, target) }
                } label: {
                    Label {
                        Text(action.title)
                    } icon: {
                        ZPDFGlyphView(action.glyph, size: ZPDFSpacing.Control.icon)
                    }
                }
                .disabled(target == nil)
            }
        }
    }
}

// MARK: - Round 2: view, removal, revisions (NL-DOCS-07/11/12/16)

/// A sheet removed from the set, as the Navigator lists it.
public struct NavigatorRemovedSheet: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

/// The card items that change how a sheet is shown or whether it is in the set.
enum NavigatorViewAction: String, CaseIterable, Identifiable {
    case rotateRight, rotateLeft, cropView, clearCrop, removeFromSet

    var id: String { rawValue }

    func title(count: Int) -> String {
        switch self {
        case .rotateRight:
            NSLocalizedString("Rotate View Right", comment: "Navigator card menu: turn the sheet a quarter turn clockwise on screen")
        case .rotateLeft:
            NSLocalizedString("Rotate View Left", comment: "Navigator card menu: turn the sheet a quarter turn anticlockwise on screen")
        case .cropView:
            NSLocalizedString("Crop View…", comment: "Navigator card menu: draw the part of the sheet to show")
        case .clearCrop:
            NSLocalizedString("Show Whole Sheet", comment: "Navigator card menu: remove the sheet's view crop")
        case .removeFromSet:
            count > 1
                ? String(format: NSLocalizedString("Remove %d Sheets from Set", comment: "Navigator card menu: remove the selected sheets from the set; the count"), count)
                : NSLocalizedString("Remove from Set", comment: "Navigator card menu: remove this sheet from the set")
        }
    }

    var glyph: ZPDFGlyph {
        switch self {
        case .rotateRight: .symbol(.redo)
        case .rotateLeft: .symbol(.undo)
        case .cropView, .clearCrop: .symbol(.viewfinder)
        case .removeFromSet: .symbol(.remove)
        }
    }
}

/// Rotate, crop and remove items on a card's ⋯ menu, and the revision items.
struct NavigatorViewItems: View {

    let environment: ProjectShellEnvironment
    let pageID: PageDescriptor.ID

    var body: some View {
        let pages = environment.document.pages
        let block = NavigatorArrangeAction.block(
            for: pageID, selection: environment.document.selectedPageIDs, pages: pages
        )
        let page = pages.first { $0.id == pageID }
        if environment.onRotatePages != nil || environment.onSetPagesRemoved != nil || environment.onCropPage != nil {
            Divider()
        }
        if let rotate = environment.onRotatePages {
            item(.rotateRight, count: block.count) { rotate(block, 90) }
            item(.rotateLeft, count: block.count) { rotate(block, -90) }
        }
        if let crop = environment.onCropPage {
            item(.cropView, count: 1) { crop(pageID) }
        }
        if let clear = environment.onClearCrop, page?.viewCrop != nil {
            item(.clearCrop, count: 1) { clear([pageID]) }
        }
        if let remove = environment.onSetPagesRemoved {
            item(.removeFromSet, count: block.count) { remove(block, true) }
                .disabled(block.count >= pages.count)
        }
        if environment.hasPreviousRevision,
           environment.onCompareWithPreviousRevision != nil || environment.onCarryForward != nil {
            Divider()
            if let compare = environment.onCompareWithPreviousRevision {
                Button { compare(pageID) } label: {
                    Label {
                        Text(NavigatorRevisionAction.compareTitle)
                    } icon: {
                        ZPDFGlyphView(.symbol(.revisionCompare), size: ZPDFSpacing.Control.icon)
                    }
                }
            }
            if let carry = environment.onCarryForward {
                Button { carry(block) } label: {
                    Label {
                        Text(NavigatorRevisionAction.carryForwardTitle)
                    } icon: {
                        ZPDFGlyphView(.symbol(.revisionCompare), size: ZPDFSpacing.Control.icon)
                    }
                }
            }
        }
    }

    private func item(_ action: NavigatorViewAction, count: Int, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label {
                Text(action.title(count: count))
            } icon: {
                ZPDFGlyphView(action.glyph, size: ZPDFSpacing.Control.icon)
            }
        }
    }
}

enum NavigatorRevisionAction {
    static var compareTitle: String {
        NSLocalizedString("Compare with Previous Revision", comment: "Navigator card menu: compare this sheet with its match in the previous revision")
    }
    static var carryForwardTitle: String {
        NSLocalizedString("Carry Forward to Revision…", comment: "Navigator card menu: carry the takeoff on these sheets onto the newest revision")
    }
}

/// The removed sheets under the cards, each with Restore (NL-DOCS-07).
struct NavigatorRemovedSheetsSection: View {

    let environment: ProjectShellEnvironment
    @State private var isExpanded = false

    static func header(count: Int) -> String {
        String(format: NSLocalizedString("Removed from Set (%d)", comment: "Navigator: disclosure listing the sheets removed from the set; the count"), count)
    }

    var body: some View {
        if !environment.removedSheets.isEmpty, let restore = environment.onSetPagesRemoved {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(environment.removedSheets) { sheet in
                    HStack(spacing: ZPDFSpacing.s) {
                        Text(sheet.title)
                            .zpdfText(.control, .textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button(NSLocalizedString("Restore", comment: "Navigator: put a removed sheet back into the set")) {
                            restore([sheet.id], false)
                        }
                        .accessibilityLabel(Text(String(
                            format: NSLocalizedString("Restore %@ to the set", comment: "Accessibility label: restore a removed sheet; its name"),
                            sheet.title
                        )))
                    }
                }
            } label: {
                Text(Self.header(count: environment.removedSheets.count))
                    .zpdfText(.control, .textSecondary)
            }
            .padding(.horizontal, NavigatorStyle.cardPadding)
            .padding(.vertical, ZPDFSpacing.s)
        }
    }
}
