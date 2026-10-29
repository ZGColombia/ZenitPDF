import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Design round d5: the Inspector restyled after the 2026-09-23 main-window mockup — the
/// title band, the Markup / Properties / Comments tabs, the header card and the form rows.
///
/// These pin the structure (tab order, which section lives where, what the header says), the
/// value rules the new rows add (the secondary unit, initials, the stored status value), the
/// token rule (no raw colour literal in the Inspector's sources) and one off-screen render per
/// appearance. Nothing here opens a window: the render is a hosting view drawn with
/// `cacheDisplay(in:to:)` and never added to one.
@MainActor
@Suite("Design d5 — Inspector after the 2026-09-23 mockup", .shellTierSerialised)
struct DesignD5InspectorTests {

    // MARK: - Fixtures

    private static let sample = ZenitSampleProject.shared.markups

    private static func markup(
        kind: MarkupKind = .measurement,
        measurementKind: MeasurementKind? = .area,
        subject: String = "Floor Screed",
        comment: String = "",
        pageLabel: String = "A-101",
        author: String = "Test Author",
        status: MarkupStatus = .open,
        modified: Date = Date(timeIntervalSince1970: 1_700_000_000),
        fields: [MeasurementFieldSummary] = []
    ) -> MarkupSummary {
        MarkupSummary(
            id: UUID(),
            kind: kind,
            measurementKind: measurementKind,
            subject: subject,
            label: "Room 1",
            comment: comment,
            pageLabel: pageLabel,
            pageID: PageDescriptor.ID(),
            pageIndex: 0,
            status: status,
            author: author,
            colorRGBA: ColorRGBA(red: 0.2, green: 0.4, blue: 1, alpha: 1),
            measurementFields: fields,
            created: Date(timeIntervalSince1970: 1_699_000_000),
            modified: modified,
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 10, height: 10)
        )
    }

    private static func areaField(squareMetres: Decimal, shownIn symbol: String, text: String) -> MeasurementFieldSummary {
        MeasurementFieldSummary(
            field: .planArea,
            quantity: DecimalQuantity(value: squareMetres, dimension: .area),
            displayText: text,
            displayUnitSymbol: symbol
        )
    }

    private static func lengthField(metres: Decimal, shownIn symbol: String, text: String) -> MeasurementFieldSummary {
        MeasurementFieldSummary(
            field: .perimeter,
            quantity: DecimalQuantity(value: metres, dimension: .length),
            displayText: text,
            displayUnitSymbol: symbol
        )
    }

    // MARK: - Tabs

    @Test("The tabs read Markup, Properties, Comments, in the mockup's order, Markup first")
    func tabOrder() {
        // r2-markup (NL-UX-06): a fourth tab docks the Tool Library.
        #expect(InspectorTab.allCases == [.markup, .properties, .comments, .tools])
        #expect(InspectorTab.allCases.map(\.title) == ["Markup", "Properties", "Comments", "Tools"])
        #expect(InspectorTab.initial == .markup)
        for tab in InspectorTab.allCases {
            #expect(!tab.helpText.isEmpty, "\(tab) has hover help and a VoiceOver hint")
        }
    }

    @Test("Every Inspector section is reachable from exactly one tab")
    func everySectionHasOneHome() {
        for section in InspectorSection.allCases {
            let homes = InspectorTab.allCases.filter { $0.sections.contains(section) }
            #expect(homes.count == 1, "\(section) appears on \(homes)")
        }
        #expect(InspectorTab.markup.sections == [.appearance, .caption])
        #expect(InspectorTab.propertiesSections.first == .measurement)
        #expect(InspectorTab.propertiesSections.last == .actions)
    }

    @Test("Left and Right move between the tabs and stop at either end")
    func tabKeyboard() {
        #expect(InspectorTabStrip.tab(after: .markup, moving: .right) == .properties)
        #expect(InspectorTabStrip.tab(after: .properties, moving: .right) == .comments)
        #expect(InspectorTabStrip.tab(after: .comments, moving: .right) == .tools)
        #expect(InspectorTabStrip.tab(after: .tools, moving: .right) == nil)
        #expect(InspectorTabStrip.tab(after: .markup, moving: .left) == nil)
        #expect(InspectorTabStrip.tab(after: .comments, moving: .left) == .properties)
        #expect(InspectorTabStrip.tab(after: .properties, moving: .up) == nil)
    }

    // MARK: - Header card

    @Test("One area measurement: the card reads its type, subject and page")
    func headerForOneMeasurement() throws {
        let model = try #require(InspectorHeaderModel(summary: InspectorSelectionSummary(markups: [Self.markup()])))
        #expect(model.title == "Area Measurement")
        #expect(model.subtitle == "Floor Screed · Page A-101")
        #expect(model.glyph == .measurement(.area))
    }

    @Test("A markup with no subject shows its page alone; a callout its own type name")
    func headerWithoutSubject() throws {
        let callout = Self.markup(kind: .callout, measurementKind: nil, subject: "  ")
        let model = try #require(InspectorHeaderModel(summary: InspectorSelectionSummary(markups: [callout])))
        #expect(model.title == "Callout")
        #expect(model.subtitle == "Page A-101")
        #expect(model.glyph == .symbol(.callout))
    }

    @Test("Several markups: the card counts them and names the shared type")
    func headerForSeveral() throws {
        let selection = InspectorSelectionSummary(markups: [Self.markup(), Self.markup()])
        let model = try #require(InspectorHeaderModel(summary: selection))
        #expect(model.title == "2 markups selected")
        #expect(model.subtitle == MarkupKind.measurement.displayName)
        let mixed = InspectorSelectionSummary(markups: [Self.markup(), Self.markup(kind: .callout, measurementKind: nil)])
        let mixedModel = try #require(InspectorHeaderModel(summary: mixed))
        #expect(mixedModel.glyph == .symbol(.inspector))
        #expect(mixedModel.subtitle == "2 different markup types")
    }

    @Test("Nothing selected: no header card at all")
    func noHeaderWhenEmpty() {
        #expect(InspectorHeaderModel(summary: InspectorSelectionSummary(markups: [])) == nil)
    }

    @Test("Every sample markup gets a tile glyph and a non-empty title")
    func everySampleHasAHeader() throws {
        for markup in Self.sample {
            let model = try #require(InspectorHeaderModel(summary: InspectorSelectionSummary(markups: [markup])))
            #expect(!model.title.isEmpty)
        }
    }

    // MARK: - Author

    @Test("Initials come from the first and last word, letters only")
    func initials() {
        #expect(InspectorMarkupFormatting.initials(for: "John Doe") == "JD")
        #expect(InspectorMarkupFormatting.initials(for: "anna") == "A")
        #expect(InspectorMarkupFormatting.initials(for: "Test Mellan Person") == "TP")
        #expect(InspectorMarkupFormatting.initials(for: "ärt ört", locale: Locale(identifier: "sv_SE")) == "ÄÖ")
        #expect(InspectorMarkupFormatting.initials(for: "jd@site.example") == "J")
        #expect(InspectorMarkupFormatting.initials(for: "a.berg@site.example") == "AB")
        #expect(InspectorMarkupFormatting.initials(for: "") == "?")
        #expect(InspectorMarkupFormatting.initials(for: "  123 ") == "?")
    }

    // MARK: - Secondary unit

    @Test("An area shown in square feet is restated in square metres, and the reverse")
    func secondaryArea() {
        // 57.6 m² is 620.0 ft².
        let imperial = InspectorSelectionSummary(markups: [Self.markup(fields: [
            Self.areaField(squareMetres: Decimal(string: "57.6")!, shownIn: "ft²", text: "620.0")
        ])])
        #expect(InspectorMarkupFormatting.secondaryText(for: .planArea, isTotal: false, in: imperial, locale: Locale(identifier: "en_US")) == "57.6 m²")
        let metric = InspectorSelectionSummary(markups: [Self.markup(fields: [
            Self.areaField(squareMetres: 10, shownIn: "m²", text: "10.00")
        ])])
        #expect(InspectorMarkupFormatting.secondaryText(for: .planArea, isTotal: false, in: metric, locale: Locale(identifier: "en_US")) == "107.64 ft²")
    }

    @Test("A length shown in feet is restated in metres, in the reader's decimal mark")
    func secondaryLength() {
        let feet = InspectorSelectionSummary(markups: [Self.markup(fields: [
            Self.lengthField(metres: Decimal(string: "30.48")!, shownIn: "ft", text: "100' - 0\"")
        ])])
        #expect(InspectorMarkupFormatting.secondaryText(for: .perimeter, isTotal: false, in: feet, locale: Locale(identifier: "en_US")) == "30.48 m")
        #expect(InspectorMarkupFormatting.secondaryText(for: .perimeter, isTotal: false, in: feet, locale: Locale(identifier: "sv_SE")) == "30,48 m")
    }

    @Test("The restated value borrows the primary value's decimal mark, whatever the system locale")
    func secondaryFollowsPrimaryMark() {
        // R-070: the mark is read in the document's number locale by the reader the Inspector's
        // totals share (`decimalMark(in:)`, which took the last "." or ",", is gone).
        let enUS = Locale(identifier: "en_US")
        #expect(InspectorDisplayedNumber.read("27,45", locale: enUS)?.decimalMark == ",")
        #expect(InspectorDisplayedNumber.read("1,234.50", locale: enUS)?.decimalMark == ".")
        #expect(InspectorDisplayedNumber.read("100' - 0\"", locale: enUS) == nil)
        #expect(InspectorDisplayedNumber.read("12", locale: enUS)?.decimalMark == nil)
        let swedish = InspectorSelectionSummary(markups: [Self.markup(fields: [
            Self.areaField(squareMetres: 10, shownIn: "m²", text: "10,00")
        ])])
        #expect(InspectorMarkupFormatting.secondaryText(for: .planArea, isTotal: false, in: swedish, locale: Locale(identifier: "en_US")) == "107,64 ft²")
        let english = InspectorSelectionSummary(markups: [Self.markup(fields: [
            Self.areaField(squareMetres: 1_000, shownIn: "m²", text: "1000.00")
        ])])
        #expect(InspectorMarkupFormatting.secondaryText(for: .planArea, isTotal: false, in: english, locale: Locale(identifier: "sv_SE")) == "10763.91 ft²")
    }

    @Test("Several markups restate their sum; mixed units and missing fields restate nothing")
    func secondaryRules() {
        let a = Self.markup(fields: [Self.areaField(squareMetres: 10, shownIn: "m²", text: "10.00")])
        let b = Self.markup(fields: [Self.areaField(squareMetres: 20, shownIn: "m²", text: "20.00")])
        let summed = InspectorSelectionSummary(markups: [a, b])
        #expect(InspectorMarkupFormatting.secondaryText(for: .planArea, isTotal: true, in: summed, locale: Locale(identifier: "en_US")) == "322.92 ft²")

        let c = Self.markup(fields: [Self.areaField(squareMetres: 20, shownIn: "ft²", text: "215.3")])
        #expect(InspectorMarkupFormatting.secondaryText(for: .planArea, isTotal: false, in: InspectorSelectionSummary(markups: [a, c])) == nil)

        let bare = Self.markup(fields: [])
        #expect(InspectorMarkupFormatting.secondaryText(for: .planArea, isTotal: false, in: InspectorSelectionSummary(markups: [a, bare])) == nil)

        let count = Self.markup(measurementKind: .count, fields: [MeasurementFieldSummary(
            field: .count, quantity: DecimalQuantity(value: 12, dimension: .count), displayText: "12", displayUnitSymbol: ""
        )])
        #expect(InspectorMarkupFormatting.secondaryText(for: .count, isTotal: false, in: InspectorSelectionSummary(markups: [count])) == nil)
    }

    @Test("The quantity row speaks both units, and a total says it is one")
    func quantitySpeechAndLabels() {
        #expect(InspectorQuantityRow.spokenValue(primary: "620.0 ft²", secondary: "57.6 m²") == "620.0 ft², 57.6 m²")
        #expect(InspectorQuantityRow.spokenValue(primary: "12", secondary: nil) == "12")
        let single = InspectorMeasurementModel.ValueRow(id: .planArea, text: "10 m²")
        #expect(InspectorPanel.quantityLabel(for: single) == MeasurementField.planArea.displayName)
        let total = InspectorMeasurementModel.ValueRow(id: .planArea, text: "30 m²", isTotal: true)
        #expect(InspectorPanel.quantityLabel(for: total) == "Total \(MeasurementField.planArea.displayName)")
    }

    // MARK: - Status

    @Test("The status popup writes the document's own value for all eight states")
    func storedStatus() {
        #expect(MarkupStatus.allCases.count == 8)
        #expect(InspectorMarkupFormatting.storedStatusValue(.inProgress) == "inProgress")
        #expect(InspectorMarkupFormatting.storedStatusValue(.cancelled) == "cancelled")
        for status in MarkupStatus.allCases {
            #expect(InspectorMarkupFormatting.storedStatusValue(status) == status.rawValue)
        }
        #expect(InspectorMarkupFormatting.severity(for: .open) == .info)
        #expect(InspectorMarkupFormatting.severity(for: .rejected) == .danger)
        #expect(InspectorMarkupFormatting.severity(for: .none) == .neutral)
    }

    @Test("Choosing a status issues one bulk edit over the whole selection")
    func statusEditGoesThroughBulkEdit() async throws {
        let environment = ProjectShellEnvironment.mock()
        let mock = try #require(environment.ledger as? MockLedgerPresenter)
        let targets = Array(Self.sample.filter { !$0.locked && $0.status != .accepted }.prefix(2))
        try #require(targets.count == 2)
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())
        let before = mock.appliedBulkEdits.count
        panel.applyStatus(.accepted, to: InspectorSelectionSummary(markups: targets))
        for _ in 0..<20 where mock.appliedBulkEdits.count == before { await Task.yield() }
        let request = try #require(mock.appliedBulkEdits.last)
        #expect(mock.appliedBulkEdits.count == before + 1)
        #expect(request.markupIDs == Set(targets.map(\.id)))
        #expect(request.values[.status] == .choice("accepted"))
        #expect(request.style.isEmpty && request.color == nil)
    }

    /// Bug InspectorPanel.swift:450 (NL-COLLAB-03). Old output: a `cancelled` markup reached
    /// the Inspector as `.rejected`, so `common(\.status) != .rejected` was false and picking
    /// "Rejected" returned early — zero bulk edits, the markup stayed `cancelled` on disk.
    @Test("Picking Rejected on a cancelled markup writes rejected")
    func rejectedOnCancelledWrites() async throws {
        let environment = ProjectShellEnvironment.mock()
        let mock = try #require(environment.ledger as? MockLedgerPresenter)
        var target = try #require(Self.sample.first { !$0.locked })
        target.status = .cancelled
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())
        let before = mock.appliedBulkEdits.count
        panel.applyStatus(.rejected, to: InspectorSelectionSummary(markups: [target]))
        for _ in 0..<20 where mock.appliedBulkEdits.count == before { await Task.yield() }
        #expect(mock.appliedBulkEdits.count == before + 1)
        #expect(mock.appliedBulkEdits.last?.values[.status] == .choice("rejected"))
    }

    @Test("A status the selection already has is not re-written")
    func unchangedStatusWritesNothing() async throws {
        let environment = ProjectShellEnvironment.mock()
        let mock = try #require(environment.ledger as? MockLedgerPresenter)
        let target = try #require(Self.sample.first { !$0.locked })
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())
        let before = mock.appliedBulkEdits.count
        panel.applyStatus(target.status, to: InspectorSelectionSummary(markups: [target]))
        for _ in 0..<10 { await Task.yield() }
        #expect(mock.appliedBulkEdits.count == before)
    }

    @Test("Label, Notes and Status are off for a selection that includes a locked markup")
    func lockedSelectionIsReadOnly() throws {
        let environment = ProjectShellEnvironment.mock()
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())
        let locked = try #require(Self.sample.first { $0.locked })
        let unlocked = try #require(Self.sample.first { !$0.locked })
        #expect(panel.canEditText(InspectorSelectionSummary(markups: [unlocked])))
        #expect(!panel.canEditText(InspectorSelectionSummary(markups: [unlocked, locked])))
        #expect(!panel.canEditText(InspectorSelectionSummary(markups: [])))
    }

    @Test("A field edit the document drops says so; a dropped style edit and a real refusal do not use it")
    func droppedFieldEditIsReported() {
        let ids: Set<UUID> = [UUID()]
        let notes = LedgerBulkEditRequest(markupIDs: ids, values: [.comment: .text("Check")])
        #expect(InspectorStyleEditing.unappliedMessage(for: notes, receipt: LedgerBulkEditReceipt(undoActionName: "Bulk Edit")) != nil)
        #expect(InspectorStyleEditing.unappliedMessage(
            for: notes, receipt: LedgerBulkEditReceipt(changedMarkupIDs: ids, undoActionName: "Bulk Edit")
        ) == nil)
        #expect(InspectorStyleEditing.unappliedMessage(for: notes, receipt: .failure("locked")) == nil)
        let style = LedgerBulkEditRequest(markupIDs: ids, style: MarkupStyleEdit(lineWidth: 2))
        #expect(InspectorStyleEditing.unappliedMessage(for: style, receipt: LedgerBulkEditReceipt()) == nil)
    }

    // MARK: - Fill

    @Test("Fill Colour is offered where there is an interior; the swatch shows the fill the canvas draws")
    func fillRules() {
        let area = Self.markup()
        #expect(InspectorMarkupFormatting.acceptsFill(area))
        #expect(InspectorMarkupFormatting.derivesFill(area))
        let effective = InspectorMarkupFormatting.effectiveFill(area)
        #expect(effective?.red == area.colorRGBA.red)
        #expect(abs((effective?.alpha ?? 0) - area.colorRGBA.alpha * 0.20) < 0.0001,
                "an unfilled area shows the 20 % stroke tint the canvas derives")
        #expect(MarkupFillDefaults.derivedAreaFillAlpha == 0.20, "one shared constant, the mockup's 20 %")
        #expect(InspectorMarkupFormatting.derivedFillAlpha == MarkupFillDefaults.derivedAreaFillAlpha)

        var filled = area
        filled.fillRGBA = ColorRGBA(red: 1, green: 0, blue: 0, alpha: 0.3)
        #expect(InspectorMarkupFormatting.effectiveFill(filled) == filled.fillRGBA)

        let callout = Self.markup(kind: .callout, measurementKind: nil)
        #expect(InspectorMarkupFormatting.acceptsFill(callout))
        #expect(InspectorMarkupFormatting.effectiveFill(callout) == nil, "a callout without a fill draws none")

        let length = Self.markup(measurementKind: .length)
        #expect(!InspectorMarkupFormatting.acceptsFill(length))
        let arrow = Self.markup(kind: .arrow, measurementKind: nil)
        #expect(!InspectorMarkupFormatting.acceptsFill(arrow))
    }

    @Test("A fill edit is an edit; clearing is one too; a derived value's agreement is found")
    func fillEditShape() {
        #expect(!MarkupStyleEdit(fill: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 0.2)).isEmpty)
        #expect(!MarkupStyleEdit(removesFill: true).isEmpty)
        #expect(MarkupStyleEdit().isEmpty)
        #expect(InspectorSelectionSummary.commonValue([1, 1, 1]) == 1)
        #expect(InspectorSelectionSummary.commonValue([1, 2]) == nil)
        let none: [ColorRGBA?] = [nil, nil]
        #expect(InspectorSelectionSummary.commonValue(none) == .some(nil), "agreeing on no fill is not mixed")
    }

    @Test("The review status Open has its own catalogue key, so Swedish can say Öppen")
    func openStatusKey() {
        #expect(MarkupStatus.open.displayName == "Open")
    }

    // MARK: - Lock and Hide

    @Test("Lock and Hide titles follow the selection's state; Hide is off where setHidden would refuse")
    func lockHideRules() {
        var locked = Self.markup(); locked.locked = true
        var hidden = Self.markup(); hidden.hidden = true
        let plain = Self.markup()
        let one = InspectorSelectionSummary(markups: [plain])
        #expect(InspectorMarkupFormatting.lockTitle(one) == "Lock" && InspectorMarkupFormatting.lockTarget(one))
        #expect(InspectorMarkupFormatting.hideTitle(one) == "Hide" && InspectorMarkupFormatting.hideTarget(one))
        let allLocked = InspectorSelectionSummary(markups: [locked, locked])
        #expect(InspectorMarkupFormatting.lockTitle(allLocked) == "Unlock" && !InspectorMarkupFormatting.lockTarget(allLocked))
        let partly = InspectorSelectionSummary(markups: [locked, plain])
        #expect(InspectorMarkupFormatting.lockTitle(partly) == "Lock", "a partly locked selection locks the rest")
        let allHidden = InspectorSelectionSummary(markups: [hidden])
        #expect(InspectorMarkupFormatting.hideTitle(allHidden) == "Show" && !InspectorMarkupFormatting.hideTarget(allHidden))
        #expect(InspectorMarkupFormatting.canChangeVisibility(one))
        #expect(!InspectorMarkupFormatting.canChangeVisibility(partly), "setHidden refuses a locked markup that would change")
        var lockedHidden = locked; lockedHidden.hidden = true
        #expect(InspectorMarkupFormatting.canChangeVisibility(InspectorSelectionSummary(markups: [lockedHidden, hidden])) == false,
                "showing a locked hidden markup is refused too")
        #expect(!InspectorMarkupFormatting.canChangeVisibility(InspectorSelectionSummary(markups: [])))
    }

    @Test("The ⋯ menu's Lock and Hide call the app's hooks with the selection and the target state")
    func lockHideHooks() {
        let environment = ProjectShellEnvironment.mock()
        var lockCalls: [(Set<UUID>, Bool)] = []
        var hideCalls: [(Set<UUID>, Bool)] = []
        environment.inspectorEditing.onSetLocked = { lockCalls.append(($0, $1)) }
        environment.inspectorEditing.onSetHidden = { hideCalls.append(($0, $1)) }
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())
        let a = Self.markup(), b = Self.markup()
        let both = InspectorSelectionSummary(markups: [a, b])
        panel.toggleLock(both)
        panel.toggleVisibility(both)
        #expect(lockCalls.count == 1 && lockCalls[0].0 == [a.id, b.id] && lockCalls[0].1 == true)
        #expect(hideCalls.count == 1 && hideCalls[0].0 == [a.id, b.id] && hideCalls[0].1 == true)

        var locked = a; locked.locked = true
        panel.toggleVisibility(InspectorSelectionSummary(markups: [locked, b]))
        #expect(hideCalls.count == 1, "a refused Hide never reaches the command")
        panel.toggleLock(InspectorSelectionSummary(markups: [locked]))
        #expect(lockCalls.last?.1 == false, "a locked selection unlocks")
    }

    // MARK: - Polish (d9 final QA)

    @Test("Typed and picked values read regular; only the measured value is emphasised")
    func valueWeights() {
        #expect(InspectorTypography.fieldValue.nsWeight == .regular)
        #expect(InspectorTypography.popupValue.nsWeight == .regular)
        #expect(InspectorTypography.emphasisedValue.nsWeight == .semibold)
    }

    @Test("A percentage hugs its sign, a word unit keeps its space; the stepper shows on hover or edit")
    func numberControlRest() {
        #expect(InspectorNumberControl.suffixSpacing(for: "%") < InspectorNumberControl.suffixSpacing(for: "pt"))
        #expect(!InspectorNumberControl.showsStepper(isHovering: false, isEditing: false))
        #expect(InspectorNumberControl.showsStepper(isHovering: true, isEditing: false))
        #expect(InspectorNumberControl.showsStepper(isHovering: false, isEditing: true))
    }

    @Test("Every Markup-tab row label fits its column on one line")
    func labelsFitOneLine() {
        let font = ZPDFTypography.nsFont(.rowLabel)
        let labels = ["Fill Colour", "Ink opacity", "Opacity", "Border", "Style", "Layer", "Status",
                      "Author", "Created", "Modified", "Text size"]
        for label in labels {
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            #expect(width <= InspectorMetrics.labelColumn, "\(label) is \(width) pt, column \(InspectorMetrics.labelColumn)")
        }
    }

    @Test("The header card sits on the raised card tone")
    func headerCardIsRaised() {
        #expect(InspectorChrome.raisedCard == .elevated)
        #expect(InspectorChrome.raisedCard != InspectorChrome.panel)
    }

    // MARK: - Comments

    /// Bug InspectorCommentsTab:31. Old output: every card named the markup's author and was
    /// dated by the markup's last modification, so B's note on A's markup read as A's and its
    /// time moved with every drag. Now who and when come from the note's own History row.
    @Test("The Comments tab lists every non-blank note by who wrote it, newest written first")
    func commentCards() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        let a = Self.markup(subject: "Walls", comment: "Check height", modified: late)
        let b = Self.markup(subject: "Doors", comment: "   ", modified: late)
        let c = Self.markup(subject: "Floors", comment: "Verify finish\n", modified: early)
        let d = Self.markup(subject: "Ceilings", comment: "Never recorded", modified: late)
        let written: [UUID: (String, Date)] = [a.id: ("Bo", early), c.id: ("Cy", late)]
        let cards = InspectorCommentCard.cards(
            for: InspectorSelectionSummary(markups: [a, b, c, d]),
            attribution: { markup in written[markup.id].map { (author: $0.0, date: Optional($0.1)) } }
        )
        #expect(cards.map(\.id) == [c.id, a.id, d.id])
        #expect(cards.first?.text == "Verify finish")
        #expect(cards.first?.author == "Cy")
        #expect(cards.first?.markupTitle == "Area Measurement · Floors")
        #expect(cards[1].author == "Bo", "the note's writer, not the markup's author")
        #expect(cards[1].written == early, "the note's time, not the markup's last move")
        #expect(cards[2].author.isEmpty && cards[2].written == nil, "unknown stays unknown")
        #expect(InspectorCommentCard.cards(for: InspectorSelectionSummary(markups: [b])).isEmpty)
    }

    // MARK: - Tokens

    @Test("The Inspector's sources draw every colour from a design-system token")
    func noRawColourLiterals() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZPDFUIShell/Inspector", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 10, "found the Inspector sources at \(directory.path)")
        let forbidden = [
            "Color(red:", "Color(white:", "Color(hue:", "Color(.sRGB", "NSColor(red:", "NSColor(calibratedRed:",
            "NSColor(srgbRed:", "NSColor(white:", "#colorLiteral", "Color.white", "Color.black", "Color.blue",
            "Color.red", "Color.green", "Color.gray", ".foregroundStyle(.white)", ".foregroundStyle(.black)",
            ".fill(.white)", ".fill(.black)", "Color(nsColor: .system", "NSColor.system"
        ]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in forbidden {
                #expect(!source.contains(literal), "\(file.lastPathComponent) uses \(literal)")
            }
        }
    }

    @Test("The Inspector's chrome names map to the mockup tokens")
    func chromeTokens() {
        #expect(InspectorChrome.field == .inset)
        #expect(InspectorChrome.fieldEdge == .borderStrong)
        #expect(InspectorChrome.selectedFill == .selectedFill)
        #expect(InspectorChrome.accentFill == .accent)
        #expect(InspectorChrome.accentLine == .accentBlue)
        #expect(InspectorChrome.onAccent == .textOnAccent)
        #expect(InspectorMetrics.fieldHeight == ZPDFSpacing.Chrome.fieldHeight)
        #expect(InspectorMetrics.tile == ZPDFSpacing.Chrome.headerCardIcon)
        #expect(InspectorMetrics.tabUnderline == ZPDFSpacing.Chrome.tabIndicatorHeight)
    }

    // MARK: - Off-screen render

    private static func render(
        appearance: NSAppearance.Name,
        selecting select: Bool,
        tab: InspectorTab = .markup
    ) async -> NSBitmapImageRep {
        let environment = ProjectShellEnvironment.mock()
        if select, let area = environment.canvas.visibleMarkups.first(where: { $0.measurementKind == .area })
            ?? Self.sample.first(where: { $0.measurementKind == .area }) {
            environment.canvas.select(markupIDs: [area.id], additive: false)
        }
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let panelState = ShellPanelState()
        if tab == .properties {
            for section in InspectorTab.propertiesSections { panelState.setExpanded(true, section: section) }
        }
        let view = NSHostingView(rootView: InspectorPanel(environment: environment, panelState: panelState, initialTab: tab)
            .environment(\.colorScheme, scheme))
        let size = NSSize(width: 300, height: 780)
        let nsAppearance = NSAppearance(named: appearance)!
        view.appearance = nsAppearance
        view.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        nsAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        if let directory = ProcessInfo.processInfo.environment["ZENIT_DESIGN_QA_OUT"], !directory.isEmpty,
           let data = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let name = "d5-inspector-\(tab.rawValue)-\(appearance == .darkAqua ? "dark" : "light")\(select ? "" : "-empty").png"
            try? data.write(to: url.appendingPathComponent(name))
        }
        return rep
    }

    /// Fraction of sampled pixels that are dark, and whether any is close to the accent.
    private static func stats(_ rep: NSBitmapImageRep, accent: NSColor) -> (dark: Double, accentPixels: Int) {
        var dark = 0, total = 0, accentPixels = 0
        let target = accent.usingColorSpace(.sRGB)!
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                let luminance = 0.2126 * colour.redComponent + 0.7152 * colour.greenComponent + 0.0722 * colour.blueComponent
                if luminance < 0.35 { dark += 1 }
                if abs(colour.redComponent - target.redComponent) < 0.06,
                   abs(colour.greenComponent - target.greenComponent) < 0.06,
                   abs(colour.blueComponent - target.blueComponent) < 0.06 { accentPixels += 1 }
            }
        }
        return (total == 0 ? 0 : Double(dark) / Double(total), accentPixels)
    }

    @Test("With an area selected the Inspector renders dark, with the accent tile and tab indicator")
    func rendersDark() async throws {
        let rep = await Self.render(appearance: .darkAqua, selecting: true)
        let accent = ZPDFColor.nsColor(.accent, variant: .dark)
        let result = Self.stats(rep, accent: accent)
        #expect(result.dark > 0.7, "dark chrome, as the mockup; dark fraction \(result.dark)")
        #expect(result.accentPixels > 20, "the header tile and avatar use the accent fill; \(result.accentPixels) samples")
    }

    @Test("The light appearance still renders, light")
    func rendersLight() async throws {
        let rep = await Self.render(appearance: .aqua, selecting: true)
        let result = Self.stats(rep, accent: ZPDFColor.nsColor(.accent, variant: .light))
        #expect(result.dark < 0.5, "light appearance is light; dark fraction \(result.dark)")
    }

    @Test("The Properties and Comments tabs render with an area selected")
    func rendersOtherTabs() async throws {
        for tab in [InspectorTab.properties, .comments] {
            let rep = await Self.render(appearance: .darkAqua, selecting: true, tab: tab)
            let result = Self.stats(rep, accent: ZPDFColor.nsColor(.accent, variant: .dark))
            #expect(result.dark > 0.7, "\(tab) is dark chrome; dark fraction \(result.dark)")
        }
    }

    @Test("Nothing selected renders the empty state under the tabs")
    func rendersEmpty() async throws {
        let rep = await Self.render(appearance: .darkAqua, selecting: false)
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
    }
}
