import Foundation
import Observation
import ZPDFUIPresentation

/// The display precisions the Inspector's Precision popup offers:
/// metric decimal places and imperial fractions — the two arms of the contracts' `PrecisionMode`,
/// mirrored here because the shell deliberately depends on the presentation seam only.
///
/// Precision is **display formatting only**. Selecting one never touches a stored SI value;
/// `InspectorMeasurementModel` asserts that after every change.
public enum InspectorPrecision: Hashable, Identifiable, Sendable {

    /// Metric: a fixed number of decimal places.
    case decimalPlaces(Int)
    /// Imperial: round to the nearest fraction of the display unit.
    case imperialFraction(ImperialPrecision)

    /// The choices the popup lists, decimals first, per the mockup's `1/32"` example.
    public static let choices: [InspectorPrecision] =
        [0, 1, 2, 3, 4].map(InspectorPrecision.decimalPlaces)
            + ImperialPrecision.allCases.map(InspectorPrecision.imperialFraction)

    /// Stable identity for the picker.
    public var id: String {
        switch self {
        case let .decimalPlaces(places): return "decimals-\(places)"
        case let .imperialFraction(fraction): return "fraction-\(fraction.rawValue)"
        }
    }

    /// The compact form shown in the closed popup, for example `"0,00"` or `"1/32"`.
    ///
    /// The decimal mark is the locale's, the same one the values it governs are printed with:
    /// a Swedish ledger reads "5,04 m" and its precision popup used to read "0.00" (BH-803).
    public var abbreviation: String { abbreviation(locale: .current) }

    /// ``abbreviation`` in a given locale.
    public func abbreviation(locale: Locale) -> String {
        switch self {
        case let .decimalPlaces(places):
            guard places > 0 else { return "1" }
            let mark = locale.decimalSeparator ?? "."
            return "0" + mark + String(repeating: "0", count: places)
        case let .imperialFraction(fraction):
            return fraction.displayName
        }
    }

    /// Whether this is a metric decimal precision.
    public var isDecimal: Bool {
        if case .decimalPlaces = self { return true }
        return false
    }

    /// The precision actually in force for a session.
    ///
    /// BH-286: the popup mirrored one stored value for two independent settings. A metric
    /// session shows its decimals whatever fraction was last picked (the fraction does nothing
    /// to a metric number), and an imperial session shows the session's own fraction rather
    /// than the metric seed.
    public static func effective(
        active: InspectorPrecision,
        lengthUnit: LengthUnit,
        imperialPrecision: ImperialPrecision
    ) -> InspectorPrecision {
        if !lengthUnit.isMetric { return .imperialFraction(imperialPrecision) }
        return active.isDecimal ? active : .decimalPlaces(3)
    }

    /// The choices that mean something for a session: decimals for a metric length unit,
    /// fractions for an imperial one.
    public static func choices(forMetric isMetric: Bool) -> [InspectorPrecision] {
        choices.filter { $0.isDecimal == isMetric }
    }

    /// The spoken, localised name.
    public var displayName: String {
        switch self {
        case let .decimalPlaces(places):
            let format = NSLocalizedString(
                "%d decimal places",
                comment: "Inspector precision choice: metric decimal places"
            )
            return String(format: format, places)
        case let .imperialFraction(fraction):
            let format = NSLocalizedString(
                "Nearest %@\u{2033}",
                comment: "Inspector precision choice: imperial fraction of an inch"
            )
            return String(format: format, fraction.displayName)
        }
    }

    /// Looks a choice up by its picker identity.
    public static func choice(withID id: String) -> InspectorPrecision? {
        choices.first { $0.id == id }
    }
}

/// The Inspector's edit surface for the Measurement section's control rows.
///
/// The shell renders the rows and fires these hooks; the app tier services them through the
/// document command bus, exactly like `ProjectShellEnvironment.externalCommandHandler`. Unwired
/// hooks leave the rows rendered but inert, never crashing a half-assembled window.
@MainActor
@Observable
public final class InspectorEditing {

    /// The user committed a Subject edit for the given markups. The app applies it to the
    /// stored markups, which is what makes the ledger row and the canvas caption follow live —
    /// both render from the same presenter data.
    public var onEditSubject: (@MainActor (_ markupIDs: Set<UUID>, _ subject: String) -> Void)?

    /// The user committed new words for the Text or Callout markups given (NL-COLLAB-18) —
    /// what the box draws, not its Notes. The app applies it as one undoable step.
    public var onEditText: (@MainActor (_ markupIDs: Set<UUID>, _ text: String) -> Void)?

    /// The person asked to set a status with a note on the markups given (NL-COLLAB-03). The app
    /// asks for the status and the words, then applies both.
    public var onRequestStatusNote: (@MainActor (_ markupIDs: Set<UUID>) -> Void)?

    /// The user assigned the markups to a Scale Region, or to the page default for `nil`.
    public var onAssignScaleRegion: (@MainActor (_ markupIDs: Set<UUID>, _ regionID: UUID?) -> Void)?

    /// The user picked a metric decimal precision. Display formatting only, by contract; the
    /// imperial arm goes through `MeasurementToolPresenting.setImperialPrecision` directly.
    public var onSetDecimalPrecision: (@MainActor (_ places: Int) -> Void)?

    /// The metric precision the popup shows. Mirrors the app's display setting; the shell
    /// seeds it with the contracts' metric default (three decimals). Read through
    /// ``InspectorPrecision/effective(active:lengthUnit:imperialPrecision:)``, which answers the
    /// session's own fraction for an imperial length unit.
    public var activePrecision: InspectorPrecision = .decimalPlaces(3)

    /// The engine's refusal of the last Inspector style edit, shown under Appearance until
    /// dismissed or superseded (IM-117). `nil` when the last edit landed.
    public var lastStyleRefusal: String?

    /// The header card's Lock / Unlock: the app runs `DocumentCommand.setLocked`, one undo
    /// step, the same command Edit ▸ Lock uses. Unwired, the menu item is not offered.
    public var onSetLocked: (@MainActor (_ markupIDs: Set<UUID>, _ locked: Bool) -> Void)?

    /// The header card's Hide / Show: the app runs `DocumentCommand.setHidden`, one undo step.
    /// Unwired, the menu item is not offered.
    public var onSetHidden: (@MainActor (_ markupIDs: Set<UUID>, _ hidden: Bool) -> Void)?

    /// The Properties tab's Project Zone popup: the app runs `DocumentCommand.setMarkupZone`,
    /// one undo step; `nil` files the markups out of every zone. Unwired (Quick PDF previews),
    /// the popup is shown disabled with the reason (nl-ux).
    public var onSetZone: (@MainActor (_ markupIDs: Set<UUID>, _ zoneID: UUID?) -> Void)?

    /// r2-markup (NL-MARKUP-17): the Link row's "Edit…" — the app asks where the selected
    /// hyperlink leads. Unwired, the row shows the destination without the button.
    public var onEditLink: (@MainActor (_ markupID: UUID) -> Void)?
    /// r2-markup (NL-MARKUP-11): the Group row's Group / Ungroup. Unwired, the row is not shown.
    public var onGroup: (@MainActor (_ markupIDs: Set<UUID>) -> Void)?
    public var onUngroup: (@MainActor (_ markupIDs: Set<UUID>) -> Void)?

    /// r2-measure (NL-MEASURE-07): the parameter rows — depth, heights, slope — for the markups in
    /// ``parameterRowsSelection``. The app keeps them current; rows for another selection are
    /// not shown.
    public var parameterRows: [InspectorParameterRowModel] = []
    /// The selection ``parameterRows`` describe.
    public var parameterRowsSelection: Set<UUID> = []
    /// The last refused parameter edit, said under the rows. `nil` when the last edit landed.
    public var parameterRefusal: String?
    /// A parameter row was committed: the markups, the row's identity and the typed text.
    public var onEditParameter: (@MainActor (_ markupIDs: Set<UUID>, _ rowID: String, _ text: String) -> Void)?
    /// "Pick Fall Line…": the app takes two clicks on the canvas and sets the slope's direction.
    /// Unwired, the button is not shown.
    public var onPickFallLine: (@MainActor (_ markupIDs: Set<UUID>) -> Void)?
    /// r2-measure (NL-MEASURE-03): "Recalculate" on the stale-value notice — every value kept
    /// under an older scale version is brought current. Unwired, the notice has no button.
    public var onRecalculateStale: (@MainActor () -> Void)?
    /// r2-measure (NL-MEASURE-09): the Caption row for the markups in its `selection`, kept
    /// current by the app; `nil` hides the row.
    public var captionState: InspectorCaptionState?
    /// The Caption row's field choice: the fields the pill shows, in order (empty = headline).
    public var onSetCaptionFields: (@MainActor (_ markupIDs: Set<UUID>, _ fields: [MeasurementField]) -> Void)?
    /// The Caption row's Segment lengths switch.
    public var onSetSegmentLengths: (@MainActor (_ markupIDs: Set<UUID>, _ on: Bool) -> Void)?
    /// The Caption row's Reset Label Position.
    public var onResetLabelPosition: (@MainActor (_ markupIDs: Set<UUID>) -> Void)?

    public init() {}
}

/// The Measurement section's behaviour, separated from its SwiftUI so the whole grammar —
/// choices, current values, commits, and the display-only guarantee — is testable against
/// `MockPresenters` without a view tree.
@MainActor
public struct InspectorMeasurementModel {

    /// One popup choice: a stable identity and its visible name.
    public struct Choice: Hashable, Identifiable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The picker identity of the "no Scale Region, page default applies" choice.
    public static let pageDefaultChoiceID = "page-default"
    /// The picker identity shown while a multi-selection disagrees.
    public static let mixedChoiceID = "mixed"

    private let environment: ProjectShellEnvironment
    public let selection: InspectorSelectionSummary

    public init(environment: ProjectShellEnvironment, selection: InspectorSelectionSummary) {
        self.environment = environment
        self.selection = selection
    }

    private var editing: InspectorEditing { environment.inspectorEditing }
    private var selectedIDs: Set<UUID> { Set(selection.markups.map(\.id)) }

    // MARK: - The lock rule (W-039)

    /// Whether the section's controls — Scale Region, Subject and Repeat — can edit the
    /// selection: something is selected and nothing selected is locked
    /// (``InspectorSelectionSummary/includesLockedMarkup``, the rule every other Inspector
    /// editor already followed).
    ///
    /// W-039: these three stayed live on a locked selection. The engine refused every edit, the
    /// Repeat stepper kept showing the refused count and asked for the next one on the next
    /// click, and the Subject field kept the refused text and sent it again on every blur.
    public var canEdit: Bool { !selection.isEmpty && !selection.includesLockedMarkup }

    /// Why the controls are off, for their help; `nil` while they can edit.
    public var disabledReason: String? {
        guard !selection.isEmpty, selection.includesLockedMarkup else { return nil }
        return InspectorPanel.lockedMarkupReason
    }

    // MARK: - Scale Region

    /// The Scale Region choices for the selection's page: the page default first, then every
    /// region on that page in the document's priority order.
    public var scaleRegionChoices: [Choice] {
        var choices = [Choice(
            id: Self.pageDefaultChoiceID,
            name: NSLocalizedString("Page default", comment: "Scale region choice: no region")
        )]
        choices.append(contentsOf: offeredRegions.map {
            Choice(id: $0.id.uuidString, name: $0.name)
        })
        // A MIXED SELECTION NEEDS A CHOICE TO POINT AT.
        //
        // `currentScaleRegionChoiceID` answered `mixedChoiceID` for a selection that disagreed,
        // and that id was in no choice list — so the popup rendered with nothing selected at
        // all, reading as "no Scale Region" rather than as "these disagree" (CR-110). The
        // marker is offered last, only when it applies, so it can never be picked out of a
        // selection that agrees; `selectScaleRegion(choiceID:)` refuses it either way.
        if isScaleRegionMixed {
            choices.append(Choice(id: Self.mixedChoiceID, name: InspectorSelectionSummary.mixedPlaceholder))
        }
        return choices
    }

    /// Whether the selection disagrees about its Scale Region.
    ///
    /// Markups on two sheets that are each in a region named "Basement" are in two regions —
    /// a region is one sheet's — so a selection over several sheets that shares a region name
    /// reads as mixed rather than as one region the popup does not offer (W-041).
    public var isScaleRegionMixed: Bool {
        if selection.isMixed(\.scaleRegionName) { return true }
        return spansSeveralPages && (selection.common(\.scaleRegionName) ?? nil) != nil
    }

    /// Whether the selection lies on more than one sheet.
    private var spansSeveralPages: Bool { Set(selection.markups.map(\.pageID)).count > 1 }

    /// The regions the popup offers: the regions of the selection's one page, and none when the
    /// selection spans several sheets. `currentScaleRegionChoiceID` resolves against exactly
    /// this list.
    ///
    /// W-041: a selection over several sheets was offered every region in the document. A
    /// region belongs to one sheet's scale, and the engine refuses it for a markup on any other
    /// (`scaleBelongsToAnotherPage`), so with two sheets selected every region was refused, with
    /// a raw-UUID warning. Only "Page default" means something for every sheet at once.
    private var offeredRegions: [ScaleRegionSummary] {
        let pageIDs = Set(selection.markups.map(\.pageID))
        guard pageIDs.count == 1, let pageID = pageIDs.first else { return [] }
        return environment.document.scaleRegions(onPage: pageID)
    }

    /// Why the popup offers no region, for its help: the selection spans several sheets
    /// (W-041). `nil` otherwise.
    public var scaleRegionNote: String? {
        guard spansSeveralPages else { return nil }
        return NSLocalizedString(
            "Select markups on one sheet to assign a Scale Region.",
            comment: "Inspector Scale Region popup help when the selection spans several sheets"
        )
    }

    /// The current popup selection: the shared region's identity, the page default, or the
    /// mixed marker when the selection disagrees.
    ///
    /// Resolved against ``offeredRegions`` — the same page-scoped list the choices come from —
    /// and never against every region in the document. Matching by NAME across all pages
    /// returned the id of a region the popup was not offering whenever two sheets both had a
    /// "Basement", and a popup told to select an id it does not hold shows nothing selected
    /// (CR-110). Name is still how the presenter reports the assignment, so the lookup starts
    /// from a name; it just may not leave the page.
    public var currentScaleRegionChoiceID: String {
        guard !isScaleRegionMixed else { return Self.mixedChoiceID }
        guard let name = selection.common(\.scaleRegionName) ?? nil else {
            return Self.pageDefaultChoiceID
        }
        return offeredRegions.first { $0.name == name }?.id.uuidString
            ?? Self.pageDefaultChoiceID
    }

    /// Applies a Scale Region popup choice.
    public func selectScaleRegion(choiceID: String) {
        guard choiceID != Self.mixedChoiceID, canEdit else { return }
        guard choiceID != currentScaleRegionChoiceID else { return }
        let regionID = choiceID == Self.pageDefaultChoiceID ? nil : UUID(uuidString: choiceID)
        guard choiceID == Self.pageDefaultChoiceID || regionID != nil else { return }
        editing.onAssignScaleRegion?(selectedIDs, regionID)
    }

    // MARK: - Scale in force (U-043)

    /// What the Scale section's "Active scale" row shows.
    public struct ScaleInForce: Equatable, Sendable {
        /// The scale, for example "1:100", or "Not calibrated". Unused while ``isMixed``.
        public let text: String
        /// Whether the selected markups were measured with different scales.
        public let isMixed: Bool
    }

    /// The scale the selection was measured with — the row's claim, per `InspectorSection.scale`.
    ///
    /// The row used to read `canvas.activeScale`, which is the default scale of the page on
    /// screen and knows nothing about Scale Regions: markup measured in a 1:100 region
    /// "Basement" on a 1:50 page showed the region's name in the Measurement section and
    /// "Active scale 1:50" here (U-043). Each markup now resolves to its own region's scale,
    /// looked up by name on its own page (the rule ``currentScaleRegionChoiceID`` uses), or to
    /// its page's default scale when it has no region. A selection that disagrees is mixed; an
    /// empty selection shows the page on screen.
    public var scaleInForce: ScaleInForce {
        let notCalibrated = NSLocalizedString("Not calibrated", comment: "Scale value when no scale is set")
        let pageScale = environment.canvas.activeScale?.displayString ?? notCalibrated
        guard !selection.isEmpty else { return ScaleInForce(text: pageScale, isMixed: false) }
        let shownPage = environment.canvas.viewport.pageID
        var texts: [String] = []
        for markup in selection.markups {
            let text: String
            if let name = markup.scaleRegionName,
               let region = environment.document.scaleRegions(onPage: markup.pageID).first(where: { $0.name == name }) {
                text = region.scale.displayString
            } else if markup.pageID == shownPage {
                text = pageScale
            } else {
                // The presenters answer a page's default scale only for the page on screen, so a
                // markup elsewhere with no region is named for what governs it rather than given
                // another sheet's ratio.
                text = NSLocalizedString("Page default", comment: "Scale region choice: no region")
            }
            if !texts.contains(text) { texts.append(text) }
        }
        guard texts.count == 1, let only = texts.first else {
            return ScaleInForce(text: InspectorSelectionSummary.mixedPlaceholder, isMixed: true)
        }
        return ScaleInForce(text: only, isMixed: false)
    }

    // MARK: - Subject

    /// The text the Subject field opens with: the shared subject, or empty when mixed.
    public var subjectText: String {
        selection.common(\.subject) ?? ""
    }

    /// Subjects already in use on the page, for the combo's menu — an editable combo offers
    /// what exists and accepts what does not.
    public var subjectSuggestions: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for markup in environment.canvas.visibleMarkups {
            let subject = markup.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty, seen.insert(subject).inserted else { continue }
            ordered.append(subject)
        }
        return ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Commits a Subject edit. Empty and unchanged texts are inert — a stray Return never
    /// blanks twenty markups.
    public func commitSubject(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canEdit else { return }
        guard trimmed != selection.common(\.subject) else { return }
        editing.onEditSubject?(selectedIDs, trimmed)
    }

    // MARK: - Value rows

    /// One read-only value row per shared measurement field. Geometry-driven values are never
    /// editable here: the number is a consequence of the drawn geometry and the scale, and the
    /// derivation disclosure beneath this section says exactly how.
    ///
    /// The row carries no label of its own. W-048: it used to compute one ("Value" / "Total" /
    /// the field's name, with the BH-804 primary-field rule) that nothing drew — the Markup tab
    /// names a row with ``InspectorPanel/quantityLabel(for:)``, from ``id`` and ``isTotal``, and
    /// that is the one label rule.
    public struct ValueRow: Identifiable {
        public let id: MeasurementField
        public let text: String
        /// Whether ``text`` is the sum over several markups rather than one markup's value.
        public let isTotal: Bool
        /// "×6" when the one selected markup repeats, `nil` otherwise (W-040): its value is one
        /// instance's, and the ledger row multiplies it, so the multiplier is said beside it.
        public let repetition: String?

        public init(id: MeasurementField, text: String, isTotal: Bool = false, repetition: String? = nil) {
            self.id = id
            self.text = text
            self.isTotal = isTotal
            self.repetition = repetition
        }
    }

    public var valueRows: [ValueRow] {
        selection.sharedMeasurementFields.map { field in
            // IM-026: an additive field over several markups is summed, and says so — each
            // markup counted as many times as it repeats, as its ledger row counts it (W-040).
            if selection.isMultiple, let total = selection.measurementTotalText(field) {
                return ValueRow(id: field, text: total, isTotal: true)
            }
            let repeats = selection.single.map(InspectorSelectionSummary.repetitions) ?? 1
            return ValueRow(
                id: field,
                text: selection.measurementText(field),
                repetition: repeats > 1 && InspectorSelectionSummary.additiveFields.contains(field)
                    ? selection.single?.repetitionText
                    : nil
            )
        }
    }

    /// Whether any selected markup produces a quantity at all.
    ///
    /// BH-287: the Scale Region, Subject and Precision rows are needed for a selection of a
    /// length and an area even though the two share no field; the section used to collapse to
    /// "This selection produces no quantities." — untrue, and it hid the bulk assignment.
    public var hasAnyQuantities: Bool {
        selection.markups.contains { !$0.measurementFields.isEmpty }
    }

    // MARK: - Precision

    /// The precision in force for this session (BH-286).
    public var currentPrecision: InspectorPrecision {
        InspectorPrecision.effective(
            active: editing.activePrecision,
            lengthUnit: environment.measurement.lengthUnit,
            imperialPrecision: environment.measurement.imperialPrecision
        )
    }

    /// The choices that mean something for the session's length unit.
    public var offeredPrecisions: [InspectorPrecision] {
        InspectorPrecision.choices(forMetric: environment.measurement.lengthUnit.isMetric)
    }

    /// The current popup selection.
    public var currentPrecisionID: String {
        currentPrecision.id
    }

    /// Applies a Precision popup choice. **Display formatting only**, and structurally so:
    /// the two hooks carry a number of places or a fraction, never a quantity, so there is
    /// nothing a precision change could write into a stored SI value.
    ///
    /// BH-805: this used to "assert" the guarantee by comparing the selection's quantities
    /// before and after — but both hooks are serviced asynchronously, so the "after" snapshot
    /// was always the "before" one and the assert could never fail.
    ///
    /// BH-286: the metric arm updates the metric setting only; the imperial arm the imperial
    /// setting only. Picking a fraction no longer overwrites the metric precision the ledger's
    /// subtotals are rounded to.
    public func selectPrecision(choiceID: String) {
        guard let choice = InspectorPrecision.choice(withID: choiceID) else { return }
        switch choice {
        case let .decimalPlaces(places):
            editing.activePrecision = choice
            editing.onSetDecimalPrecision?(places)
        case let .imperialFraction(fraction):
            environment.measurement.setImperialPrecision(fraction)
        }
    }
}
