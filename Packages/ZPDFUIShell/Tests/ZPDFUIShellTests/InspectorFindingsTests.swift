import Foundation
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The Inspector defects from the code review: CR-99, CR-109, CR-110, CR-116, CR-117, CR-118.
///
/// Each control's rule is asserted on the value-level seam the view renders from, so the rule
/// is pinned where a view tree cannot reach — which is exactly where all six of these lived.
@MainActor
@Suite("Inspector review findings", .shellTierSerialised)
struct InspectorFindingsTests {

    private func sampleMarkup(_ index: Int = 0) -> MarkupSummary {
        let markups = ZenitSampleProject.shared.markups
        return markups[index % markups.count]
    }

    // MARK: - CR-99: the colour well on a mixed selection

    /// CR-99 — a mixed selection painted every markup transparent black.
    ///
    /// `value` is `nil` when the selected markups disagree, `draft` opens on the `.clear`
    /// placeholder, and the guard was `picked != value` — an opaque `ColorRGBA` compared
    /// against `nil`, which always passes. Expanding Appearance, clicking one markup and
    /// ⌘-clicking a second of another colour applied `.clear` to all of them in one bulk edit.
    /// Old output, against the code before the fix:
    ///
    /// ```
    /// ✘ Test "A mixed selection writes no colour at all" recorded an issue at
    ///   InspectorFindingsTests.swift:40:9: Expectation failed:
    ///   (InspectorColourControl.pickedColour(from: .clear, current: nil)
    ///   → ColorRGBA(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)) == nil
    /// ✘ Test "A mixed selection writes no colour at all" recorded an issue at
    ///   InspectorFindingsTests.swift:42:9: Expectation failed:
    ///   (InspectorColourControl.pickedColour(from: .red, current: nil)
    ///   → ColorRGBA(red: 1.0, green: 0.2588…, blue: 0.2705…, alpha: 1.0)) == nil
    /// ```
    ///
    /// The assertions now call `pickedColour(_:current:)`, the function the palette and the
    /// colour panel call; the SwiftUI-colour wrapper the old output names had no production
    /// caller and was removed (T-035).
    @Test("A mixed selection writes no colour at all")
    func aMixedSelectionWritesNoColour() {
        // The state the control is in for a mixed selection: no shared value, and the
        // transparent placeholder.
        #expect(InspectorColourControl.pickedColour(Self.transparent, current: nil) == nil)
        // BH-053 superseded the second half of this test: a *deliberate* opaque pick on a
        // mixed selection is written — giving a disagreeing selection one colour is what the
        // control is for — while the transparent placeholder never is.
        #expect(InspectorColourControl.pickedColour(Self.opaqueRed, current: nil) == Self.opaqueRed)
        #expect(InspectorColourControl.pickedColour(Self.opaqueBlack, current: nil) == Self.opaqueBlack)
    }

    @Test("A selection that agrees still writes the colour the reader picked")
    func anAgreeingSelectionStillWrites() {
        let current = sampleMarkup().colorRGBA
        let picked = InspectorColourControl.pickedColour(Self.opaqueRed, current: current)
        #expect(picked != nil)
        #expect(picked != current)

        // Picking the exact colour already in force is not an edit.
        #expect(InspectorColourControl.pickedColour(current, current: current) == nil)
    }

    private static let transparent = ColorRGBA(red: 0, green: 0, blue: 0, alpha: 0)
    private static let opaqueRed = ColorRGBA(red: 1, green: 0.2588, blue: 0.2706, alpha: 1)
    private static let opaqueBlack = ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1)

    /// The measurement behind CR-117: the round trip is NOT bit-exact.
    ///
    /// The finding called the phantom edit "suspected", conditional on the round trip losing
    /// precision. It does — a sample markup's own colour does not come back equal to itself —
    /// so `picked != value` alone can never tell a colour that came back through SwiftUI apart
    /// from a real pick. The pick rule compares by hue (`ZPDFColourMath.sameHue`), so the
    /// round-tripped colour is still no edit. That is asserted on `pickedColour(_:current:)`,
    /// the function the palette and the colour panel call; the seed-guard helper this test used
    /// to pin (`isUserEdit`) had no production caller since the colour well went, and was
    /// removed with its own test (T-035).
    @Test("The colour round trip loses precision, and the pick rule still reads it as no edit")
    func theColourRoundTripIsNotBitExact() {
        let current = sampleMarkup().colorRGBA
        let roundTripped = ColorRGBA(swiftUIColor: current.swiftUIColor)
        #expect(
            roundTripped != current,
            """
            If this ever starts passing, the round trip has become exact and CR-117's phantom \
            edit is no longer reachable through it. `pickedColour(_:current:)` still guards \
            both cases, and neither depends on the round trip: it never writes the transparent \
            placeholder on a mixed selection (`current` nil, CR-99), and it compares a pick \
            with the colour in force by hue (`ZPDFColourMath.sameHue`), not bit for bit.
            """
        )
        // …and that inexact value must not read as a user edit of the colour in force.
        #expect(InspectorColourControl.pickedColour(roundTripped, current: current) == nil)
    }

    // MARK: - CR-118: the number field on a non-finite value

    /// CR-118 — `String(Int(rounded))` traps.
    ///
    /// `Int(_:)` traps rather than returning `nil`, and `inf == inf.rounded()` is `true`, so an
    /// infinite line width took the whole-number branch and killed the process. Old output,
    /// against the code before the fix — a crash, not a failed expectation:
    ///
    /// ```
    /// Swift/arm64e-apple-macos.swiftinterface:39429: Fatal error: Double value cannot be
    /// converted to Int because it is either infinite or NaN
    /// error: Process '…/ZPDFUIShellPackageTests --filter InspectorFindingsTests …'
    ///   exited with unexpected signal code 5
    /// (the whole test process died; no later test in the suite ran)
    /// ```
    @Test("A non-finite value formats as nothing instead of trapping")
    func nonFiniteValuesDoNotTrap() {
        #expect(InspectorNumberControl.format(.infinity).isEmpty)
        #expect(InspectorNumberControl.format(-.infinity).isEmpty)
        #expect(InspectorNumberControl.format(.nan).isEmpty)
        #expect(InspectorNumberControl.format(.signalingNaN).isEmpty)
        // Finite, but large enough that `value * 100` overflows to infinity on the way.
        #expect(InspectorNumberControl.format(Double.greatestFiniteMagnitude).isEmpty)
        // Finite and enormous but not overflowing: rendered, never trapped.
        #expect(!InspectorNumberControl.format(1e30).isEmpty)
        #expect(!InspectorNumberControl.format(-1e30).isEmpty)
    }

    @Test("The ordinary numbers still format the way the mockup shows them")
    func ordinaryNumbersAreUnchanged() {
        #expect(InspectorNumberControl.format(2) == "2")
        #expect(InspectorNumberControl.format(0.25) == "0.25")
        #expect(InspectorNumberControl.format(6.5) == "6.50")
        #expect(InspectorNumberControl.format(-3) == "-3")
        #expect(InspectorNumberControl.format(0) == "0")
        #expect(InspectorNumberControl.format(nil).isEmpty)
    }

    // MARK: - CR-116: Custom Data with no ledger rows

    /// CR-116 — "Multiple values" for a selection with no values at all.
    ///
    /// The expression was `values.count == 1 ? values.first! : mixedPlaceholder`, so an empty
    /// set — every selection the ledger holds no row for — fell into the `else`. Old output,
    /// against the code before the fix:
    ///
    /// ```
    /// ✘ Test "A custom column with no rows behind it reads as an em dash" recorded an issue at
    ///   InspectorFindingsTests.swift:167:9: Expectation failed:
    ///   (InspectorPanel.customDataText([]) → "Multiple values") == "—"
    /// ✘ Test "A custom column with no rows behind it reads as an em dash" recorded an issue at
    ///   InspectorFindingsTests.swift:168:9: Expectation failed:
    ///   (InspectorPanel.customDataText([]) → "Multiple values")
    ///   == (InspectorAppearanceText.none → "—")
    /// ```
    @Test("A custom column with no rows behind it reads as an em dash")
    func customDataWithNoRowsIsAnEmDash() {
        #expect(InspectorPanel.customDataText([]) == "—")
        #expect(InspectorPanel.customDataText([]) == InspectorAppearanceText.none)
        #expect(InspectorPanel.customDataText(["Concrete"]) == "Concrete")
        #expect(InspectorPanel.customDataText(["Concrete", "Screed"])
                == InspectorSelectionSummary.mixedPlaceholder)
    }

    @Test("An unfiled selection shows no custom value, and does not claim there are several")
    func anUnfiledSelectionShowsNothing() {
        let environment = ProjectShellEnvironment.mock()
        let custom = environment.ledger.columns.filter { $0.id.isCustom }
        #expect(!custom.isEmpty, "the sample project must define custom columns")

        // A markup identity the ledger has never seen: no rows come back.
        let rows = environment.ledger.rows(withIDs: [UUID()])
        #expect(rows.isEmpty)
        for column in custom {
            let values = Set(rows.map { $0.displayValue(column.id) })
            #expect(InspectorPanel.customDataText(values) == "—", "\(column.title) claimed several values")
        }
    }

    // MARK: - CR-109: the Subject combo re-committing an undone edit

    /// CR-109 — ⌘Z, then a click elsewhere, silently re-applied the undone rename.
    ///
    /// The draft was seeded once, in `init`, so it lived as long as SwiftUI kept the view's
    /// identity — per selection, not per edit. An undo moved the model's subject back and left
    /// the field showing the old text; losing focus then committed it. Old output, against the
    /// code before the fix — the helper did not exist, and the stale draft was unreachable:
    ///
    /// ```
    /// ✘ Test "An undone rename is not re-committed on focus loss" recorded an issue at
    ///   InspectorFindingsTests.swift:226:9: Expectation failed: (draft → "Outer Wall") == "Wall"
    /// ✘ Test "An undone rename is not re-committed on focus loss" recorded an issue at
    ///   InspectorFindingsTests.swift:230:9: Expectation failed:
    ///   (edits → [(Set([5A504446-…-0000000003E8]), "Outer Wall")]).isEmpty → false
    /// ```
    @Test("An undone rename is not re-committed on focus loss")
    func anUndoneRenameIsNotRecommitted() throws {
        let environment = ProjectShellEnvironment.mock()
        // Unlocked, so "inert" is the draft rule's doing, not the lock rule's (W-039).
        var markup = try #require(environment.canvas.visibleMarkups.first { !$0.locked })
        markup.subject = "Wall"
        let selection = InspectorSelectionSummary(markups: [markup])
        let model = InspectorMeasurementModel(environment: environment, selection: selection)

        var edits: [(Set<UUID>, String)] = []
        environment.inspectorEditing.onEditSubject = { edits.append(($0, $1)) }

        // The stale draft the field was left holding after ⌘Z put the subject back to "Wall".
        var draft = "Outer Wall"

        // THE OLD RULE, as a control: the draft was seeded once and never re-read, so this is
        // what focus loss committed.
        #expect(model.subjectText == "Wall")
        #expect(draft != model.subjectText, "the control is only meaningful while the draft is stale")

        // THE RULE NOW: while nobody is typing, the field follows the subject.
        if let reseeded = InspectorSubjectCombo.reseededDraft(subject: model.subjectText, isFocused: false) {
            draft = reseeded
        }
        #expect(draft == "Wall")

        // Focus loss then commits what is on screen, which is what is already stored — inert.
        model.commitSubject(draft)
        #expect(edits.isEmpty, "the undone edit was re-applied on focus loss")
    }

    @Test("A person who is typing is never overwritten underneath")
    func typingIsNotOverwritten() {
        #expect(InspectorSubjectCombo.reseededDraft(subject: "Wall", isFocused: true) == nil)
        #expect(InspectorSubjectCombo.reseededDraft(subject: "Wall", isFocused: false) == "Wall")
        #expect(InspectorSubjectCombo.reseededDraft(subject: "", isFocused: false) == "",
                "a mixed selection clears the field rather than keeping one member's subject")
    }

    @Test("A real rename still commits")
    func aRealRenameStillCommits() throws {
        let environment = ProjectShellEnvironment.mock()
        // Unlocked: a locked markup's subject is not editable (W-039).
        var markup = try #require(environment.canvas.visibleMarkups.first { !$0.locked })
        markup.subject = "Wall"
        let model = InspectorMeasurementModel(
            environment: environment,
            selection: InspectorSelectionSummary(markups: [markup])
        )
        var edits: [(Set<UUID>, String)] = []
        environment.inspectorEditing.onEditSubject = { edits.append(($0, $1)) }

        model.commitSubject("Outer Wall")
        #expect(edits.count == 1)
        #expect(edits.first?.1 == "Outer Wall")
    }

    // MARK: - CR-110: the Scale Region popup

    /// CR-110 — the popup showed nothing selected, two different ways.
    ///
    /// A mixed selection resolved to an id that was in no choice list, and a single selection
    /// resolved BY NAME across every page while the choices were scoped to the selection's own
    /// page — so a region named the same on two sheets handed back an id the popup was not
    /// offering. Both render as a popup with no selection, which reads as "no Scale Region".
    /// Old output, against the code before the fix:
    ///
    /// ```
    /// ✘ Test "A mixed selection has a choice to point at" recorded an issue at
    ///   InspectorFindingsTests.swift:299:9: Expectation failed:
    ///   choices.contains { $0.id == model.currentScaleRegionChoiceID }
    /// ✘ Test "A mixed selection has a choice to point at" recorded an issue at
    ///   InspectorFindingsTests.swift:303:9: Expectation failed:
    ///   (choices.last?.name → "Stair Detail 1:20")
    ///   == (InspectorSelectionSummary.mixedPlaceholder → "Multiple values")
    /// ✘ Test "The current choice is resolved on the selection's own page" recorded an issue at
    ///   InspectorFindingsTests.swift:353:9: Expectation failed:
    ///   (model.currentScaleRegionChoiceID → "5A504446-0000-4000-8000-0000000000D4")
    ///   == (InspectorMeasurementModel.pageDefaultChoiceID → "page-default")
    /// ✘ Test "The current choice is resolved on the selection's own page" recorded an issue at
    ///   InspectorFindingsTests.swift:354:9: Expectation failed:
    ///   choices.contains { $0.id == model.currentScaleRegionChoiceID }
    /// ```
    @Test("A mixed selection has a choice to point at")
    func aMixedSelectionHasAChoice() throws {
        let environment = ProjectShellEnvironment.mock()
        let pageID = try #require(environment.document.pages.first?.id)
        var withRegion = sampleMarkup(0)
        withRegion.pageID = pageID
        withRegion.scaleRegionName = "Stair Detail 1:20"
        var without = sampleMarkup(1)
        without.pageID = pageID
        without.scaleRegionName = nil
        // Unlocked, so the marker's refusal below is its own rule, not the lock rule (W-039).
        withRegion.locked = false
        without.locked = false

        let model = InspectorMeasurementModel(
            environment: environment,
            selection: InspectorSelectionSummary(markups: [withRegion, without])
        )
        #expect(model.isScaleRegionMixed)
        #expect(model.currentScaleRegionChoiceID == InspectorMeasurementModel.mixedChoiceID)

        let choices = model.scaleRegionChoices
        #expect(
            choices.contains { $0.id == model.currentScaleRegionChoiceID },
            "a popup told to select an id it does not hold shows nothing selected"
        )
        #expect(choices.last?.name == InspectorSelectionSummary.mixedPlaceholder)

        // Picking the marker is not an edit.
        var assigned = 0
        environment.inspectorEditing.onAssignScaleRegion = { _, _ in assigned += 1 }
        model.selectScaleRegion(choiceID: InspectorMeasurementModel.mixedChoiceID)
        #expect(assigned == 0)
    }

    @Test("A selection that agrees is offered no mixed marker to pick")
    func anAgreeingSelectionHasNoMixedMarker() throws {
        let environment = ProjectShellEnvironment.mock()
        let pageID = try #require(environment.document.pages.first?.id)
        var markup = sampleMarkup(0)
        markup.pageID = pageID
        markup.scaleRegionName = "Stair Detail 1:20"

        let model = InspectorMeasurementModel(
            environment: environment,
            selection: InspectorSelectionSummary(markups: [markup])
        )
        #expect(!model.isScaleRegionMixed)
        let choices = model.scaleRegionChoices
        #expect(!choices.contains { $0.id == InspectorMeasurementModel.mixedChoiceID })
        #expect(choices.contains { $0.id == model.currentScaleRegionChoiceID })
    }

    @Test("The current choice is resolved on the selection's own page")
    func theCurrentChoiceIsPageScoped() throws {
        let environment = ProjectShellEnvironment.mock()
        let pages = environment.document.pages
        try #require(pages.count >= 3)
        // "Footing Detail 1:10" is a region of page three. This markup is on page one and
        // carries that name — the shape of two sheets that both have a "Detail" region.
        var markup = sampleMarkup(0)
        markup.pageID = pages[0].id
        markup.scaleRegionName = "Footing Detail 1:10"

        let model = InspectorMeasurementModel(
            environment: environment,
            selection: InspectorSelectionSummary(markups: [markup])
        )
        let choices = model.scaleRegionChoices
        let offPageRegion = try #require(
            environment.document.scaleRegions.first { $0.name == "Footing Detail 1:10" }
        )
        #expect(
            !choices.contains { $0.id == offPageRegion.id.uuidString },
            "the choices are page-scoped; the resolution has to be too"
        )
        #expect(model.currentScaleRegionChoiceID == InspectorMeasurementModel.pageDefaultChoiceID)
        #expect(choices.contains { $0.id == model.currentScaleRegionChoiceID })
    }

    @Test("A region on the selection's own page still resolves to itself")
    func anOnPageRegionStillResolves() throws {
        let environment = ProjectShellEnvironment.mock()
        let pages = environment.document.pages
        let region = try #require(environment.document.scaleRegions.first { $0.name == "Stair Detail 1:20" })
        var markup = sampleMarkup(0)
        markup.pageID = pages[0].id
        markup.scaleRegionName = region.name

        let model = InspectorMeasurementModel(
            environment: environment,
            selection: InspectorSelectionSummary(markups: [markup])
        )
        #expect(model.currentScaleRegionChoiceID == region.id.uuidString)
        #expect(model.scaleRegionChoices.contains { $0.id == region.id.uuidString })
    }
}
