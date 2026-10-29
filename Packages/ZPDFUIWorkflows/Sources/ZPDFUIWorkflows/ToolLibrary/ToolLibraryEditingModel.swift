import Foundation
import Observation
import ZPDFUIPresentation

/// How the preset area is laid out.
public enum ToolPresetPresentationStyle: String, Hashable, Sendable, CaseIterable, Identifiable {

    /// A grid of swatch tiles, which reads fastest for colour-coded tools.
    case grid
    /// A dense list with names, categories and shortcuts, which reads fastest for long sets.
    case list

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the layout switch.
    public var displayName: String {
        switch self {
        case .grid: return NSLocalizedString("Grid", comment: "Tool Library layout")
        case .list: return NSLocalizedString("List", comment: "Tool Library layout")
        }
    }
}

/// The editable form of a tool preset, used by the edit sheet.
///
/// A draft is a plain value: opening the sheet copies the preset into one, and cancelling
/// throws the copy away. Nothing is written until the person presses Save.
public struct ToolPresetDraft: Hashable, Sendable, Identifiable {

    /// Identity of the preset being edited, or of the preset about to be created.
    public var id: UUID
    /// Whether this draft becomes a new preset.
    public var isNew: Bool
    /// The panel the preset belongs to.
    public var panel: ToolLibraryPanel
    /// The tool's name.
    public var name: String
    /// The category it groups under.
    public var category: String
    /// The markup family it places.
    public var markupKind: MarkupKind
    /// The measurement tool it activates, if any.
    public var measurementKind: MeasurementKind?
    /// The stroke colour.
    public var colorRGBA: ColorRGBA
    /// The default takeoff subject.
    public var defaultSubject: String
    /// The measurement parameters the tool carries: depth, wall height, slope magnitude and
    /// azimuth, the cutout and perimeter policies, the volume depth reference.
    public var measurementDefaults: ToolPresetMeasurementDefaults
    /// The ledger label a markup made with this tool starts with.
    public var labelPattern: String
    /// The review status a markup made with this tool starts in.
    public var defaultStatus: MarkupStatus
    /// Where the tool came from.
    public var provenance: ToolPresetProvenance
    /// The default display unit for lengths.
    public var displayLengthUnit: LengthUnit
    /// Default values for custom Quantity Ledger columns.
    public var customDefaults: [String: String]
    /// The Count symbol, if any.
    public var countSymbolName: String?
    /// The stamp this preset places, for a `.stamp` preset.
    public var stamp: StampTemplate?
    /// Whether the preset is starred.
    public var isFavorite: Bool
    /// Where it sits inside its category.
    public var sortIndex: Int
    /// The whole look the preset places (NL-MARKUP-15): captured from a markup, carried
    /// through an edit; `nil` keeps the colour-only behaviour.
    public var style: ToolStyleSelection? = nil
    /// Parameter fields whose typed text does not read as a number at all.
    ///
    /// The field used to turn unparseable text into "no value", so a typo silently deleted the
    /// saved depth. It now keeps the typed text, leaves the stored value alone, and records the
    /// field here; Save stays off until the text reads or is cleared (IM-036).
    public var unparsedFields: Set<ToolPresetParameterRule.Field> = []

    /// Creates a draft from scratch.
    public init(
        id: UUID = UUID(),
        isNew: Bool,
        panel: ToolLibraryPanel,
        name: String,
        category: String,
        markupKind: MarkupKind,
        measurementKind: MeasurementKind? = nil,
        colorRGBA: ColorRGBA,
        defaultSubject: String,
        measurementDefaults: ToolPresetMeasurementDefaults = .none,
        labelPattern: String = "",
        defaultStatus: MarkupStatus = .none,
        provenance: ToolPresetProvenance = ToolPresetProvenance(origin: .createdHere),
        displayLengthUnit: LengthUnit = .metre,
        customDefaults: [String: String] = [:],
        countSymbolName: String? = nil,
        stamp: StampTemplate? = nil,
        isFavorite: Bool = false,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.isNew = isNew
        self.panel = panel
        self.name = name
        self.category = category
        self.markupKind = markupKind
        self.measurementKind = measurementKind
        self.colorRGBA = colorRGBA
        self.defaultSubject = defaultSubject
        self.measurementDefaults = measurementDefaults
        self.labelPattern = labelPattern
        self.defaultStatus = defaultStatus
        self.provenance = provenance
        self.displayLengthUnit = displayLengthUnit
        self.customDefaults = customDefaults
        self.countSymbolName = countSymbolName
        self.stamp = stamp
        self.isFavorite = isFavorite
        self.sortIndex = sortIndex
    }

    /// Creates a draft that edits an existing preset.
    public init(editing preset: ToolPresetSummary) {
        self.init(
            id: preset.id,
            isNew: false,
            panel: preset.panel,
            name: preset.name,
            category: preset.category,
            markupKind: preset.markupKind,
            measurementKind: preset.measurementKind,
            colorRGBA: preset.colorRGBA,
            defaultSubject: preset.defaultSubject,
            measurementDefaults: preset.measurementDefaults,
            labelPattern: preset.labelPattern,
            defaultStatus: preset.defaultStatus,
            provenance: preset.provenance,
            displayLengthUnit: preset.displayLengthUnit,
            customDefaults: preset.customDefaults,
            countSymbolName: preset.countSymbolName,
            stamp: preset.stamp,
            isFavorite: preset.isFavorite,
            sortIndex: preset.sortIndex
        )
        style = preset.style
    }

    /// Creates a draft from a markup the person selected on the canvas.
    ///
    /// This is "save the thing I just drew as a tool": the style, the takeoff defaults **and
    /// the measurement parameters** come from the markup, the name starts as its subject, and
    /// the person can change any of it before saving.
    ///
    /// The parameters are the part that matters. Capturing the styling and leaving the depth,
    /// the wall height and the slope behind is precisely the mistake that makes a tool library
    /// feel useless — the estimator draws a 200 mm slab, saves it as a
    /// tool, and the tool turns out to be a colour. `MarkupSummary.measurementDefaults` carries
    /// them here, so a captured Volume is a Volume with its thickness.
    public init(
        from markup: MarkupSummary,
        panel: ToolLibraryPanel = .myTools,
        displayLengthUnit: LengthUnit = .metre
    ) {
        let fallbackName = markup.subject.isEmpty
            ? markup.kind.displayName
            : markup.subject
        let zone = markup.zone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            isNew: true,
            panel: panel,
            name: fallbackName,
            // A markup whose zone name is blank used to become a preset with a blank category
            // and a nameless section in the panel. Finding BH-846.
            category: zone.isEmpty
                ? NSLocalizedString("Uncategorised", comment: "Default Tool Library category")
                : zone,
            markupKind: markup.kind,
            measurementKind: markup.measurementKind,
            colorRGBA: markup.colorRGBA,
            defaultSubject: markup.subject,
            measurementDefaults: markup.measurementDefaults ?? .none,
            labelPattern: markup.label,
            defaultStatus: markup.status,
            // The project's display unit, not always metres, so an imperial project's presets
            // read in feet from the first keystroke (IM-232).
            displayLengthUnit: displayLengthUnit,
            customDefaults: [:],
            countSymbolName: markup.kind == .count ? "circle" : nil
        )
        // NL-MARKUP-15: "Add Selection to Tool Library" captures the whole look — a red dashed
        // 3 pt cloud with a 20 % fill places exactly that.
        if ZenitToolMode.isDrawable(markup.kind) { style = ToolStyleSelection(markup: markup) }
    }

    /// Whether the draft can be saved: it has a name, a category, and parameters the importer
    /// would accept back.
    ///
    /// The category check is new: Save used to be gated by the name alone, so clearing the
    /// Category field produced a section with a blank header in the panel. Finding BH-846. The
    /// parameter check is ``ToolPresetParameterRule``, the same rule the importer applies
    /// (IM-036).
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parameterIssues.isEmpty
    }

    /// Everything wrong with the measurement parameters, in field order. Shown under the
    /// fields by the editor; empty is the condition for Save.
    public var parameterIssues: [ToolPresetParameterRule.Issue] {
        let unparsed = ToolPresetParameterRule.Field.allCases
            .filter { unparsedFields.contains($0) }
            .map { ToolPresetParameterRule.Issue(field: $0, message: ToolPresetParameterRule.unparsedMessage) }
        let ruled = ToolPresetParameterRule.issues(in: measurementDefaults)
            .filter { !unparsedFields.contains($0.field) }
        return (unparsed + ruled).sorted {
            ToolPresetParameterRule.Field.allCases.firstIndex(of: $0.field)!
                < ToolPresetParameterRule.Field.allCases.firstIndex(of: $1.field)!
        }
    }

    /// The issue to show under one field, or `nil`.
    public func parameterIssue(for field: ToolPresetParameterRule.Field) -> ToolPresetParameterRule.Issue? {
        parameterIssues.first { $0.field == field }
    }

    /// The parameter fields the editor shows for the chosen tool (IM-157).
    public var displayedParameterFields: Set<ToolPresetParameterRule.Field> {
        ToolPresetParameterRule.displayedFields(for: measurementKind)
    }

    /// Changes the measurement tool and keeps the markup family in step with it.
    ///
    /// The sheet's Tool picker used to bind `measurementKind` alone, so a new Count tool kept
    /// the `.measurement` family it was created with and never reached the toolbar's Count
    /// palette, which filters on `markupKind == .count` — and a Count preset re-tooled to Area
    /// stayed in that palette. Finding BH-317. A stamp keeps its family whatever tool it names.
    public mutating func setMeasurementKind(_ kind: MeasurementKind?) {
        measurementKind = kind
        // Unreadable text in a field the new tool does not show would keep Save off with no
        // visible reason. The stored value under it was never touched, so dropping the flag
        // loses nothing the person can see.
        unparsedFields.formIntersection(displayedParameterFields)
        guard markupKind == .measurement || markupKind == .count else { return }
        markupKind = kind == .count ? .count : .measurement
    }

    /// Adds one custom column default. A blank name adds nothing and answers `false`.
    @discardableResult
    public mutating func addColumnDefault(key: String, value: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        customDefaults[trimmed] = value
        return true
    }

    /// Drops the preset's imported artwork.
    ///
    /// A stamp keeps its template — the fields are the stamp — and loses the picture. A Count
    /// preset loses the whole template: it existed only to carry the picture, and an empty
    /// 12 × 12 template left behind reads as a stamp to Batch Apply, which then places blank
    /// stamps on every page instead of refusing. Finding BH-318.
    public mutating func removeArtwork() {
        if markupKind == .stamp {
            stamp?.artwork = nil
            stamp?.revision += 1
        } else {
            stamp = nil
        }
    }

    /// Whether this preset places a stamp whose artwork will blur when magnified.
    public var placesRasterStamp: Bool { stamp?.artworkIsRaster ?? false }

    /// The editor's raster warning, or `nil` when there is nothing to warn about.
    ///
    /// A raster-sourced stamp is marked as such **in the editor**, because the user should know
    /// which of their stamps will blur. Derived from the
    /// artwork rather than typed in, so it cannot go stale against the artwork it describes.
    public var stampSharpnessWarning: String? { stamp?.rasterSharpnessWarning }

    /// Whether this preset's marks can carry a picture.
    ///
    /// A stamp, obviously. And a **Count**, because a count symbol rides exactly the pipeline a
    /// stamp's artwork rides — the renderer says so in its own words: *"a count mark with
    /// imported artwork is a small stamp with no fields on it"*. One compiler, one store, one
    /// renderer path, and "a count mark with a chosen symbol" is satisfied by
    /// a chosen picture as readily as by a chosen glyph.
    public var acceptsArtwork: Bool { markupKind == .stamp || measurementKind == .count }

    /// The stamp as it should be saved.
    ///
    /// A template survives on a preset that will actually draw it. Changing a preset's family
    /// to something that draws neither a stamp nor a count drops it rather than leaving an
    /// invisible one attached, so a preset cannot carry artwork it will never draw.
    var stampForSaving: StampTemplate? {
        guard acceptsArtwork else { return nil }
        // A count preset's template is its picture; without one there is nothing to save.
        if markupKind != .stamp, stamp?.artwork == nil { return nil }
        return stamp
    }

    /// Points the preset's artwork at a newly imported picture.
    ///
    /// A count preset that had no template gets one sized to the symbol box rather than to a
    /// stamp's default 160 × 60 — a count mark is a mark, not a title block — and it carries no
    /// fields, because a field on a count mark is text nobody asked for.
    ///
    /// **A stamp looks as drawn by default** (ADR-0011 §2.4, decided 2026-09-23). A
    /// one-colour seal's regions carry no colour of their own and draw in the stamp's colour,
    /// so adopting it sets that colour to the ink the seal was drawn in: a red seal imports
    /// red. Choosing another colour afterwards is the explicit recolour — it repaints every
    /// ink region and stroke, and white knockouts keep their own white. Artwork in several
    /// colours, raster artwork and a colour the importer could not state carry no
    /// ``StampArtworkDescriptor/sourceInk`` and leave the colour alone. A Count preset keeps its
    /// colour too: it is the takeoff's colour code, not the symbol's.
    public mutating func adoptArtwork(_ artwork: StampArtworkDescriptor) {
        if markupKind == .stamp, let ink = artwork.sourceInk {
            colorRGBA = ink
        }
        if var template = stamp {
            template.artwork = artwork
            template.revision += 1
            stamp = template
        } else {
            let isCount = markupKind != .stamp && measurementKind == .count
            stamp = StampTemplate(
                id: id,
                widthPoints: isCount ? Self.countArtworkBoxPoints : 160,
                heightPoints: isCount ? Self.countArtworkBoxPoints : 60,
                artwork: artwork,
                fields: []
            )
        }
    }

    /// The edge of the box a count mark's imported artwork is fitted into, in PDF points.
    ///
    /// The same twelve `ImportedArtworkScene` falls back to, so a count mark drawn from a
    /// picture and one drawn from a glyph are the same size on the sheet.
    public static let countArtworkBoxPoints: Double = 12

    /// The draft as a preset summary.
    public func makePreset(isReadOnly: Bool = false) -> ToolPresetSummary {
        ToolPresetSummary(
            id: id,
            schemaVersion: ToolSetDocument.currentSchemaVersion,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category.trimmingCharacters(in: .whitespacesAndNewlines),
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
            stamp: stampForSaving,
            provenance: provenance,
            isFavorite: isFavorite,
            isReadOnly: isReadOnly,
            sortIndex: sortIndex,
            style: style
        )
    }
}

/// One category of presets, in display order, as the panel shows it.
public struct ToolPresetGroup: Hashable, Sendable, Identifiable {
    /// The category name.
    public var category: String
    /// Its presets, in `sortIndex` order.
    public var presets: [ToolPresetSummary]
    /// Stable identity: the category name.
    public var id: String { category }
}

/// What the Tool Library's preset area shows for one panel and one filter (R-120, R-133).
public struct ToolPresetPanelContent: Hashable, Sendable {
    /// The visible presets, grouped by category in display order.
    public var groups: [ToolPresetGroup]
    /// How many presets the filter leaves on screen: the header's count.
    public var visibleCount: Int
    /// The number key that arms each preset, for the first nine of the **unfiltered** set
    /// (``ToolSlotOrder``), so a filter never renumbers a badge.
    public var slotNumbers: [ToolPresetSummary.ID: Int]

    /// The badge for one preset, or `nil` past the ninth slot.
    public func slotNumber(of id: ToolPresetSummary.ID) -> Int? { slotNumbers[id] }
}

/// A change the Tool Library made, handed to the host so it can be persisted.
public enum ToolLibraryChange: Hashable, Sendable {
    case added([ToolPresetSummary])
    case updated(ToolPresetSummary)
    case removed(ToolPresetSummary)
    case restored(ToolPresetSummary)
    case reordered([ToolPresetSummary])
}

/// One Tool Library edit with enough in it to be taken back (IM-154).
///
/// Every edit the model makes — a save, an import, a duplicate, a favourite, a delete — is
/// reported here as well as through ``ToolLibraryChange``, carrying the state before and after.
/// The host registers each step with the document's `UndoManager` and calls
/// ``ToolLibraryEditingModel/revert(_:)`` to apply it; the model then re-reports the inverse
/// through `onChange` so persistence follows.
public struct ToolLibraryUndoStep: Hashable, Sendable, Identifiable {

    /// What the step did.
    public enum Kind: Hashable, Sendable {
        /// Presets were added; undo removes them.
        case added([ToolPresetSummary])
        /// Presets were removed; undo puts them back.
        case removed([ToolPresetSummary])
        /// Presets changed in place; undo restores `before`.
        case updated(before: [ToolPresetSummary], after: [ToolPresetSummary])
        /// One import that both updated and added tools: undo removes every `after` preset and
        /// puts every `before` preset back (IM-233).
        case replaced(before: [ToolPresetSummary], after: [ToolPresetSummary])
    }

    /// Identity of the step.
    public let id: UUID
    /// What happened.
    public let kind: Kind
    /// A localized name for the Undo menu item, for example "Undo Import 5 Tools".
    public let actionName: String

    /// Creates a step.
    public init(id: UUID = UUID(), kind: Kind, actionName: String) {
        self.id = id
        self.kind = kind
        self.actionName = actionName
    }

    /// The step that takes this one back.
    public var inverse: ToolLibraryUndoStep {
        switch kind {
        case let .added(presets):
            return ToolLibraryUndoStep(kind: .removed(presets), actionName: actionName)
        case let .removed(presets):
            return ToolLibraryUndoStep(kind: .added(presets), actionName: actionName)
        case let .updated(before, after):
            return ToolLibraryUndoStep(kind: .updated(before: after, after: before), actionName: actionName)
        case let .replaced(before, after):
            return ToolLibraryUndoStep(kind: .replaced(before: after, after: before), actionName: actionName)
        }
    }
}

/// How a re-imported tool set meets the tools already in the library (IM-233).
public enum ToolSetImportStrategy: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// Every arriving tool is added; a colliding identity is re-minted. The default.
    case keepBoth
    /// An arriving tool whose identity is already in the library replaces that tool's settings
    /// in place — its favourite, position and set are kept — so a revised office tool set can
    /// be refreshed without a second copy of every tool.
    case updateMatching

    public var id: String { rawValue }

    /// A localized name for the review sheet's choice.
    public var displayName: String {
        switch self {
        case .keepBoth:
            return NSLocalizedString("Keep Both", comment: "Tool set re-import: add arriving tools beside the existing ones")
        case .updateMatching:
            return NSLocalizedString("Update Matching Tools", comment: "Tool set re-import: replace tools that are already in the library")
        }
    }
}

/// A delete that has happened on screen but can still be taken back.
///
/// Zenit does not ask "are you sure?" for a tool preset. It performs the delete, says what it
/// did, and leaves Undo sitting there. That is faster for the person who meant it and no worse
/// for the person who did not.
public struct PendingToolPresetDeletion: Hashable, Sendable, Identifiable {

    /// Identity of the affordance.
    public let id: UUID
    /// Every preset the delete removed, in their set's order: one for Remove, a whole imported
    /// set for Remove Imported Set (X-031). Never empty, and always one panel and category.
    public private(set) var presets: [ToolPresetSummary]
    /// Where the first one sat, so Undo puts it back in the same place.
    public var originalIndex: Int

    /// The preset that was removed — the first, for a set.
    public var preset: ToolPresetSummary { presets[0] }

    /// Creates a pending deletion of one preset.
    public init(id: UUID = UUID(), preset: ToolPresetSummary, originalIndex: Int) {
        self.init(id: id, presets: [preset], originalIndex: originalIndex)
    }

    /// Creates a pending deletion of several presets, removed as one step. `presets` must not
    /// be empty.
    public init(id: UUID = UUID(), presets: [ToolPresetSummary], originalIndex: Int) {
        precondition(!presets.isEmpty, "a pending deletion removes at least one preset")
        self.id = id
        self.presets = presets
        self.originalIndex = originalIndex
    }

    /// Whether this deletion removed any of `ids`.
    func removedAny(of ids: Set<ToolPresetSummary.ID>) -> Bool {
        presets.contains { ids.contains($0.id) }
    }

    /// A localized sentence for the Undo bar.
    public var message: String {
        if presets.count == 1 {
            return String(
                format: NSLocalizedString(
                    "Removed “%@” from your Tool Library.",
                    comment: "Undo bar message after a tool preset was deleted. %@ is the preset name"
                ),
                preset.name
            )
        }
        return String(
            format: NSLocalizedString(
                "Removed the imported set “%1$@” (%2$@) from your Tool Library.",
                comment: "Undo bar message after an imported tool set was removed. 1: the set's name, 2: a number of tools such as '5 tools'"
            ),
            preset.category,
            WorkflowPlurals.tools(presets.count)
        )
    }
}

/// One imported tool set Remove Imported Set can remove: a category of Imported Libraries that
/// no subscription owns (X-031).
public struct ToolLibraryImportedSet: Hashable, Sendable, Identifiable {
    /// The set's name — its category in Imported Libraries.
    public let category: String
    /// How many tools removing it takes out.
    public let toolCount: Int

    public var id: String { category }

    /// A localized menu title, for example "Office kit — 5 tools".
    public var menuTitle: String {
        String(
            format: NSLocalizedString(
                "%1$@ — %2$@",
                comment: "Tool Library: an imported set in the Remove Imported Set menu. 1: the set's name, 2: a number of tools such as '5 tools'"
            ),
            category,
            WorkflowPlurals.tools(toolCount)
        )
    }
}

/// The editing state the Tool Library needs on top of ``ToolLibraryPresenting``.
///
/// The presenter protocol covers what the core owns: which panel is open, which preset is armed,
/// reuse-tool, reordering. Creating, editing, duplicating, deleting and importing are edits to
/// the library itself, so they live here as a working copy plus a change stream the host
/// persists. The model never writes to disk on its own.
@MainActor
@Observable
public final class ToolLibraryEditingModel {

    /// The working copy of every preset, across all panels.
    public private(set) var presets: [ToolPresetSummary]
    /// How the preset area is laid out.
    public var presentationStyle: ToolPresetPresentationStyle = .grid
    /// The delete that can still be taken back, or `nil`.
    public private(set) var pendingDeletion: PendingToolPresetDeletion?
    /// The preset being edited, or `nil` when no sheet is open.
    public var draft: ToolPresetDraft?
    /// The import-safety review waiting for an answer, or `nil`.
    public private(set) var importReview: ToolSetImportReview?
    /// Categories the person has collapsed.
    public var collapsedCategories: Set<String> = []

    /// Runs whenever the library changes, so the host can persist it.
    public var onChange: (@MainActor (ToolLibraryChange) -> Void)?
    /// Runs after every edit with a step the host can register with its `UndoManager`
    /// (IM-154). Only edits — never the re-application of a step through ``revert(_:)``.
    public var onUndoableChange: (@MainActor (ToolLibraryUndoStep) -> Void)?
    /// Whether an import file is being read and validated off the main actor (IM-155).
    public private(set) var isReviewingImport = false
    // ToolLibraryPanelView drags ToolPresetDragPayload; ZenitCanvasScrollView decodes it
    // and resolves the preset in the library when it receives a drop.

    /// Runs when an import cannot even be described.
    public var onImportFailure: (@MainActor (ZPDFUserFacingError) -> Void)?

    /// Compiles a chosen PDF page or image into preset artwork and stores it in the project.
    ///
    /// `nil` when the host has installed nothing, and the preset editor then shows the Artwork
    /// row without a chooser rather than a button that does nothing. This package cannot own
    /// the import: the compiler lives below the UI seam and the store is the open project's.
    public var onImportArtwork: ArtworkImportHandler?

    private let validator: ToolSetImportValidator

    /// Creates the model over a starting set of presets.
    public init(
        presets: [ToolPresetSummary] = [],
        validator: ToolSetImportValidator = ToolSetImportValidator()
    ) {
        self.presets = presets
        self.validator = validator
    }

    // MARK: - Reading

    /// The presets in one panel, filtered and ordered the way the sidebar shows them.
    ///
    /// The match is `localizedStandardContains` — case- and diacritic-insensitive, the way
    /// Finder searches — instead of lowercasing three strings per preset per keystroke (IM-156).
    ///
    /// Favorites also lists every starred preset of any set, and Recent the presets named by
    /// `recent` (the presenter's newest-first history), newest first. Both used to list only
    /// presets whose own set was Favorites or Recent — none ever is Recent, and starring changed
    /// nothing a set filtered on — so both showed 0 tools (R-054).
    public func presets(
        in panel: ToolLibraryPanel,
        matching query: String = "",
        recent: [ToolPresetSummary.ID] = []
    ) -> [ToolPresetSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The set's membership and order are the number keys' own (`ToolSlotOrder`), so a badge
        // and the key it names come from one list; the filter only narrows what is shown.
        return ToolSlotOrder.ordered(presets, in: panel, recent: recent).filter {
            trimmed.isEmpty
                || $0.name.localizedStandardContains(trimmed)
                || $0.category.localizedStandardContains(trimmed)
                || $0.defaultSubject.localizedStandardContains(trimmed)
        }
    }

    /// The one section heading Recent is listed under: newest first, not by category.
    public static var recentSectionTitle: String {
        NSLocalizedString("Recently Used", comment: "Tool Library: the section heading of the Recent set")
    }

    /// The presets in one panel, filtered once and grouped by category in display order.
    ///
    /// The panel used to ask for `categories(in:)` and then `presets(in:)` twice per category,
    /// each a full filter and sort of the library: 81 passes over 2 000 presets in 40
    /// categories on every keystroke in the search field. This is one. IM-156.
    public func groupedPresets(
        in panel: ToolLibraryPanel,
        matching query: String = "",
        recent: [ToolPresetSummary.ID] = []
    ) -> [ToolPresetGroup] {
        let listed = presets(in: panel, matching: query, recent: recent)
        if panel == .recent {
            return listed.isEmpty ? [] : [ToolPresetGroup(category: Self.recentSectionTitle, presets: listed)]
        }
        var groups: [ToolPresetGroup] = []
        for preset in listed {
            if groups.last?.category == preset.category {
                groups[groups.count - 1].presets.append(preset)
            } else {
                groups.append(ToolPresetGroup(category: preset.category, presets: [preset]))
            }
        }
        return groups
    }

    /// Everything the preset area draws for one panel and one filter, worked out once per body
    /// (R-120, R-133).
    ///
    /// The panel used to ask ``ToolSlotOrder/slotNumber(of:in:panel:)`` once per tile, and every
    /// call filtered and sorted the whole library to find one badge: (tiles) × O(N log N) on each
    /// keystroke in the search field, about 2 000 full sorts for a 2 000-tool set. Its header count
    /// ran a second filter-and-sort of its own beside ``groupedPresets(in:matching:)``. Here the
    /// groups are built once, the count is read off them, and the slots are one sort of the
    /// unfiltered set turned into a lookup.
    public func panelContent(
        in panel: ToolLibraryPanel,
        matching query: String = "",
        recent: [ToolPresetSummary.ID] = []
    ) -> ToolPresetPanelContent {
        let groups = groupedPresets(in: panel, matching: query, recent: recent)
        var slotNumbers: [ToolPresetSummary.ID: Int] = [:]
        for (offset, preset) in ToolSlotOrder.slots(presets, in: panel, recent: recent).enumerated() {
            slotNumbers[preset.id] = offset + 1
        }
        return ToolPresetPanelContent(
            groups: groups,
            visibleCount: groups.reduce(0) { $0 + $1.presets.count },
            slotNumbers: slotNumbers
        )
    }

    /// The categories present in one panel, in display order.
    public func categories(in panel: ToolLibraryPanel, matching query: String = "") -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for preset in presets(in: panel, matching: query) where !seen.contains(preset.category) {
            seen.insert(preset.category)
            ordered.append(preset.category)
        }
        return ordered
    }

    /// Replaces the working copy, for example after the host reloaded the library.
    public func synchronize(with presets: [ToolPresetSummary]) {
        self.presets = presets
    }

    // MARK: - Editing

    /// Opens the edit sheet on an existing preset. Read-only presets cannot be edited.
    public func beginEditing(id: ToolPresetSummary.ID) {
        guard let preset = presets.first(where: { $0.id == id }), !preset.isReadOnly else { return }
        draft = ToolPresetDraft(editing: preset)
    }

    /// Opens the edit sheet on a new preset built from a markup the person selected.
    /// - Parameter displayLengthUnit: the project's display unit, so the parameter fields read
    ///   in it from the start (IM-232).
    public func beginCreating(
        from markup: MarkupSummary,
        in panel: ToolLibraryPanel = .myTools,
        displayLengthUnit: LengthUnit = .metre
    ) {
        draft = ToolPresetDraft(from: markup, panel: panel, displayLengthUnit: displayLengthUnit)
    }

    /// Opens the edit sheet on an empty preset.
    public func beginCreating(
        in panel: ToolLibraryPanel = .myTools,
        category: String? = nil,
        displayLengthUnit: LengthUnit = .metre
    ) {
        draft = ToolPresetDraft(
            isNew: true,
            panel: panel,
            name: "",
            category: category ?? NSLocalizedString("Uncategorised", comment: "Default Tool Library category"),
            markupKind: .measurement,
            measurementKind: .area,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            defaultSubject: "",
            displayLengthUnit: displayLengthUnit,
            sortIndex: presets.filter { $0.panel == panel }.count
        )
    }

    /// Saves the open draft.
    public func commitDraft() {
        guard let draft, draft.isValid else { return }
        var preset = draft.makePreset()
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            let before = presets[index]
            // The draft does not carry the stored shortcut text; an edit must not erase it.
            preset.shortcutDisplayString = before.shortcutDisplayString
            presets[index] = preset
            onChange?(.updated(preset))
            onUndoableChange?(ToolLibraryUndoStep(
                kind: .updated(before: [before], after: [preset]),
                actionName: NSLocalizedString("Edit Tool", comment: "Undo action name: a tool preset edit")
            ))
        } else {
            presets.append(preset)
            onChange?(.added([preset]))
            onUndoableChange?(ToolLibraryUndoStep(
                kind: .added([preset]),
                actionName: NSLocalizedString("New Tool", comment: "Undo action name: a tool preset creation")
            ))
        }
        self.draft = nil
    }

    /// Applies an undo step handed back by the host's `UndoManager`, and reports the
    /// resulting library changes through `onChange` so they are persisted like any edit.
    /// Nothing is reported through `onUndoableChange`; the host registers the inverse itself.
    public func revert(_ step: ToolLibraryUndoStep) {
        switch step.kind {
        case let .added(added):
            let ids = Set(added.map(\.id))
            let removed = presets.filter { ids.contains($0.id) }
            presets.removeAll { ids.contains($0.id) }
            if pendingDeletion?.removedAny(of: ids) == true {
                pendingDeletion = nil
            }
            for preset in removed {
                onChange?(.removed(preset))
            }
        case let .removed(removed):
            let existing = Set(presets.map(\.id))
            let restored = removed.filter { !existing.contains($0.id) }
            // The Undo bar and the document's Undo must not both be able to put one preset back.
            if pendingDeletion?.removedAny(of: Set(removed.map(\.id))) == true {
                pendingDeletion = nil
            }
            presets.append(contentsOf: restored)
            for preset in restored {
                renumber(panel: preset.panel, category: preset.category)
                onChange?(.restored(preset))
            }
        case let .updated(before, _):
            for preset in before {
                guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { continue }
                presets[index] = preset
                onChange?(.updated(preset))
            }
        case let .replaced(before, after):
            let restoring = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for preset in after {
                guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { continue }
                if let original = restoring[preset.id] {
                    presets[index] = original
                    onChange?(.updated(original))
                } else {
                    let removed = presets.remove(at: index)
                    onChange?(.removed(removed))
                }
            }
            let present = Set(presets.map(\.id))
            let missing = before.filter { !present.contains($0.id) }
            presets.append(contentsOf: missing)
            for preset in missing {
                renumber(panel: preset.panel, category: preset.category)
                onChange?(.restored(preset))
            }
        }
    }

    /// Throws the open draft away.
    public func cancelDraft() {
        draft = nil
    }

    /// Copies a preset, appending "copy" to its name and placing it right after the original.
    ///
    /// A copy of a read-only preset lands in My Tools, at the **end** of its category there.
    /// "Right after the original" has no meaning in a panel the original is not in; positioning
    /// the copy by the source panel's index used to drop it into the middle of an unrelated
    /// category order and shift every ⌥ slot after it. Finding BH-848.
    ///
    /// Every field travels through ``ToolPresetSummary/copy(id:name:panel:sortIndex:provenance:isFavorite:isReadOnly:keepsShortcut:)``
    /// (IM-035), which also gives the copy's stamp template its own identity (BH-847).
    @discardableResult
    public func duplicate(id: ToolPresetSummary.ID) -> ToolPresetSummary? {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return nil }
        let source = presets[index]
        let destination = source.panel.isEditable ? source.panel : .myTools
        let sortIndex = destination == source.panel
            ? source.sortIndex + 1
            : presets.filter { $0.panel == destination && $0.category == source.category }.count
        let copy = source.copy(
            id: UUID(),
            name: String(
                format: NSLocalizedString(
                    "%@ copy",
                    comment: "Name of a duplicated tool preset. %@ is the original name"
                ),
                source.name
            ),
            panel: destination,
            sortIndex: sortIndex,
            provenance: ToolPresetProvenance(origin: .duplicated, recordedAt: Date()),
            isFavorite: false,
            isReadOnly: false,
            keepsShortcut: false
        )
        // Make room for the copy in the sibling order before inserting it, so `renumber` has an
        // unambiguous sequence to compact and the copy lands directly after its original.
        for offset in presets.indices
        where presets[offset].panel == copy.panel
            && presets[offset].category == copy.category
            && presets[offset].sortIndex >= copy.sortIndex {
            presets[offset].sortIndex += 1
        }
        presets.insert(copy, at: destination == source.panel ? index + 1 : presets.count)
        renumber(panel: copy.panel, category: copy.category)
        let stored = presets.first { $0.id == copy.id } ?? copy
        onChange?(.added([copy]))
        onUndoableChange?(ToolLibraryUndoStep(
            kind: .added([stored]),
            actionName: NSLocalizedString("Duplicate Tool", comment: "Undo action name: a tool preset duplicate")
        ))
        return stored
    }

    /// Whether Remove is offered for a preset, and whether ``delete(id:)`` honours it.
    ///
    /// Every tool in an editable set, and a read-only tool in Imported Libraries that no
    /// subscription owns (``SubscribedToolSet``) — a set imported by hand or from a pack. A
    /// subscribed tool is not: the next refresh would put it straight back.
    ///
    /// X-031: Remove used to be disabled for every read-only tool, and a hand-imported set is
    /// read-only by design, so a set imported by mistake — or only to try it — sat in every
    /// project's Tool Library for good. Nothing else could remove it.
    public func canRemove(_ preset: ToolPresetSummary) -> Bool {
        guard preset.isReadOnly else { return true }
        return preset.panel == .importedLibraries && !SubscribedToolSet.owns(preset)
    }

    /// Removes a preset and leaves an Undo affordance behind. Does nothing for a preset
    /// ``canRemove(_:)`` refuses, so the menu's enabled state and this guard are one rule.
    public func delete(id: ToolPresetSummary.ID) {
        guard let index = presets.firstIndex(where: { $0.id == id }), canRemove(presets[index]) else { return }
        let removed = presets.remove(at: index)
        pendingDeletion = PendingToolPresetDeletion(preset: removed, originalIndex: index)
        onChange?(.removed(removed))
        onUndoableChange?(ToolLibraryUndoStep(
            kind: .removed([removed]),
            actionName: NSLocalizedString("Remove Tool", comment: "Undo action name: a tool preset delete")
        ))
    }

    /// The imported sets Remove Imported Set offers: each category of Imported Libraries with a
    /// tool ``canRemove(_:)`` allows, in the panel's order (X-031).
    public func removableImportedSets() -> [ToolLibraryImportedSet] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for preset in presets(in: .importedLibraries) where canRemove(preset) {
            if counts[preset.category] == nil { order.append(preset.category) }
            counts[preset.category, default: 0] += 1
        }
        return order.map { ToolLibraryImportedSet(category: $0, toolCount: counts[$0] ?? 0) }
    }

    /// Removes every tool of one imported set as one step — one Undo bar, one ⌘Z (X-031).
    ///
    /// Only the tools ``canRemove(_:)`` allows: a subscribed tool that happens to share the
    /// set's name stays.
    public func removeImportedSet(category: String) {
        let ordered = presets(in: .importedLibraries).filter { $0.category == category && canRemove($0) }
        guard !ordered.isEmpty else { return }
        let ids = Set(ordered.map(\.id))
        let firstIndex = presets.firstIndex { ids.contains($0.id) } ?? 0
        presets.removeAll { ids.contains($0.id) }
        pendingDeletion = PendingToolPresetDeletion(presets: ordered, originalIndex: firstIndex)
        for preset in ordered {
            onChange?(.removed(preset))
        }
        onUndoableChange?(ToolLibraryUndoStep(
            kind: .removed(ordered),
            actionName: NSLocalizedString("Remove Imported Set", comment: "Undo action name: an imported tool set removed from the Tool Library")
        ))
    }

    /// Puts the last deleted preset back exactly where it was.
    ///
    /// "Where it was" is a place in its own category, not an offset into the flat array. The
    /// old code inserted at the recorded array index, which any edit made between the delete
    /// and the Undo — another delete, an import, a duplicate — had already invalidated, and it
    /// never restored the sibling numbering, so an undeleted T3 came back sitting after T4 with
    /// the ⌥ slots to match. Finding CR-180.
    ///
    /// A removed imported set (X-031) comes back the same way, one preset at a time in its own
    /// order, so each re-opens the slot it held.
    public func undoDelete() {
        guard let pending = pendingDeletion else { return }
        let restoring = pending.presets.sorted { $0.sortIndex < $1.sortIndex }

        for (offset, restored) in restoring.enumerated() {
            // Re-open the slot the preset held in its category, then let `renumber` compact.
            for position in presets.indices
            where presets[position].panel == restored.panel
                && presets[position].category == restored.category
                && presets[position].sortIndex >= restored.sortIndex {
                presets[position].sortIndex += 1
            }
            let index = min(max(0, pending.originalIndex + offset), presets.count)
            presets.insert(restored, at: index)
        }
        // One set, one category: a pending deletion is one preset or one imported set.
        renumber(panel: pending.preset.panel, category: pending.preset.category)
        pendingDeletion = nil
        for restored in restoring {
            onChange?(.restored(presets.first { $0.id == restored.id } ?? restored))
        }
    }

    /// Drops the Undo affordance without restoring anything.
    public func clearPendingDeletion() {
        pendingDeletion = nil
    }

    /// Moves a preset to a new position within its own panel and category.
    public func move(id: ToolPresetSummary.ID, to destinationIndex: Int) {
        guard let current = presets.firstIndex(where: { $0.id == id }) else { return }
        let preset = presets[current]
        var siblings = presets(in: preset.panel).filter { $0.category == preset.category }
        guard let siblingIndex = siblings.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(destinationIndex, siblings.count - 1))
        guard clamped != siblingIndex else { return }
        let moved = siblings.remove(at: siblingIndex)
        siblings.insert(moved, at: clamped)
        applyOrder(siblings, panel: preset.panel, category: preset.category)
    }

    /// Moves a preset one step past its neighbour **as the person sees the list** — `visible` is
    /// the sibling order on screen, which under a search is a subset of the category.
    ///
    /// Moving down places the preset directly after the next visible sibling, moving up
    /// directly before the previous one, and every hidden sibling keeps its relative place.
    /// Finding BH-316: the filtered index used to be applied to the unfiltered category.
    public func move(id: ToolPresetSummary.ID, by delta: Int, among visible: [ToolPresetSummary.ID]) {
        guard delta != 0,
              let visibleIndex = visible.firstIndex(of: id),
              visible.indices.contains(visibleIndex + delta),
              let preset = presets.first(where: { $0.id == id })
        else { return }
        let neighbour = visible[visibleIndex + delta]
        var siblings = presets(in: preset.panel).filter { $0.category == preset.category }
        guard let from = siblings.firstIndex(where: { $0.id == id }) else { return }
        let moved = siblings.remove(at: from)
        guard let neighbourIndex = siblings.firstIndex(where: { $0.id == neighbour }) else { return }
        siblings.insert(moved, at: delta > 0 ? neighbourIndex + 1 : neighbourIndex)
        applyOrder(siblings, panel: preset.panel, category: preset.category)
    }

    /// Whether ``move(id:by:among:)`` would visibly reorder the list the person is looking at.
    ///
    /// A move rewrites the order of the preset's **own** set and category. It is offered only
    /// when the neighbour on screen belongs to that same set and category and the panel shown
    /// is one whose order is that order. In Recent, sorted by recency across every set, Move Up,
    /// Move Down and Option-arrow were enabled and either did nothing or silently rewrote the
    /// tool's own set and its 1–9 slots while the list looked unchanged; in Favorites a
    /// neighbour from another set with the same category name gave a silent no-op (S-083).
    ///
    /// - Parameters:
    ///   - visible: the sibling order on screen.
    ///   - viewing: the panel being shown, which may differ from the preset's own set.
    public func canMove(
        id: ToolPresetSummary.ID,
        by delta: Int,
        among visible: [ToolPresetSummary.ID],
        viewing: ToolLibraryPanel
    ) -> Bool {
        guard delta != 0, viewing.isEditable,
              let visibleIndex = visible.firstIndex(of: id),
              visible.indices.contains(visibleIndex + delta),
              let preset = presets.first(where: { $0.id == id }),
              preset.panel.isEditable,
              let neighbour = presets.first(where: { $0.id == visible[visibleIndex + delta] })
        else { return false }
        return neighbour.panel == preset.panel && neighbour.category == preset.category
    }

    private func applyOrder(_ siblings: [ToolPresetSummary], panel: ToolLibraryPanel, category: String) {
        for (order, sibling) in siblings.enumerated() {
            guard let index = presets.firstIndex(where: { $0.id == sibling.id }) else { continue }
            presets[index].sortIndex = order
        }
        onChange?(.reordered(presets(in: panel).filter { $0.category == category }))
    }

    /// Stars or unstars a preset in the working copy.
    public func toggleFavorite(id: ToolPresetSummary.ID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let before = presets[index]
        presets[index].isFavorite.toggle()
        onChange?(.updated(presets[index]))
        onUndoableChange?(ToolLibraryUndoStep(
            kind: .updated(before: [before], after: [presets[index]]),
            actionName: presets[index].isFavorite
                ? NSLocalizedString("Add to Favorites", comment: "Undo action name: star a tool preset")
                : NSLocalizedString("Remove from Favorites", comment: "Undo action name: unstar a tool preset")
        ))
    }

    // MARK: - Import and export

    /// Reads a candidate tool set and opens the import-safety review. Nothing is added yet.
    ///
    /// The identities already in the library are handed to the validator, so a file imported a
    /// second time is described as what it is — tools that collide with ones already here — and
    /// arrives with fresh identities rather than duplicates. Finding CR-172.
    public func beginImport(data: Data, fileName: String) {
        receive(validator.review(
            data: data,
            fileName: fileName,
            existingIdentifiers: Set(presets.map(\.id))
        ))
    }

    /// ``beginImport(data:fileName:)`` with the parse and the validation run off the main
    /// actor (IM-155). The validator is a `Sendable` value and reads nothing but its arguments,
    /// so an 8 MB file with two thousand presets no longer stalls the window while it is
    /// described. ``isReviewingImport`` is true for the duration; the review lands exactly as
    /// the synchronous path would have produced it.
    public func reviewImport(data: Data, fileName: String) async {
        let validator = self.validator
        let existing = Set(presets.map(\.id))
        isReviewingImport = true
        defer { isReviewingImport = false }
        let result = await Task.detached(priority: .userInitiated) {
            validator.review(data: data, fileName: fileName, existingIdentifiers: existing)
        }.value
        receive(result)
    }

    /// Reads a chosen tool set file and reviews it, both off the main actor (IM-155, R-134).
    ///
    /// The Tool Library's file importer used to read the whole file with `Data(contentsOf:)` on
    /// the main actor and only then hand it to ``reviewImport(data:fileName:)``, whose validator
    /// refuses anything over 8 MB — so an oversized file stalled the window and sat in memory
    /// before being refused. The size check and the bounded read
    /// (``ToolSetImportValidator/readCandidate(at:)``) now run in the detached review task, and
    /// the security-scoped access the importer granted is held until the read has finished.
    public func reviewImport(fileAt url: URL) async {
        let validator = self.validator
        let existing = Set(presets.map(\.id))
        isReviewingImport = true
        defer { isReviewingImport = false }
        let result = await Task.detached(priority: .userInitiated) {
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            switch validator.readCandidate(at: url) {
            case let .failure(error):
                return Result<ToolSetImportReview, ZPDFUserFacingError>.failure(error)
            case let .success(data):
                return validator.review(
                    data: data,
                    fileName: url.lastPathComponent,
                    existingIdentifiers: existing
                )
            }
        }.value
        receive(result)
    }

    private func receive(_ result: Result<ToolSetImportReview, ZPDFUserFacingError>) {
        switch result {
        case let .success(review):
            importReview = review
        case let .failure(error):
            importReview = nil
            onImportFailure?(error)
        }
    }

    /// Adds the reviewed tools. Refuses when the review said the set is not safe to import.
    ///
    /// Identities are re-minted here as well as in the validator. The review is a value the host
    /// may have built any way it likes — the preview path builds one straight from a document —
    /// and two presets sharing a `UUID` break `ForEach` identity so thoroughly that delete,
    /// favourite and edit all land on whichever of them SwiftUI happened to keep.
    public func confirmImport(strategy: ToolSetImportStrategy = .keepBoth) {
        guard let review = importReview, review.isSafeToImport else { return }
        if strategy == .updateMatching, !review.libraryMatches.isEmpty {
            confirmImportUpdatingMatches(review)
            return
        }
        var taken = Set(presets.map(\.id))
        // Which arriving preset an accepted picture belongs to, across the re-mint.
        var identityMap: [UUID: UUID] = [:]
        let arriving: [ToolPresetSummary] = review.presets.map { preset in
            guard taken.contains(preset.id) else {
                taken.insert(preset.id)
                identityMap[preset.id] = preset.id
                return preset
            }
            let fresh = Self.reidentified(preset)
            taken.insert(fresh.id)
            identityMap[preset.id] = fresh.id
            return fresh
        }
        presets.append(contentsOf: arriving)
        importReview = nil
        onChange?(.added(arriving))
        onUndoableChange?(ToolLibraryUndoStep(
            kind: .added(arriving),
            actionName: WorkflowPlurals.importTools(arriving.count)
        ))
        let pictures = review.embeddedImages
            .filter(\.isAccepted)
            .compactMap { image -> (UUID, ToolSetEmbeddedImageReview)? in
                guard let presetID = image.presetID, let target = identityMap[presetID] else { return nil }
                return (target, image)
            }
        guard !pictures.isEmpty, onImportArtwork != nil else { return }
        Task { @MainActor in
            await attachImportedPictures(pictures)
        }
    }

    /// ``confirmImport(strategy:)`` with ``ToolSetImportStrategy/updateMatching``: tools whose
    /// identity is already in the library update that tool in place, keeping its identity,
    /// favourite, position, set and read-only state; the rest are added. One undo step.
    private func confirmImportUpdatingMatches(_ review: ToolSetImportReview) {
        var before: [ToolPresetSummary] = []
        var after: [ToolPresetSummary] = []
        var added: [ToolPresetSummary] = []
        var identityMap: [UUID: UUID] = [:]
        var taken = Set(presets.map(\.id))
        for preset in review.presets {
            if let original = review.libraryMatches[preset.id],
               let index = presets.firstIndex(where: { $0.id == original }) {
                let existing = presets[index]
                var updated = preset.copy(
                    id: existing.id,
                    panel: existing.panel,
                    sortIndex: existing.sortIndex,
                    isFavorite: existing.isFavorite,
                    isReadOnly: existing.isReadOnly
                )
                // V-060: a file that says nothing about the look (written before tool sets
                // carried a style, or by a tool that never had one) keeps the library tool's
                // own style; it used to reset every matched markup tool to colour-only.
                if updated.style == nil { updated.style = existing.style }
                before.append(existing)
                after.append(updated)
                presets[index] = updated
                identityMap[preset.id] = existing.id
                onChange?(.updated(updated))
            } else {
                let arriving = taken.contains(preset.id) ? Self.reidentified(preset) : preset
                taken.insert(arriving.id)
                identityMap[preset.id] = arriving.id
                added.append(arriving)
            }
        }
        presets.append(contentsOf: added)
        importReview = nil
        if !added.isEmpty { onChange?(.added(added)) }
        onUndoableChange?(ToolLibraryUndoStep(
            kind: .replaced(before: before, after: after + added),
            actionName: WorkflowPlurals.importTools(review.presets.count)
        ))
        let pictures = review.embeddedImages
            .filter(\.isAccepted)
            .compactMap { image -> (UUID, ToolSetEmbeddedImageReview)? in
                guard let presetID = image.presetID, let target = identityMap[presetID] else { return nil }
                return (target, image)
            }
        guard !pictures.isEmpty, onImportArtwork != nil else { return }
        Task { @MainActor in
            await attachImportedPictures(pictures)
        }
    }

    /// Whether an accepted picture in a review can actually be kept: the host has installed an
    /// artwork importer, which is the only way a picture reaches the project's artwork store.
    /// The review sheet reads this so it never promises "Will be kept" where nothing can keep
    /// it. Finding BH-320.
    public var canKeepImportedPictures: Bool { onImportArtwork != nil }

    /// Compiles each accepted picture through the host's artwork importer and points its
    /// preset at the result.
    ///
    /// The review used to list an in-limit picture as "Will be kept" and ``confirmImport()``
    /// then appended `review.presets` alone; the base64 text was discarded and the tool arrived
    /// with no artwork. Finding BH-320. The bytes are decoded here — after the person said yes,
    /// never during the review — written to a private temporary file, and handed to the same
    /// importer the editor's Image… button uses, so every limit that importer enforces applies.
    /// A picture the importer refuses is reported through `onImportFailure` and the tool stays
    /// as it is.
    public func attachImportedPictures(_ pictures: [(UUID, ToolSetEmbeddedImageReview)]) async {
        guard let importer = onImportArtwork else { return }
        for (presetID, image) in pictures {
            guard let data = Data(base64Encoded: image.base64Data, options: .ignoreUnknownCharacters),
                  !data.isEmpty else {
                onImportFailure?(ZPDFUserFacingError(
                    kind: .toolSetPictureNotKept,
                    subject: image.fileName,
                    technicalDetail: "The picture's base64 text did not decode."
                ))
                continue
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zenit-toolset-images-\(UUID().uuidString)", isDirectory: true)
            let fileExtension = image.declaredFormat == "jpeg" ? "jpg" : "png"
            let url = directory.appendingPathComponent(
                Self.safeFileStem(image.fileName) + "." + fileExtension
            )
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                onImportFailure?(ZPDFUserFacingError(
                    kind: .toolSetPictureNotKept,
                    subject: image.fileName,
                    technicalDetail: "The picture could not be written for import: \(error)"
                ))
                continue
            }
            defer { try? FileManager.default.removeItem(at: directory) }
            switch await importer(.image(url: url)) {
            case let .imported(descriptor):
                adoptImportedArtwork(descriptor, into: presetID)
            case let .refused(reason):
                onImportFailure?(ZPDFUserFacingError(
                    kind: .toolSetPictureNotKept,
                    subject: image.fileName,
                    technicalDetail: reason
                ))
            case .inspected:
                break
            }
        }
    }

    private func adoptImportedArtwork(_ descriptor: StampArtworkDescriptor, into presetID: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == presetID }) else { return }
        var draft = ToolPresetDraft(editing: presets[index])
        guard draft.acceptsArtwork else { return }
        draft.adoptArtwork(descriptor)
        let updated = draft.makePreset(isReadOnly: presets[index].isReadOnly)
        presets[index] = updated
        onChange?(.updated(updated))
    }

    /// A file-system-safe stem for a temporary picture file: the declared name is untrusted.
    private static func safeFileStem(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let stem = String(name.unicodeScalars.filter(allowed.contains).prefix(40))
        return stem.isEmpty ? "picture" : stem
    }

    /// Closes the review without adding anything.
    public func cancelImport() {
        importReview = nil
    }

    /// Whether a panel has anything to export. The export writes every preset in the panel,
    /// unfiltered, so this ignores any search. Finding BH-849.
    public func canExport(panel: ToolLibraryPanel) -> Bool {
        presets.contains { $0.panel == panel }
    }

    /// Builds the document for an export of one panel.
    ///
    /// Stamp templates travel (BH-319). A preset's picture travels only when the host has
    /// installed ``artworkExporter`` and it can hand back the bytes as a PNG or JPEG; otherwise
    /// the file says what the picture was, the recipient's review reports it as not included,
    /// and ``presetsLeavingArtworkBehind(panel:)`` lets the exporting window say so too.
    public func exportDocument(
        panel: ToolLibraryPanel,
        name: String,
        author: String? = nil,
        exportedAt: Date = Date()
    ) -> ToolSetDocument {
        ToolSetDocument(
            name: name,
            author: author,
            exportedAt: exportedAt,
            exporting: presets(in: panel),
            embeddingArtwork: artworkExporter
        )
    }

    /// Hands back a preset picture's bytes for export, from the project's artwork store, or
    /// `nil` when it cannot travel in a tool set file (vector artwork, a missing store entry).
    /// Installed by the host; this package has no access to the store.
    public var artworkExporter: (@MainActor (StampArtworkDescriptor) -> ToolSetEmbeddedImageRecord?)?

    /// The names of the presets in `panel` whose picture will not be in an exported file.
    public func presetsLeavingArtworkBehind(panel: ToolLibraryPanel) -> [String] {
        presets(in: panel).compactMap { preset in
            guard let artwork = preset.stamp?.artwork else { return nil }
            return artworkExporter?(artwork) == nil ? preset.name : nil
        }
    }

    // MARK: - Private

    /// The same preset under a fresh identity.
    ///
    /// `ToolPresetSummary.id` is a `let`, which is right — an identity that can be reassigned in
    /// place is an identity nothing can rely on — so a re-mint rebuilds the value. Every field
    /// travels, including the artwork, so this cannot become the CR-167 defect a second time.
    static func reidentified(_ preset: ToolPresetSummary) -> ToolPresetSummary {
        preset.copy(id: UUID())
    }

    /// Compacts one category's `sortIndex` values to 0, 1, 2 … **in the order the sidebar shows
    /// them**, which is `sortIndex` order and not the order they happen to sit in the array.
    ///
    /// This used to renumber by position in the flat `presets` array. `move(id:to:)` rewrites
    /// `sortIndex` and never moves anything in that array, so the two disagreed the moment
    /// anybody reordered a category by hand — and the next `duplicate` or `undoDelete`, both of
    /// which end here, silently put the manual order back the way it was, taking the ⌥1–9 slots
    /// with it. Finding CR-168.
    ///
    /// The array position is kept as the tie-break so the result is deterministic when two
    /// siblings share a `sortIndex`, which is the state a freshly inserted duplicate is in for
    /// the length of one call.
    private func renumber(panel: ToolLibraryPanel, category: String) {
        let ordered = presets
            .enumerated()
            .filter { $0.element.panel == panel && $0.element.category == category }
            .sorted {
                $0.element.sortIndex == $1.element.sortIndex
                    ? $0.offset < $1.offset
                    : $0.element.sortIndex < $1.element.sortIndex
            }
        for (order, entry) in ordered.enumerated() {
            presets[entry.offset].sortIndex = order
        }
    }
}
