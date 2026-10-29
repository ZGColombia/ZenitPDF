import Foundation

/// The number-key slots of a tool set: number-key shortcuts for the first nine slots of the
/// active set.
///
/// # Why the order is computed here and not read off a field
///
/// A slot is a **position**, not a stored property. `ToolPresetSummary.shortcutDisplayString`
/// existed before this type and was stored, displayed and bound to nothing:
/// a label that promises a key which does not work is worse than no label. Deriving the slot
/// from the set's own order means the badge on the row and the key the canvas obeys cannot
/// disagree, because they are the same computation over the same list.
///
/// # Why the filter is deliberately ignored
///
/// The Tool Library's search field narrows what is on screen. The slots do **not** follow it.
/// If they did, `3` would mean a different tool every time the estimator typed a letter into
/// the filter, which is the opposite of what a muscle-memory shortcut is for. Slots are the
/// first nine tools of the set as the set is ordered, all day, filtered or not.
public enum ToolSlotOrder {

    /// How many slots a set exposes to the number row: `1` through `9`.
    ///
    /// Nine, not ten, because `0` is not the tenth slot in any keyboard convention worth
    /// following and `⌘0` already means Fit Width.
    public static let slotCount = 9

    /// Every preset of one set, in the order the panel lists them, ignoring any filter.
    ///
    /// The sort is the same one ``ToolLibraryPresenting/presets(in:)`` and the workflow
    /// package's editing model apply — category first, then position inside it — so the
    /// numbering matches what the person is looking at.
    ///
    /// A set lists its own presets. Favorites also lists every starred preset of any set, and
    /// Recent the presets `recent` names (the presenter's history, newest first), in that order
    /// (R-054): the panel lists through this, so the badge and the key keep agreeing there too.
    public static func ordered(
        _ presets: [ToolPresetSummary],
        in panel: ToolLibraryPanel,
        recent: [ToolPresetSummary.ID] = []
    ) -> [ToolPresetSummary] {
        let recentRank = panel == .recent
            ? Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            : [:]
        let listed = presets.filter {
            $0.panel == panel || (panel == .favorites && $0.isFavorite) || recentRank[$0.id] != nil
        }
        guard panel != .recent else {
            return listed.sorted { (recentRank[$0.id] ?? Int.max) < (recentRank[$1.id] ?? Int.max) }
        }
        return listed.sorted {
            $0.category == $1.category ? $0.sortIndex < $1.sortIndex : $0.category < $1.category
        }
    }

    /// The presets that occupy slots `1...9`, in slot order. Shorter than nine when the set is.
    public static func slots(
        _ presets: [ToolPresetSummary],
        in panel: ToolLibraryPanel,
        recent: [ToolPresetSummary.ID] = []
    ) -> [ToolPresetSummary] {
        Array(ordered(presets, in: panel, recent: recent).prefix(slotCount))
    }

    /// The preset a one-based slot number names, or `nil` when the set is shorter than that.
    ///
    /// A slot past the end of the set is **not** an error and must not fall through to some
    /// other tool: pressing `7` on a set of four tools does nothing at all.
    public static func preset(
        inSlot slot: Int,
        of presets: [ToolPresetSummary],
        in panel: ToolLibraryPanel,
        recent: [ToolPresetSummary.ID] = []
    ) -> ToolPresetSummary? {
        guard (1...slotCount).contains(slot) else { return nil }
        let occupants = slots(presets, in: panel, recent: recent)
        guard occupants.indices.contains(slot - 1) else { return nil }
        return occupants[slot - 1]
    }

    /// The one-based slot a preset occupies in its own set, or `nil` when it is past the ninth.
    public static func slotNumber(
        of id: ToolPresetSummary.ID,
        in presets: [ToolPresetSummary],
        panel: ToolLibraryPanel,
        recent: [ToolPresetSummary.ID] = []
    ) -> Int? {
        guard let index = slots(presets, in: panel, recent: recent).firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return index + 1
    }

    /// What a slot's key prints on a row, for example `"1"`, or `nil` for a number out of range.
    public static func displayString(slot: Int) -> String? {
        guard (1...slotCount).contains(slot) else { return nil }
        return String(slot)
    }

    /// What VoiceOver says for a slot, for example `"Shortcut 1"`.
    public static func accessibilityDescription(slot: Int) -> String? {
        guard let key = displayString(slot: slot) else { return nil }
        return String(
            format: NSLocalizedString(
                "Shortcut %@",
                comment: "Spoken form of a Tool Library number-key slot. %@ is the digit"
            ),
            key
        )
    }
}

extension ToolLibraryPresenting {

    /// The preset a one-based slot number names in the active set, or `nil`.
    ///
    /// The active set, not the armed preset's set: the number row is a way of reaching into
    /// the list that is on screen, and an estimator browsing `Project Tools` who presses `2`
    /// means the second tool of `Project Tools`.
    public func toolSlotPreset(_ slot: Int) -> ToolPresetSummary? {
        ToolSlotOrder.preset(inSlot: slot, of: presets, in: activePanel, recent: recentPresetIDs)
    }
}
