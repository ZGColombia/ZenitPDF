import AppKit
import ZPDFAppCore

/// The round-2 markup rows of the application command table (r2-markup): Group ⌘G, Ungroup
/// ⇧⌘G, Edit Link…, Insert Image…, Edit ▸ Arrange (⌘] ⌘[ ⌥⌘] ⌥⌘[) and Edit ▸ Align.
@MainActor
enum MarkupRound2MenuSpecs {

    static func spec(for command: ZenitAppCommand) -> ZenitAppCommandSpec {
        switch command {
        case .groupMarkups:
            return ZenitAppCommandSpec(
                command, slot: .editGroup,
                title: NSLocalizedString("Group", comment: "Edit menu command: group the selected markups"),
                keyEquivalent: ZenitKeyEquivalent("g", [.command]),
                toolTip: NSLocalizedString("Clicking one member then selects, moves and restyles all of them.", comment: "Group tool tip"),
                rule: .markupSelection,
                action: withCore { core, _ in MarkupRound2Actions.group(core) }
            )
        case .ungroupMarkups:
            return ZenitAppCommandSpec(
                command, slot: .editGroup,
                title: NSLocalizedString("Ungroup", comment: "Edit menu command: take the selected markups out of their group"),
                keyEquivalent: ZenitKeyEquivalent("g", [.command, .shift]),
                // Only a selection that touches a group: Shift-Cmd-G on an ungrouped one did
                // nothing (R-065).
                rule: .groupedMarkupSelection,
                action: withCore { core, _ in MarkupRound2Actions.ungroup(core) }
            )
        case .editMarkupLink:
            return ZenitAppCommandSpec(
                command, slot: .editGroup,
                title: NSLocalizedString("Edit Link…", comment: "Edit menu command: set where the selected hyperlink markup leads"),
                toolTip: NSLocalizedString("⌘-click a link on the sheet to follow it.", comment: "Edit Link tool tip"),
                rule: .markupSelection,
                action: withCore { core, controller in MarkupRound2Actions.editLink(core, window: controller.window) }
            )
        case .insertImage:
            return ZenitAppCommandSpec(
                command, slot: .editGroup,
                title: NSLocalizedString("Insert Image…", comment: "Edit menu command: place an image file on the sheet"),
                toolTip: NSLocalizedString("You can also drag an image onto the sheet.", comment: "Insert Image tool tip"),
                rule: .drawing,
                action: .withDocument { controller, document in
                    MarkupRound2Actions.chooseAndInsertImage(document: document, window: controller.window)
                }
            )
        case .bringToFront, .bringForward, .sendBackward, .sendToBack:
            let arrangement: MarkupArrangement
            let chord: ZenitKeyEquivalent
            switch command {
            // ⌘[ and ⌘] are sheet history Back and Forward, taken by the canvas before the menu,
            // so Arrange lives on ⌥⌘: ⌥⌘] / ⌥⌘[ one step, and
            // with ⇧ — spelled "}" / "{" like Show Next Tab — all the way.
            case .bringToFront: arrangement = .bringToFront; chord = ZenitKeyEquivalent("}", [.command, .option])
            case .bringForward: arrangement = .bringForward; chord = ZenitKeyEquivalent("]", [.command, .option])
            case .sendBackward: arrangement = .sendBackward; chord = ZenitKeyEquivalent("[", [.command, .option])
            default: arrangement = .sendToBack; chord = ZenitKeyEquivalent("{", [.command, .option])
            }
            return ZenitAppCommandSpec(
                command, slot: .editArrange,
                title: arrangement.actionName,
                keyEquivalent: chord,
                rule: .markupSelection,
                action: withCore { core, _ in MarkupRound2Actions.arrange(arrangement, core: core) }
            )
        default:
            let alignment = Self.alignment(of: command) ?? .left
            return ZenitAppCommandSpec(
                command, slot: .editAlign,
                title: alignment.displayName,
                rule: .markupSelection,
                action: withCore { core, _ in MarkupRound2Actions.align(alignment, core: core) }
            )
        }
    }

    /// The align verb a command is, or `nil`.
    static func alignment(of command: ZenitAppCommand) -> MarkupAlignment? {
        switch command {
        case .alignLeft: .left
        case .alignCentres: .centreHorizontally
        case .alignRight: .right
        case .alignTop: .top
        case .alignMiddles: .middle
        case .alignBottom: .bottom
        case .distributeHorizontally: .distributeHorizontally
        case .distributeVertically: .distributeVertically
        case .makeSameWidth: .sameWidth
        case .makeSameHeight: .sameHeight
        default: nil
        }
    }

    private static func withCore(
        _ body: @escaping @MainActor (AppCoreEnvironment, ProjectWindowController) -> Void
    ) -> ZenitAppCommandAction {
        .withDocument { controller, document in
            guard let core = document.core else { return }
            body(core, controller)
        }
    }
}
