import AppKit
import Foundation
import Observation
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The tools the main toolbar arms. Length and Area are first-class items, never behind a
/// chevron.
///
/// This enum is **display identity only**: which chip fills cyan, which glyph, which
/// caption. What the canvas does is carried by ``ZenitToolSelection``/``ZenitToolMode``,
/// which every arming path sets in the same breath. Before that split, the toolbar's idea
/// of the armed tool reached the canvas exactly once — to arm the zoom marquee — and Text,
/// Callout and Shapes armed nothing at all.
public enum ZenitToolIdentifier: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    case select
    case pan
    case zoom
    case calibrate
    /// The first-class Length item.
    case length
    /// The first-class Area item.
    case area
    case text
    case callout
    case shapes
    case measure
    case count
    case cutout

    public var id: String { rawValue }

    /// The toolbar label and the VoiceOver name.
    public var displayName: String {
        switch self {
        case .select: return NSLocalizedString("Select", comment: "Toolbar tool name")
        case .pan: return NSLocalizedString("Pan", comment: "Toolbar tool name")
        case .zoom: return NSLocalizedString("Zoom", comment: "Toolbar tool name")
        case .calibrate: return NSLocalizedString("Calibrate", comment: "Toolbar tool name")
        case .length: return NSLocalizedString("Length", comment: "Toolbar tool name")
        case .area: return NSLocalizedString("Area", comment: "Toolbar tool name")
        case .text: return NSLocalizedString("Text", comment: "Toolbar tool name")
        case .callout: return NSLocalizedString("Callout", comment: "Toolbar tool name")
        case .shapes: return NSLocalizedString("Shapes", comment: "Toolbar tool name")
        case .measure: return NSLocalizedString("Measure", comment: "Toolbar tool name")
        case .count: return NSLocalizedString("Count", comment: "Toolbar tool name")
        case .cutout: return NSLocalizedString("Cutout", comment: "Toolbar tool name")
        }
    }

    /// The toolbar icon.
    public var glyph: ZPDFGlyph {
        switch self {
        case .select: return .symbol(.select)
        case .pan: return .symbol(.pan)
        case .zoom: return .symbol(.zoomTool) // the mockup draws a plain magnifier
        case .calibrate: return .measurement(.calibrate)
        case .length: return .measurement(.length)
        case .area: return .measurement(.area)
        case .text: return .symbol(.textTool)
        case .callout: return .symbol(.callout)
        case .shapes: return .symbol(.shapes)
        case .measure: return .symbol(.measure)
        case .count: return .measurement(.count)
        case .cutout: return .measurement(.cutout)
        }
    }

    /// Whether arming this tool puts the contextual measurement controls on screen.
    public var showsMeasurementControls: Bool {
        switch self {
        case .measure, .count, .cutout, .length, .area: return true
        case .select, .pan, .zoom, .calibrate, .text, .callout, .shapes: return false
        }
    }

    /// The mode this chip arms by default, given the palettes' last-used memory.
    ///
    /// The inverse of ``init(mode:)``. Together they are the only translation between chip
    /// identity and canvas behaviour, so the two can never be set independently.
    public func mode(
        lastUsedMeasurement: MeasurementKind,
        lastUsedShape: MarkupKind
    ) -> ZenitToolMode {
        switch self {
        case .select: return .select
        case .pan: return .pan
        case .zoom: return .zoom
        case .calibrate: return .calibrate
        case .length: return .measure(.length)
        case .area: return .measure(.area)
        case .text: return .markup(.text)
        case .callout: return .markup(.callout)
        case .shapes: return .markup(lastUsedShape)
        case .measure: return .measure(lastUsedMeasurement)
        case .count: return .measure(.count)
        case .cutout: return .measure(.polygonCutout)
        }
    }

    /// The chip that reads as armed for a mode.
    public init(mode: ZenitToolMode) {
        switch mode {
        case .select: self = .select
        case .pan: self = .pan
        case .zoom: self = .zoom
        case .calibrate: self = .calibrate
        case .measure(let kind):
            switch kind {
            case .length: self = .length
            case .area: self = .area
            case .count: self = .count
            default: self = kind.isCutout ? .cutout : .measure
            }
        case .markup(let kind):
            switch kind {
            case .text: self = .text
            case .callout: self = .callout
            default: self = .shapes
            }
        }
    }
}

/// State behind the main toolbar: which tool is armed, and what the three popup palettes
/// re-arm when their button is clicked rather than opened.
///
/// **One stored notion of the armed tool.** ``activeSelection`` is it; ``activeTool`` is
/// derived from it. Every arming path — a chip, a palette item, a menu command, a keyboard
/// shortcut — funnels through ``arm(_:)``, so it is structurally impossible for one of them
/// to move the toolbar's highlight without also telling the canvas what to draw. That was
/// the whole root cause of tools that lit a chip and armed nothing.
///
/// The last-used memory is the point of a palette button: a user measuring twenty walls
/// should press one button twenty times, not open a menu twenty times.
@MainActor
@Observable
public final class ZenitToolbarModel {

    /// Everything the canvas needs to know about the armed tool.
    public private(set) var activeSelection: ZenitToolSelection = .select
    /// What the Measure palette button arms on a plain click.
    public private(set) var lastUsedMeasurementKind: MeasurementKind
    /// What the Shapes palette button arms on a plain click.
    public private(set) var lastUsedShapeKind: MarkupKind = .rectangle
    /// The style Text, Callout and the Shapes draw with: the one the person chose for the tool
    /// in the Inspector, or the last one they gave a markup.
    ///
    /// Every arming path reads it, so a tool picked from a chip, a palette or a menu draws in
    /// it. It used to be `activeSelection.style`, which nothing but ``setStyle(_:)`` could
    /// change — and ``setStyle(_:)`` had no caller, so every new text box, callout and shape
    /// was the default blue at 1.5 pt whatever the person had just chosen.
    public private(set) var toolStyle: ToolStyleSelection = .zenitInk
    /// Each markup tool's own default and last-used style (nl-markup, NL-MARKUP-04). In memory
    /// until the app hands in one backed by the process defaults.
    public var styleDefaults = MarkupStyleDefaults()
    /// What the Count palette button arms on a plain click, when a preset has been used.
    public private(set) var lastUsedCountPresetID: UUID?
    /// The measurement tools the Measure palette offers, in palette order.
    public private(set) var measurementPalette: [MeasurementKind]
    /// The shapes the Shapes palette offers, in palette order.
    public private(set) var shapePalette: [MarkupKind] = ZenitToolMode.shapePalette
    /// The count presets the Count palette offers, in Tool Library order.
    ///
    /// **Live when a source is bound** (BH-054, IM-138). The palette used to be a stored copy
    /// taken once, when the shell environment was built, while the chevron menu listed presets
    /// live from the Tool Library. A preset created later appeared in the menu, failed the
    /// lookup in ``activateCountPreset(id:)`` and silently armed plain Count; a preset deleted
    /// later stayed here and kept being re-armed with a dead id. With
    /// ``bindCountPalette(to:)`` the palette is derived from the library on every read, so the
    /// menu, the button and the lookup can no longer disagree.
    public var countPalette: [ToolPresetSummary] {
        if let countPresetSource { return Self.countPresets(in: countPresetSource()) }
        return storedCountPalette
    }
    /// The live preset source, when one is bound.
    @ObservationIgnored private var countPresetSource: (@MainActor () -> [ToolPresetSummary])?
    /// The last list pushed through ``updateCountPalette(from:)``, used while no source is bound.
    private var storedCountPalette: [ToolPresetSummary] = []

    /// The armed tool, as chip identity. Derived — never stored.
    public var activeTool: ZenitToolIdentifier { ZenitToolIdentifier(mode: activeSelection.mode) }

    /// Which chip is under the pointer and which is held down: one of each for the whole bar
    /// (L-11). Cleared whenever the armed tool changes.
    @ObservationIgnored public let chipPointer = ZenitChipPointerState()

    /// Raised when the user picks a toolbar item that maps to a menu command.
    public var onCommand: (@MainActor (ZPDFCommandID) -> Void)?
    /// Raised whenever the armed tool changes, with everything the canvas needs.
    ///
    /// This is the seam. Nothing else arms anything.
    public var onSelectionChange: (@MainActor (ZenitToolSelection) -> Void)?
    /// Raised when a person chooses a tool — a chip, a palette item, a menu command or its key —
    /// **before** the toolbar arms it, and even when the choice is the tool already lit (X-018).
    ///
    /// ``onSelectionChange`` cannot say this. ``arm(_:)`` drops a selection equal to the armed
    /// one, so choosing the lit chip again reached nobody; and a style re-arm reaches it exactly
    /// as a tool change does. The armed Tool Library preset is put down on a choice and only on
    /// a choice, so the shell listens here. Not raised by a style re-arm (``setStyle(_:)``,
    /// ``rememberStyle(_:kinds:)``, ``setAsDefault(_:)``), a restore, or the Tool Library
    /// lighting the tool its preset armed (``showLibraryArm(_:preset:)``).
    public var onToolChosen: (@MainActor (ZenitToolSelection) -> Void)?
    /// Raised when a tool is armed, as chip identity. Convenience over
    /// ``onSelectionChange`` for consumers that only care which chip lit up.
    public var onToolChange: (@MainActor (ZenitToolIdentifier) -> Void)?
    /// Raised when a count preset is armed from the palette, so the Tool Library can supply
    /// its subject, colour and symbol.
    public var onCountPreset: (@MainActor (UUID) -> Void)?
    /// Raised whenever something worth persisting changed.
    public var onPersistableChange: (@MainActor () -> Void)?

    /// The measurement tools offered in the Measure palette by default.
    ///
    /// `Length` and `Area` are deliberately absent: they are
    /// first-class toolbar items that are never hidden behind a chevron, so the palette
    /// carries only the rarer tools.
    public static let defaultMeasurementPalette: [MeasurementKind] = [
        .dimension, .polylength, .perimeter,
        .rectangleArea, .ellipseArea,
        .volume, .wallArea,
        .radius, .diameter, .threePointCircle, .arcLength,
        .angle, .slope, .riseDrop,
        .trueSlopedLength, .trueSlopedArea,
        .temporaryMeasure
    ]

    /// The family a measurement tool belongs to, for the palette's dividers (IM-226): length,
    /// area, volume and wall, circle and arc, slope and angle, true-sloped, temporary.
    static func paletteFamily(of kind: MeasurementKind) -> Int {
        switch kind {
        case .length, .dimension, .polylength, .perimeter: return 0
        case .area, .rectangleArea, .ellipseArea, .polygonCutout, .ellipseCutout: return 1
        case .volume, .wallArea: return 2
        case .radius, .diameter, .threePointCircle, .arcLength: return 3
        case .angle, .slope, .riseDrop: return 4
        case .trueSlopedLength, .trueSlopedArea: return 5
        case .count: return 6
        case .temporaryMeasure: return 7
        }
    }

    /// The Measure palette cut into runs of one family each, in palette order, so the menu can
    /// put a divider between families without reordering anything (IM-226).
    public var measurementPaletteSections: [[MeasurementKind]] {
        var sections: [[MeasurementKind]] = []
        for kind in measurementPalette {
            if let last = sections.last?.last, Self.paletteFamily(of: last) == Self.paletteFamily(of: kind) {
                sections[sections.count - 1].append(kind)
            } else {
                sections.append([kind])
            }
        }
        return sections
    }

    /// Creates the model.
    ///
    /// - Parameters:
    ///   - lastUsedMeasurementKind: restored from the window's layout state.
    ///   - lastUsedCountPresetID: restored from the window's layout state.
    ///   - measurementPalette: override the palette contents.
    public init(
        lastUsedMeasurementKind: MeasurementKind = .length,
        lastUsedCountPresetID: UUID? = nil,
        measurementPalette: [MeasurementKind] = ZenitToolbarModel.defaultMeasurementPalette
    ) {
        // IM-031: the Measure button's memory only ever names a tool the palette offers. The
        // historical default, Length, is a first-class chip of its own; a Measure button that
        // re-armed it lit the Length chip instead of its own.
        self.lastUsedMeasurementKind = measurementPalette.contains(lastUsedMeasurementKind)
            ? lastUsedMeasurementKind
            : (measurementPalette.first ?? lastUsedMeasurementKind)
        self.lastUsedCountPresetID = lastUsedCountPresetID
        self.measurementPalette = measurementPalette
    }

    /// Restores the palettes' last-used memory from persisted layout state **without**
    /// announcing a change worth persisting.
    ///
    /// The window's layout state has carried `lastUsedMeasurementKind` and
    /// `lastUsedCountPresetID` since the store was written, and nothing ever read them back
    /// in: `ProjectWindowLayoutController.init` loaded the state, seeded the panel state from
    /// it and left the toolbar on its own defaults, after which the first
    /// `captureLayoutState()` wrote those defaults straight over the stored values. A person
    /// who spent the session in Volume relaunched into Length, and the memory of Volume was
    /// gone before they noticed (CR-100).
    ///
    /// Non-notifying by construction: the restore is not the user choosing a tool, so it must
    /// not raise ``onPersistableChange`` — that hook writes the layout store, and writing the
    /// store from inside the controller's initializer is how a restore turns into an
    /// overwrite. It does not arm anything either; the armed tool is a session decision, not
    /// a persisted one.
    ///
    /// - Parameters:
    ///   - measurementKind: the Measure palette's last used, or `nil` to keep the default.
    ///   - countPresetID: the Count palette's last used, or `nil` for none.
    public func restoreLastUsed(measurementKind: MeasurementKind?, countPresetID: UUID?) {
        // Clamped like ``activateMeasurement(_:)`` (IM-031): a stored `.length` — the layout
        // state's own default — must not turn the Measure button into a second Length button.
        if let measurementKind, measurementPalette.contains(measurementKind) {
            lastUsedMeasurementKind = measurementKind
        }
        lastUsedCountPresetID = countPresetID
    }

    /// Restores all three palettes' memory, the Shapes palette included (IM-141).
    ///
    /// Same non-notifying contract as ``restoreLastUsed(measurementKind:countPresetID:)``. A
    /// stored shape the Shapes palette does not offer (a Text or Callout from an older build,
    /// or a kind this build no longer draws) is ignored rather than restored.
    public func restoreLastUsed(
        measurementKind: MeasurementKind?,
        countPresetID: UUID?,
        shapeKind: MarkupKind?
    ) {
        restoreLastUsed(measurementKind: measurementKind, countPresetID: countPresetID)
        if let shapeKind, shapePalette.contains(shapeKind) {
            lastUsedShapeKind = shapeKind
        }
    }

    /// Whether the contextual measurement controls row belongs on screen.
    public var showsMeasurementControls: Bool { activeTool.showsMeasurementControls }

    /// The count preset the Count button re-arms, resolved against the current palette.
    public var lastUsedCountPreset: ToolPresetSummary? {
        guard let lastUsedCountPresetID else { return countPalette.first }
        return countPalette.first { $0.id == lastUsedCountPresetID } ?? countPalette.first
    }

    /// The count presets among `presets`, in Tool Library order. The one filter both the
    /// palette and the chevron menu use.
    public static func countPresets(in presets: [ToolPresetSummary]) -> [ToolPresetSummary] {
        presets
            .filter { $0.markupKind == .count }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Refreshes the Count palette from the Tool Library.
    ///
    /// A snapshot: it goes stale the moment the library changes. Prefer
    /// ``bindCountPalette(to:)``; while a source is bound, this only updates the fallback.
    public func updateCountPalette(from presets: [ToolPresetSummary]) {
        storedCountPalette = Self.countPresets(in: presets)
        forgetVanishedCountPreset()
    }

    /// Derives the Count palette from the Tool Library on every read (BH-054, IM-138).
    ///
    /// - Parameter source: returns the library's presets as they are now. Read from the
    ///   observable presenter, so a SwiftUI view reading ``countPalette`` re-renders when the
    ///   library changes.
    public func bindCountPalette(to source: @escaping @MainActor () -> [ToolPresetSummary]) {
        countPresetSource = source
        forgetVanishedCountPreset()
    }

    /// The remembered preset was deleted or renamed away. Forget it rather than leaving the
    /// button pointing at nothing.
    private func forgetVanishedCountPreset() {
        if let lastUsedCountPresetID, !countPalette.contains(where: { $0.id == lastUsedCountPresetID }) {
            self.lastUsedCountPresetID = nil
            onPersistableChange?()
        }
    }

    // MARK: - Arming

    /// The one setter. Everything else is a caller of this.
    public func arm(_ selection: ZenitToolSelection) {
        guard selection != activeSelection else { return }
        let previousTool = activeTool
        activeSelection = selection
        // L-11: no chip keeps a hover or press fill across a tool change — not the chip that
        // was armed, not the one just armed, and not a third one the pointer crossed.
        if activeTool != previousTool { chipPointer.settle() }
        onSelectionChange?(selection)
        if activeTool != previousTool { onToolChange?(activeTool) }
    }

    /// A person's choice of tool: announced through ``onToolChosen`` first, then armed (X-018).
    /// Every public arming method but the style, restore and Tool Library paths goes through
    /// here.
    private func choose(_ selection: ZenitToolSelection) {
        onToolChosen?(selection)
        arm(selection)
    }

    /// Lights the tool a Tool Library preset armed, naming the preset in the selection (X-018).
    ///
    /// The app core arms the presenters itself and calls this (through
    /// `ProjectShellEnvironment.libraryArmed(_:)`) so the chips say the same thing: the preset's
    /// measurement or markup tool in Draw, and Select when the preset arms no drawing tool —
    /// Apply, Place, or a kind nobody draws by hand — because the canvas collects nothing for a
    /// drawing chip then. It is not a choice, so it never puts the preset down. Because the
    /// selection carries the preset, the person choosing any tool afterwards — the lit one
    /// included — is a different selection, so the whole seam re-arms the presenters the
    /// preset's disarm put down.
    public func showLibraryArm(_ mode: ZenitToolMode, preset: ToolPresetSummary?) {
        var style = toolStyle
        switch mode {
        case .measure(let kind):
            if measurementPalette.contains(kind) { lastUsedMeasurementKind = kind }
        case .markup(let kind):
            if shapePalette.contains(kind) { lastUsedShapeKind = kind }
            adoptStyle(for: kind)
            // The preset's own look, which the core armed the markup tool with (NL-MARKUP-15).
            // The canvas re-arms the markup tool from this selection, so the tool style here
            // would replace the preset's look on every arm.
            style = preset?.placementStyle ?? toolStyle
        case .select, .pan, .zoom, .calibrate:
            break
        }
        arm(ZenitToolSelection(
            mode: mode,
            presetID: preset?.id,
            style: style,
            // The glyph a count preset chose, exactly as the Count palette arms it, so the
            // palette arming a preset and the core's echo of the same preset are one selection.
            countSymbolName: mode == .measure(.count) ? preset?.countSymbolName : nil
        ))
        onPersistableChange?()
    }

    /// Arms a tool by chip identity, resolving the palettes' last-used memory.
    public func selectTool(_ tool: ZenitToolIdentifier) {
        let mode = tool.mode(
            lastUsedMeasurement: lastUsedMeasurementKind,
            lastUsedShape: lastUsedShapeKind
        )
        if let kind = mode.markupKind { adoptStyle(for: kind) }
        choose(ZenitToolSelection(mode: mode, style: toolStyle))
    }

    /// Takes the style the kind's tool draws with (nl-markup, NL-MARKUP-04): its last-used or
    /// default style from ``styleDefaults``, else the current tool style.
    private func adoptStyle(for kind: MarkupKind) {
        guard ZenitToolMode.isDrawable(kind) else { return }
        var style = styleDefaults.style(for: kind, fallback: toolStyle)
        // A multiply blend belongs to the highlighter variant only (r2-markup).
        style.multiplyBlend = false
        guard style != toolStyle else { return }
        toolStyle = style
        onPersistableChange?()
    }

    /// Arms a measurement kind and, when the Measure palette offers it, remembers it as the
    /// palette's last used.
    ///
    /// IM-031: Length, Area, Count and Cutout have chips of their own, and remembering them
    /// here turned the Measure button into a second Length (or Count) button — clicking
    /// Measure lit a different chip. The palette's memory is "the rarer tool I used last",
    /// so only a kind the palette lists is written to it.
    public func activateMeasurement(_ kind: MeasurementKind) {
        if measurementPalette.contains(kind) { lastUsedMeasurementKind = kind }
        choose(ZenitToolSelection(
            mode: .measure(kind),
            style: toolStyle
        ))
        onPersistableChange?()
    }

    /// Re-arms whatever the Measure palette last used.
    public func activateLastUsedMeasurement() {
        activateMeasurement(lastUsedMeasurementKind)
    }

    /// Arms a markup kind and, when it is one of the Shapes palette's, remembers it.
    ///
    /// BH-824: the Tool Library forwards every drawable preset here, Text and Callout
    /// included. Remembering those made the Shapes button arm Text — lighting the Text chip —
    /// and read "Click to draw another Text". They are still armed; they are not remembered.
    public func activateShape(_ kind: MarkupKind) {
        if shapePalette.contains(kind) { lastUsedShapeKind = kind }
        adoptStyle(for: kind)
        choose(ZenitToolSelection(
            mode: .markup(kind),
            style: toolStyle
        ))
        onPersistableChange?()
    }

    /// The Pen tool's palette name: the freehand kind's tool (NL-MARKUP-06).
    public static let penTitle = NSLocalizedString("Pen", comment: "Markup tool: freehand pen")

    /// The annotation tools the Shapes palette offers below the shapes (r2-markup): Pen, Note
    /// and Hyperlink.
    public var annotationPalette: [MarkupKind] { ZenitToolMode.annotationPalette }

    /// The tool variants the Shapes palette offers (r2-markup): Highlighter, Clouded Callout.
    public var variantPalette: [MarkupToolVariant] { MarkupToolVariant.allCases }

    /// Arms a tool variant (r2-markup): the highlighter draws with its own remembered style —
    /// the wide, translucent multiply stroke until the person restyles one — and the clouded
    /// callout with the Cloud tool's.
    public func activateShapeVariant(_ variant: MarkupToolVariant) {
        let style: ToolStyleSelection
        switch variant {
        case .highlighter:
            style = styleDefaults.style(forVariant: variant, fallback: .highlighter)
        case .cloudedCallout:
            style = styleDefaults.style(for: .cloud, fallback: toolStyle)
        }
        choose(ZenitToolSelection(mode: .markup(variant.kind), style: style, variant: variant))
        onPersistableChange?()
    }

    /// Re-arms whatever the Shapes palette last used.
    public func activateLastUsedShape() {
        activateShape(lastUsedShapeKind)
    }

    /// Arms a count preset from the Count palette and remembers it.
    ///
    /// The preset's own measurement kind is **not** trusted to be a count: a preset saved
    /// without one used to leave whatever kind was armed before in place, so pressing Count
    /// continued the previous polygon. Count arms `.count`, always; the preset then supplies
    /// subject, colour and symbol on top.
    public func activateCountPreset(id: UUID) {
        // An id the palette does not hold is a preset that was deleted, renamed away, or
        // restored from another project's layout. Arming it anyway put a `presetID` with no
        // symbol behind it into the armed selection — the canvas had nothing to stamp — and
        // persisted the missing id as the Count button's memory, so the *next* launch restored
        // a button pointing at nothing all over again. `updateCountPalette(from:)` already
        // forgets a remembered id that has gone; this is the same rule at the other end, where
        // the id arrives (CR-106). The plain Count tool is armed instead: the tool the person
        // asked for, without the preset that is not there.
        guard let preset = countPalette.first(where: { $0.id == id }) else {
            if lastUsedCountPresetID == id { lastUsedCountPresetID = nil }
            activateMeasurement(.count)
            return
        }
        lastUsedCountPresetID = id
        choose(ZenitToolSelection(
            mode: .measure(.count),
            presetID: id,
            style: toolStyle,
            countSymbolName: preset.countSymbolName
        ))
        onCountPreset?(id)
        onPersistableChange?()
    }

    /// Re-arms whatever the Count palette last used, or the plain Count tool when the
    /// Tool Library has no count presets.
    public func activateLastUsedCount() {
        if let preset = lastUsedCountPreset {
            activateCountPreset(id: preset.id)
        } else {
            activateMeasurement(.count)
        }
    }

    /// Sets the style the markup tools draw with, without changing which tool is armed.
    ///
    /// An armed markup tool is re-armed with the new style, so its next markup uses it — the
    /// canvas observes the selection. A measurement or navigation tool is left exactly as it
    /// is: re-arming it would end a boundary capture or reset a half-placed measurement, and
    /// the style is not theirs; the next markup tool armed picks the style up.
    public func setStyle(_ style: ToolStyleSelection) {
        // r2-markup: the highlighter's look is its own and never becomes every tool's.
        let isHighlighter = activeSelection.variant == .highlighter
        let changed = !isHighlighter && style != toolStyle
        if !isHighlighter { toolStyle = style }
        // nl-markup: the armed kind remembers the style it was given.
        if let variant = activeSelection.variant, variant == .highlighter {
            // The highlighter keeps its own memory, apart from the pen's (r2-markup).
            styleDefaults.remember(style, forVariant: variant)
        } else if let kind = activeSelection.mode.markupKind, ZenitToolMode.isDrawable(kind) {
            styleDefaults.remember(style, for: kind)
        }
        if case .markup = activeSelection.mode, activeSelection.style != style {
            var selection = activeSelection
            selection.style = style
            arm(selection)
        }
        if changed { onPersistableChange?() }
    }

    /// Folds a style edit the person just made to a markup into the tool style, so the next
    /// markup they draw looks like the last one they styled ("last used").
    ///
    /// Only the fields a tool carries are taken — stroke, fill, width and text size. A fill
    /// that was the old stroke's tint follows a new stroke, so recolouring a blue shape red does
    /// not leave the next shape red with a blue interior.
    public func rememberStyle(_ edit: MarkupStyleEdit, kinds: Set<MarkupKind> = []) {
        setStyle(Self.style(toolStyle, applying: edit))
        // nl-markup: and each restyled kind remembers it for its own tool (NL-MARKUP-04).
        for kind in kinds where ZenitToolMode.isDrawable(kind) {
            let base = styleDefaults.style(for: kind, fallback: toolStyle)
            styleDefaults.remember(Self.style(base, applying: edit), for: kind)
        }
    }

    /// *Set as Default for ⟨kind⟩* (nl-markup, NL-MARKUP-04): the markup's whole look becomes
    /// what its kind's tool draws, now and after a restart.
    public func setAsDefault(_ markup: MarkupSummary) {
        guard ZenitToolMode.isDrawable(markup.kind) else { return }
        let style = ToolStyleSelection(markup: markup)
        styleDefaults.setDefault(style, for: markup.kind)
        if activeSelection.mode.markupKind == markup.kind { setStyle(style) }
    }

    /// ``rememberStyle(_:)``'s rule, value-only so it is testable without a toolbar.
    public static func style(_ base: ToolStyleSelection, applying edit: MarkupStyleEdit) -> ToolStyleSelection {
        var style = base
        if let colour = edit.color, colour.alpha > 0 {
            let opaque = ColorRGBA(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
            // The design system's one "same colour" rule (R-090).
            if let fill = style.fill, ZPDFColourMath.sameHue(fill, style.stroke) {
                style.fill = ColorRGBA(red: opaque.red, green: opaque.green, blue: opaque.blue, alpha: fill.alpha)
            }
            style.stroke = opaque
        }
        if let fill = edit.fill {
            style.fill = fill
        } else if edit.removesFill {
            style.fill = nil
        }
        if let width = edit.lineWidth, width.isFinite, width > 0 { style.lineWidth = width }
        if let size = edit.fontSize, size.isFinite, size > 0 { style.fontSize = size }
        // nl-markup: the rest of the look a tool now carries (NL-MARKUP-04).
        if let lineStyle = edit.lineStyle { style.lineStyle = lineStyle }
        if let opacity = edit.opacity, opacity.isFinite { style.opacity = min(1, max(0, opacity)) }
        if let cap = edit.startCap { style.startCap = cap }
        if let cap = edit.endCap { style.endCap = cap }
        if let font = edit.fontName, !font.isEmpty { style.fontName = font }
        if let alignment = edit.textAlignment { style.textAlignment = alignment }
        // r2-markup (ADR-0029): text format and arc size travel with the tool; a rotation is a
        // property of one markup and never becomes a tool's.
        if let bold = edit.bold { style.bold = bold }
        if let italic = edit.italic { style.italic = italic }
        if let colour = edit.textColor {
            style.textColor = colour
        } else if edit.removesTextColor {
            style.textColor = nil
        }
        if let border = edit.boxBorder { style.boxBorder = border }
        if let arc = edit.cloudArcSize, arc.isFinite, arc > 0 {
            style.cloudArcSize = arc
        } else if edit.resetsCloudArcSize {
            style.cloudArcSize = nil
        }
        return style
    }

    /// Restores the tool style from persisted layout state **without** announcing a change
    /// worth persisting — the same non-notifying contract as ``restoreLastUsed(measurementKind:countPresetID:)``.
    /// Values a style could not have been saved with are refused rather than restored.
    public func restoreToolStyle(_ style: ToolStyleSelection?) {
        guard let style,
              style.lineWidth.isFinite, style.lineWidth > 0,
              style.fontSize.isFinite, style.fontSize > 0
        else { return }
        toolStyle = style
        if case .markup = activeSelection.mode { activeSelection.style = style }
    }

    /// Runs a plain toolbar command.
    public func run(_ command: ZPDFCommandID) {
        onCommand?(command)
    }

    /// The label the Measure button shows: the tool it will arm, not the word "Measure".
    public var measureButtonTitle: String {
        lastUsedMeasurementKind.displayName
    }

    /// The label the Count button shows.
    public var countButtonTitle: String {
        lastUsedCountPreset?.name ?? MeasurementKind.count.displayName
    }

    /// The label the Shapes button shows: the shape it will draw.
    public var shapeButtonTitle: String {
        lastUsedShapeKind.displayName
    }

    // MARK: - Author badge (2026-09-23 mockup, top bar right)

    /// Where the author badge reads the name new markups are signed with.
    ///
    /// The application installs `AuthorIdentity.current()` here (Settings ▸ General ▸ Author
    /// name, else the macOS account name), which lives in ZPDFAppCore and is out of this
    /// package's reach. Until it does, the badge shows the machine's own answer, which is the
    /// same value `AuthorIdentity` falls back to — never a literal name from source.
    @ObservationIgnored public var authorNameProvider: @MainActor () -> String = {
        ZenitToolbarModel.machineAuthorName
    } {
        didSet { refreshAuthorName() }
    }

    /// The name the author badge shows, as of the last ``refreshAuthorName()``.
    public private(set) var authorName: String = ZenitToolbarModel.machineAuthorName

    /// Re-reads ``authorNameProvider``. The badge calls this when it appears and whenever the
    /// user defaults change, so a rename in Settings reaches the top bar without a relaunch.
    public func refreshAuthorName() {
        let name = authorNameProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        if name != authorName { authorName = name }
    }

    /// Opens Settings, where the author name is changed: runs the application menu's own
    /// Settings item (the `⌘,` item), so the badge goes exactly where the menu goes and needs no
    /// hook of its own.
    ///
    /// - Parameter mainMenu: the menu to search; the application's main menu by default.
    /// - Returns: whether a Settings item was found and run.
    @discardableResult
    public func openAuthorSettings(in mainMenu: NSMenu? = NSApp?.mainMenu) -> Bool {
        guard let mainMenu, let (menu, index) = Self.settingsItem(in: mainMenu) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    /// The `⌘,` item anywhere in a menu tree, as its menu and index.
    static func settingsItem(in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.keyEquivalent == ",",
               item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command,
               item.isEnabled {
                return (menu, index)
            }
            if let submenu = item.submenu, let found = settingsItem(in: submenu) {
                return found
            }
        }
        return nil
    }

    /// The initials the badge draws for ``authorName``.
    public var authorInitials: String { Self.initials(for: authorName) }

    /// The macOS account's full name, or its short name when the full name is empty — the same
    /// fallback `AuthorIdentity.machineDefault` documents.
    public nonisolated static var machineAuthorName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    /// Up to two initials for a display name, uppercased: the first letter of the first and
    /// of the last word ("Sample Author" → "SA"), the first letter alone for a one-word name,
    /// and an empty string for a blank one (the badge then draws a person glyph instead).
    ///
    /// The one ``AuthorInitials`` rule (S-053), so the badge and the Inspector's avatar agree
    /// for the same person. Word-based rather than `PersonNameComponentsFormatter`'s
    /// abbreviation, whose output depends on the current locale's name order and so could not
    /// be pinned by a test.
    public nonisolated static func initials(for name: String) -> String {
        AuthorInitials.initials(for: name)
    }
}

/// The pointer's state over the tool chips, owned by the bar rather than by each chip (L-11).
///
/// Each chip used to keep its own `isHovering` and `isPressed`, cleared only by its own exit,
/// its own release, a change of its own armed state or the window losing key. An exit or a
/// release that never arrived — the pointer warped away, a sheet or a menu took it mid-press,
/// the band laid its chips out again under a resting pointer — left a raised fill on a chip
/// beside the truly armed one: two chips lit (LT3-06, L-11). With one owner for the bar, a chip
/// is hovered only while it is the last one the pointer entered, and pressed only while it is
/// the one held down, so at most one chip draws each transient fill.
@MainActor
@Observable
public final class ZenitChipPointerState {

    /// The chip the pointer last entered and has not left.
    public private(set) var hovered: UUID?
    /// The chip held down.
    public private(set) var pressed: UUID?

    public init() {}

    /// The pointer entered (`true`) or left (`false`) a chip.
    public func hover(_ chip: UUID, _ isInside: Bool) {
        if isInside {
            if hovered != chip { hovered = chip }
        } else if hovered == chip {
            hovered = nil
        }
    }

    /// A chip was pressed (`true`) or released (`false`).
    public func press(_ chip: UUID, _ isDown: Bool) {
        if isDown {
            if pressed != chip { pressed = chip }
            // The pointer is on the chip it presses.
            if hovered != chip { hovered = chip }
        } else if pressed == chip {
            pressed = nil
        }
    }

    /// Clears both: a tool change, a sheet or a menu taking the pointer, the window losing key.
    public func settle() {
        if hovered != nil { hovered = nil }
        if pressed != nil { pressed = nil }
    }
}
