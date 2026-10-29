import Foundation
import ZPDFUIPresentation

extension ToolPresetSummary {

    /// The same preset under a new identity, with only the fields a copy legitimately changes
    /// overridden. Every other field travels untouched.
    ///
    /// `duplicate`, the import re-mint and the draft used to each spell out every field of
    /// `ToolPresetSummary` by hand, and CR-167 was the result: one of the three forgot `stamp`
    /// and duplicated stamps placed nothing. IM-035 moved the list here, but it was still a
    /// list: the round-2 `style` has a defaulted initialiser argument, so leaving it out
    /// compiled, and Duplicate gave a colour-only tool (V-059). The copy now starts from a
    /// full re-key of `self` and overrides only what a copy changes; `id` is a `let`, so the
    /// re-key is the one place that names the fields.
    ///
    /// The stamp template is re-minted with the new preset identity. `StampTemplate.id` is
    /// documented as "shared with the preset that owns it", placed stamps record it, and the
    /// batch producer matches on it — a copy that kept the original's template identity made a
    /// batch of the copy skip every page that already carried the original. Finding BH-847.
    func copy(
        id newID: UUID,
        name: String? = nil,
        panel: ToolLibraryPanel? = nil,
        sortIndex: Int? = nil,
        provenance: ToolPresetProvenance? = nil,
        isFavorite: Bool? = nil,
        isReadOnly: Bool? = nil,
        keepsShortcut: Bool = true
    ) -> ToolPresetSummary {
        var copy = reidentified(as: newID)
        if let name { copy.name = name }
        if let panel { copy.panel = panel }
        if let sortIndex { copy.sortIndex = sortIndex }
        if let provenance { copy.provenance = provenance }
        if let isFavorite { copy.isFavorite = isFavorite }
        if let isReadOnly { copy.isReadOnly = isReadOnly }
        if !keepsShortcut { copy.shortcutDisplayString = nil }
        copy.stamp = stamp.map { $0.reidentified(as: newID) }
        return copy
    }

    /// Every field of `self` under `newID`. The one place that names the fields, because `id`
    /// is a `let`. `Iter5ToolLibraryStyleTests.copyCarriesEveryStoredProperty` walks every
    /// stored property by reflection — the fixture must set each one away from its default,
    /// and the copy must carry each — so a field added later and forgotten here fails that
    /// test instead of silently resetting on Duplicate, Update Matching or the import re-mint.
    private func reidentified(as newID: UUID) -> ToolPresetSummary {
        ToolPresetSummary(
            id: newID,
            schemaVersion: schemaVersion,
            name: name,
            category: category,
            panel: panel,
            markupKind: markupKind,
            measurementKind: measurementKind,
            colorRGBA: colorRGBA,
            defaultSubject: defaultSubject,
            measurementDefaults: measurementDefaults,
            labelPattern: labelPattern,
            defaultStatus: defaultStatus,
            displayLengthUnit: displayLengthUnit,
            customDefaults: customDefaults,
            countSymbolName: countSymbolName,
            stamp: stamp,
            provenance: provenance,
            isFavorite: isFavorite,
            isReadOnly: isReadOnly,
            shortcutDisplayString: shortcutDisplayString,
            sortIndex: sortIndex,
            style: style
        )
    }
}

extension StampTemplate {

    /// The same template under the identity of the preset that now owns it.
    func reidentified(as newID: UUID) -> StampTemplate {
        StampTemplate(
            id: newID,
            revision: revision,
            widthPoints: widthPoints,
            heightPoints: heightPoints,
            rotationDegrees: rotationDegrees,
            artwork: artwork,
            fields: fields
        )
    }
}
