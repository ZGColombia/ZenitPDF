import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Live test 8, area l8-ledger, the shell half: the Markups chip reads the markup count (L-50),
/// History rows name the markup and the change (L-79), the detached ledger opens at a size its
/// panels work in and its filter panel fits (L-84), and the Bulk Edit fields take the keyboard
/// on one click (L-85).
///
/// Nothing here goes on screen: the windows are never ordered in, and clicks are delivered to the
/// view under the pointer the way a key window delivers them.
@MainActor
@Suite("Live test 8: ledger pane", .shellTierSerialised)
struct L8LedgerShellTests {

    // MARK: - Fixtures

    static func environment() -> ProjectShellEnvironment {
        let mocks = MockPresenters.makeEnvironment()
        return ProjectShellEnvironment(
            document: mocks.document,
            canvas: mocks.canvas,
            ledger: mocks.ledger,
            toolLibrary: mocks.toolLibrary,
            search: mocks.search,
            compare: mocks.compare,
            measurement: mocks.measurement,
            status: mocks.status
        )
    }

    static func controls(in view: NSView) -> [NSControl] {
        var result: [NSControl] = []
        for subview in view.subviews {
            if let control = subview as? NSControl, !control.isHidden { result.append(control) }
            result.append(contentsOf: controls(in: subview))
        }
        return result
    }

    static func editableTextFields(in view: NSView) -> [NSTextField] {
        controls(in: view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
    }

    static func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// What a click at the middle of `view` does in a key window: AppKit hands the mouse-down to
    /// the view under the pointer, and a text field there takes the keyboard. Returns that view.
    ///
    /// The mouse-down itself is not replayed: a text field answers it with a tracking loop that
    /// pulls the mouse-up off the application's event queue, and a test process whose
    /// application is not running ends its run when that queue is pumped.
    @discardableResult
    static func click(_ view: NSView, in window: NSWindow) -> NSView? {
        let middle = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let hit = window.contentView?.superview?.hitTest(middle) else { return nil }
        if hit.acceptsFirstResponder { window.makeFirstResponder(hit) }
        spin()
        return hit
    }

    static func editingField(_ window: NSWindow) -> NSTextField? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor.delegate as? NSTextField
    }

    // MARK: - L-50

    /// Old output: the chip's figure was the ledger's row count — "Markups 0" over four text
    /// boxes, whose rows the ledger never has.
    @Test("L-50: the Markups chip shows the presenter's count of markups without a quantity")
    func markupsChipReadsTheMarkupCount() throws {
        let summary = LedgerSummary(totals: .empty, rowCount: 0, kindCounts: [:], markupCount: 4)
        #expect(summary.chip(.markups)?.headline == "4")
        #expect(summary.chip(.markups)?.accessibilityLabel == "Markups, 4 items")

        // The pane hands the presenter's count to the chip.
        let environment = Self.environment()
        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.fix2c2.tests")
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let pane = QuantityLedgerPane(
            environment: environment, panelState: ShellPanelState(),
            preferences: LedgerPanePreferences(defaults: defaults)
        )
        let counting = try #require(environment.ledger as? LedgerMarkupCounting)
        #expect(pane.summary.chip(.markups)?.rowCount == counting.nonMeasurementMarkupCount)
        #expect(counting.nonMeasurementMarkupCount != environment.ledger.rowCount,
                "the mock's sample measures things, so its rows and its non-measurement markups differ")
    }

    // MARK: - L-79

    /// Old output: the row's markup line was the subject alone — empty for a text box — and the
    /// bare page label "1"; Group and Send to Back had no detail at all.
    @Test("L-79: a History row names its markup and, when no value changed, its command")
    func historyRowWording() {
        let text = LedgerAuditEvent(
            sequence: 4, occurredAt: .distantPast, action: "markup_modified", actor: "A. Berg",
            markupID: UUID(), markupSubject: "", pageLabel: "1", commandName: "Group", markupName: "Text"
        )
        #expect(HistoryPaneContent.markupTitle(text) == "Text")
        #expect(HistoryPaneContent.pageText(text) == "Page 1")
        #expect(HistoryPaneContent.detailText(text) == "Group")

        let area = LedgerAuditEvent(
            sequence: 5, occurredAt: .distantPast, action: "markup_modified", actor: "A. Berg",
            markupID: UUID(), markupSubject: "Slab", pageLabel: "1", commandName: "Edit Vertices",
            changes: [LedgerAuditValueChange(field: "planArea", before: "1", after: "2",
                                             fieldDisplayName: "Plan Area", beforeDisplay: "1 m²", afterDisplay: "2 m²")],
            markupName: "Area R-1"
        )
        #expect(HistoryPaneContent.markupTitle(area) == "Area R-1 · Slab")
        #expect(HistoryPaneContent.detailText(area) == "Plan Area 1 m² → 2 m²", "values win over the command name")

        let scale = LedgerAuditEvent(sequence: 1, occurredAt: .distantPast, action: "scale_changed", actor: "A. Berg")
        #expect(HistoryPaneContent.markupTitle(scale) == nil)
        #expect(HistoryPaneContent.pageText(scale) == nil)
    }

    /// Re-check of L-79. Old output: "Plan Area 30,79 m²\nPerimeter 22,4 m" under "Edited" for a
    /// Send to Back on an area — an edit records every measured value on both sides, and every
    /// one of them was listed, unchanged, where the command's name belonged. The rows are shaped
    /// exactly as `AppHistoryPresenter` writes them (`L8LedgerHistoryTests` drives the real bus).
    @Test("L-79: on a measured markup, a step that changed no value shows the command, and only moved values are listed")
    func historyDetailLeavesOutUnchangedValues() {
        func value(_ field: String, _ name: String, _ before: String?, _ after: String?, _ shownBefore: String?, _ shownAfter: String?) -> LedgerAuditValueChange {
            LedgerAuditValueChange(field: field, before: before, after: after, fieldDisplayName: name, beforeDisplay: shownBefore, afterDisplay: shownAfter)
        }
        let area = value("netArea", "Plan Area", "30.79", "30.79", "30,79 m²", "30,79 m²")
        let perimeter = value("perimeter", "Perimeter", "22.4", "22.4", "22,4 m", "22,4 m")
        func row(_ action: String, _ command: String, _ changes: [LedgerAuditValueChange], note: String? = nil) -> LedgerAuditEvent {
            LedgerAuditEvent(
                sequence: 9, occurredAt: .distantPast, action: action, actor: "A. Berg", markupID: UUID(),
                markupSubject: "Slab", pageLabel: "1", commandName: command, note: note, changes: changes,
                markupName: "Area R-1"
            )
        }
        let sent = row("markup_modified", "Send to Back", [area, perimeter])
        #expect(HistoryPaneContent.detailText(sent) == "Send to Back")
        #expect(HistoryPaneContent.detailText(row("markup_modified", "Group", [area, perimeter])) == "Group")
        #expect(HistoryPaneContent.detailText(row("markup_modified", "Align Top", [area, perimeter])) == "Align Top")
        // A translation that moved the last bits of the computed area: the same at display
        // precision, so not a change a person can see.
        let drift = value("netArea", "Plan Area", "30.79", "30.790000000000003", "30,79 m²", "30,79 m²")
        #expect(HistoryPaneContent.detailText(row("markup_modified", "Move Markup", [drift, perimeter])) == "Move Markup")
        // Only what moved is listed.
        let grown = value("netArea", "Plan Area", "30.79", "41.2", "30,79 m²", "41,2 m²")
        #expect(HistoryPaneContent.detailText(row("markup_modified", "Edit Vertices", [grown, perimeter])) == "Plan Area 30,79 m² → 41,2 m²")
        let status = value("review.status", "Status", "open", "accepted", "Open", "Accepted")
        #expect(HistoryPaneContent.detailText(row("markup_modified", "Change Status", [area, perimeter, status])) == "Status Open → Accepted")
        // An undo of such a step names the step, not the compensation's bookkeeping note.
        let undone = row("compensated", "Send to Back", [area, perimeter], note: "compensates 6F1C")
        #expect(HistoryPaneContent.detailText(undone) == "Send to Back")
        // A creation still lists what was measured; a stamp's note still shows when it has no value.
        let measured = row("markup_created", "Measure Area", [value("netArea", "Plan Area", nil, "30.79", nil, "30,79 m²")])
        #expect(HistoryPaneContent.detailText(measured) == "Plan Area 30,79 m²")
        let stamp = row("markup_added", "Place Stamp", [], note: "Stamp: Approved")
        #expect(HistoryPaneContent.detailText(stamp) == "Stamp: Approved")
        // The pane shows the event's own detail, the one rule the AppCore test asserts on real rows.
        for event in [sent, undone, measured, stamp] {
            #expect(HistoryPaneContent.detailText(event) == event.historyDetail)
        }
    }

    // MARK: - L-84

    /// Old output: the window took the docked ledger's frame — 56 pt tall when folded to its bar,
    /// a little over 200 pt otherwise — and was centred over the project window's canvas.
    @Test("L-84: detaching opens the ledger at a size its side panels work in, beside the project window")
    func detachedWindowOpensAtAUsableSize() throws {
        let environment = Self.environment()
        let layout = ProjectWindowLayoutController(
            environment: environment,
            store: ProjectWindowLayoutStore(defaults: PanelSweepTests.CountingDefaults(), key: "l8.ledger.layout")
        )
        environment.layoutController = layout
        layout.presentDetachedLedgerWindow = { _ in }
        layout.detachedLedgerAutosaveName = ""
        _ = layout.view
        layout.detachQuantityLedger(persist: false)
        defer { layout.attachQuantityLedger() }
        let window = try #require(layout.detachedLedgerControllerForTesting?.window)
        let content = window.contentRect(forFrameRect: window.frame).size
        #expect(content.width >= LedgerDetachWindowController.minimumContentSize.width, "\(content)")
        #expect(content.height >= LedgerDetachWindowController.minimumContentSize.height, "\(content)")

        // Folded to its bar, the docked ledger's view is 56 pt tall; the window still opens whole.
        let folded = NSViewController()
        folded.view = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 56))
        let parent = CGRect(x: 0, y: 0, width: 1_440, height: 875)
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 875)
        let detached = LedgerDetachWindowController(
            contentViewController: folded, initialFrame: nil, autosaveName: "", parentFrame: parent, screenFrame: screen
        )
        let frame = try #require(detached.window?.frame)
        let foldedContent = try #require(detached.window?.contentRect(forFrameRect: frame).size)
        #expect(foldedContent.height >= LedgerDetachWindowController.minimumContentSize.height, "\(foldedContent)")
        // No room under a full-height project window: along its bottom edge, where the ledger
        // was docked, not centred over the canvas.
        #expect(frame.minY == parent.minY && frame.minX == parent.minX, "\(frame)")
        #expect(frame.midY < parent.midY, "the window sits low, not centred over the canvas")

        // Room under a smaller project window: under it.
        let small = CGRect(x: 200, y: 500, width: 1_000, height: 375)
        let under = LedgerDetachWindowController.firstFrame(size: CGSize(width: 900, height: 440), parent: small, screen: screen)
        #expect(under.maxY == small.minY && under.minX == small.minX, "\(under)")

        // A frame remembered from the old, too-short window grows back to the minimum.
        let remembered = LedgerDetachWindowController.enlarged(CGRect(x: 10, y: 10, width: 760, height: 200), toAtLeast: CGSize(width: 560, height: 348))
        #expect(remembered == CGRect(x: 10, y: -138, width: 760, height: 348))
    }

    /// Old output: the rule row needs about 440 pt on one line, so its value field started past
    /// the 340 pt panel's right edge, and the canvas choice read "Leave Uncha…".
    @Test("L-84: the filter panel's rule row and canvas choice fit the side panel")
    func filterPanelFitsTheSidePanel() throws {
        _ = NSApplication.shared
        let environment = Self.environment()
        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.fix2c2.tests")
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let model = LedgerPaneModel(presenter: environment.ledger, preferences: LedgerPanePreferences(defaults: defaults))
        model.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .pageLabel, comparison: .contains, operand: .text("1"))
        ]))
        let width = QuantityLedgerPane.sidePanelWidth
        let hosting = NSHostingView(rootView: QuantityLedgerPane.filterBuilder(for: model).frame(width: width, height: 640))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        Self.spin()

        let controls = Self.controls(in: hosting)
        let valueField = try #require(Self.editableTextFields(in: hosting).first, "the rule's value field")
        for control in controls {
            let frame = control.convert(control.bounds, to: hosting)
            #expect(frame.minX >= 0 && frame.maxX <= width + 0.5, "\(type(of: control)) at \(frame) runs off the \(width) pt panel")
        }
        #expect(valueField.convert(valueField.bounds, to: hosting).width >= 60, "the value field has room to type in")
        // Every canvas choice is a whole, clickable control: one radio button per choice, each
        // name drawn beside its button inside the panel.
        let radios = controls.filter { String(describing: type(of: $0.superview ?? $0)).contains("<Radio>") }
        #expect(radios.count == LedgerCanvasFilterBehavior.allCases.count, "\(radios.count) radio buttons")
        func allViews(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(allViews) }
        for view in allViews(hosting) where !(view is NSScroller) {
            let frame = view.convert(view.bounds, to: hosting)
            #expect(frame.maxX <= width + 0.5, "\(type(of: view)) at \(frame) runs off the \(width) pt panel")
        }
    }

    // MARK: - L-85

    /// Old output: the window opened with the docked ledger's height, the side panel's fields
    /// sat in a strip a few points tall, and a click at a field's middle landed on the pane
    /// behind it: the keyboard stayed where it was and the typed text went to the field typed
    /// into before.
    @Test("L-85: in the detached ledger one click puts the keyboard in a Bulk Edit field, and typing lands there")
    func bulkEditFieldsTakeTheKeyboardOnOneClick() throws {
        _ = NSApplication.shared
        let environment = Self.environment()
        let panelState = ShellPanelState()
        panelState.isLedgerDetached = true
        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.fix2c2.tests")
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let pane = QuantityLedgerPane(
            environment: environment, panelState: panelState,
            preferences: LedgerPanePreferences(defaults: defaults), sidePanel: .bulkEdit
        )
        let host = ZPDFPanelHostViewController(accessibilityLabel: "Quantity Ledger", rootView: pane)
        // The docked ledger, folded to its bar, as the live test detached it.
        host.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 56)
        let detached = LedgerDetachWindowController(contentViewController: host, initialFrame: nil, autosaveName: "")
        let window = try #require(detached.window)
        defer { window.contentViewController = nil }
        let first = try #require(environment.ledger.row(at: 0))
        environment.ledger.select(rowIDs: [first.markupID], additive: false)
        Self.spin(0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        Self.spin()

        let fields = Self.editableTextFields(in: host.view).sorted {
            $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY
        }
        try #require(fields.count >= 2, "the panel shows at least two text fields: \(fields.count)")
        let before = fields.map(\.stringValue)

        // A click at a field's middle reaches that field, for every field the panel shows.
        for field in fields {
            let middle = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
            let hit = window.contentView?.superview?.hitTest(middle)
            #expect(hit === field, "a click at \(middle) lands on \(String(describing: hit.map { type(of: $0) }))")
        }

        // Typing in the first field, then one click on the next: the keyboard follows the click
        // and the typed text lands in the clicked field, not in the one typed into before.
        Self.click(fields[0], in: window)
        #expect(Self.editingField(window) === fields[0], "one click puts the keyboard in the first field")
        (window.firstResponder as? NSTextView)?.insertText("R-100", replacementRange: NSRange(location: NSNotFound, length: 0))
        Self.spin()
        Self.click(fields[1], in: window)
        #expect(Self.editingField(window) === fields[1], "one click moves the keyboard to the next field")
        (window.firstResponder as? NSTextView)?.insertText("Roofing", replacementRange: NSRange(location: NSNotFound, length: 0))
        Self.spin()

        #expect(fields[0].stringValue.contains("R-100") && !fields[0].stringValue.contains("Roofing"), "\(fields[0].stringValue)")
        #expect(fields[1].stringValue.contains("Roofing"), "the text typed after the click went to the clicked field: \(fields[1].stringValue)")
        #expect(fields[1].stringValue != before[1])
    }

    /// The real pane, docked at `height`, opened on Bulk Edit with the first row selected, over
    /// `model` when the test already drove one. Returns the window and the panel's first field.
    static func dockedBulkEdit(
        _ environment: ProjectShellEnvironment,
        defaults: UserDefaults,
        height: CGFloat,
        model: LedgerPaneModel? = nil
    ) throws -> (window: NSWindow, host: NSViewController, firstField: NSTextField) {
        let pane = QuantityLedgerPane(
            environment: environment, panelState: ShellPanelState(),
            preferences: LedgerPanePreferences(defaults: defaults), sidePanel: .bulkEdit, model: model
        )
        let host = ZPDFPanelHostViewController(accessibilityLabel: "Quantity Ledger", rootView: pane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1_200, height: height))
        let first = try #require(environment.ledger.row(at: 0))
        environment.ledger.select(rowIDs: [first.markupID], additive: false)
        Self.spin(0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        Self.spin()
        let field = try #require(Self.editableTextFields(in: host.view).max {
            $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY
        }, "the panel's first text field")
        return (window, host, field)
    }

    /// Old output: in a docked ledger 150 pt tall the confirmation and the buttons kept their
    /// full height under the fields' scroll, which got no height at all, and a click on the first
    /// field landed on the pane behind it. Re-check: after an Apply, the outcome line sat under the
    /// panel, outside that scroll, and took its height from the fields again — at the docked
    /// ledger's 120 pt minimum the scroll was squeezed back to nothing.
    @Test("L-85: a short docked ledger keeps its Bulk Edit fields in reach, with an Apply's outcome showing too")
    func shortDockedPaneKeepsFieldsInReach() async throws {
        _ = NSApplication.shared
        let height = CGFloat(ProjectWindowLayoutState.minimumLedgerHeight)
        #expect(height == 120)

        // Without an outcome line.
        let plainEnvironment = Self.environment()
        let (plainDefaults, plainSuite) = try ShellScratchDefaults.make(prefix: "zenit.fix2c2.tests")
        defer { ShellScratchDefaults.discard(plainDefaults, suiteName: plainSuite) }
        let plain = try Self.dockedBulkEdit(plainEnvironment, defaults: plainDefaults, height: height)
        defer { plain.window.contentViewController = nil }
        let plainHit = Self.click(plain.firstField, in: plain.window)
        #expect(plainHit === plain.firstField, "a click on the first field lands on \(String(describing: plainHit.map { type(of: $0) }))")
        #expect(Self.editingField(plain.window) === plain.firstField)
        let plainViewport = try #require(plain.firstField.enclosingScrollView?.contentView.bounds.height)

        // With the outcome of an Apply showing: the panel's own Apply, through the pane's model.
        let environment = Self.environment()
        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.fix2c2.tests")
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let model = LedgerPaneModel(presenter: environment.ledger, preferences: LedgerPanePreferences(defaults: defaults))
        let applied = try Self.dockedBulkEdit(environment, defaults: defaults, height: height, model: model)
        defer { applied.window.contentViewController = nil }
        try #require(!model.bulkEdit.rows.isEmpty, "the panel holds the selected row")
        model.bulkEdit.setEdit(.text("Roof area"), for: .label)
        model.bulkEdit.apply()
        for _ in 0..<200 where model.lastBulkEditReceipt == nil { await Task.yield() }
        try #require(model.lastBulkEditReceipt != nil, "the Apply produced an outcome line")
        Self.spin(0.3)
        applied.window.contentView?.layoutSubtreeIfNeeded()
        Self.spin()
        #expect(model.lastBulkEditReceipt != nil, "the outcome line is still showing")

        // The outcome line lives inside the fields' scroll, so the fields keep the same viewport.
        let field = try #require(Self.editableTextFields(in: applied.host.view).max {
            $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY
        }, "the panel's first text field, after the Apply")
        let viewport = try #require(field.enclosingScrollView?.contentView.bounds.height)
        #expect(viewport >= plainViewport - 0.5, "the outcome line took \(plainViewport - viewport) pt from the fields' scroll (\(viewport) of \(plainViewport))")
        #expect(viewport >= field.bounds.height, "the fields' scroll shows at least one whole field: \(viewport) pt")
        let hit = Self.click(field, in: applied.window)
        #expect(hit === field, "a click on the first field lands on \(String(describing: hit.map { type(of: $0) }))")
        #expect(Self.editingField(applied.window) === field)
    }

    /// Old output: the row menu's Change Status ran as if from the Bulk Edit panel, so the panel
    /// then opened saying "Changed 3 markups. One Undo takes the whole change back." for a change
    /// made somewhere else.
    @Test("L-85: a status set from the ledger's row menu leaves no outcome line under the Bulk Edit panel")
    func rowMenuStatusLeavesNoPanelOutcome() async throws {
        let environment = Self.environment()
        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.fix2c2.tests")
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let model = LedgerPaneModel(presenter: environment.ledger, preferences: LedgerPanePreferences(defaults: defaults))
        model.host.controller.loadViewIfNeeded()
        let rows = (0..<environment.ledger.rowCount).compactMap { environment.ledger.row(at: $0) }.filter { !$0.locked }
        let chosen = Array(rows.prefix(3))
        try #require(chosen.count == 3)
        let status = try #require(model.rowMenuStatuses.last { choice in
            chosen.contains { $0.values[.status] != .choice(choice.value) }
        }, "a status at least one row does not already have")

        model.performRowMenuAction(.setStatus(status.value), rows: Set(chosen.map(\.markupID)), environment: environment, explain: nil)
        func applied() -> Bool {
            chosen.allSatisfy { row in
                (0..<environment.ledger.rowCount).compactMap { environment.ledger.row(at: $0) }
                    .first { $0.markupID == row.markupID }?.values[.status] == .choice(status.value)
            }
        }
        for _ in 0..<200 where !applied() { await Task.yield() }
        #expect(applied(), "the row menu set the status")
        // Long enough for the apply's task to have finished and stored a receipt, if it would.
        for _ in 0..<200 { await Task.yield() }
        #expect(model.lastBulkEditReceipt == nil, "the Bulk Edit panel has no outcome for a change made from the row menu")
        #expect(model.paneNotice == nil)
    }

    /// Old output: an inline label edit left "Changed 1 markup(s). One Undo takes the whole
    /// change back." waiting under the Bulk Edit panel, which then opened saying it.
    @Test("L-85: the Bulk Edit outcome line is the panel's own, follows the selection, and agrees in number")
    func bulkEditOutcomeLine() async throws {
        let environment = Self.environment()
        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.fix2c2.tests")
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let model = LedgerPaneModel(presenter: environment.ledger, preferences: LedgerPanePreferences(defaults: defaults))
        model.host.controller.loadViewIfNeeded()
        let rows = (0..<environment.ledger.rowCount).compactMap { environment.ledger.row(at: $0) }.filter { !$0.locked }
        let first = try #require(rows.first)
        let second = try #require(rows.dropFirst().first)

        model.applyExternalSelection([first.markupID])
        model.bulkEdit.setEdit(.text("Roof area"), for: .label)
        model.bulkEdit.apply()
        for _ in 0..<200 where model.lastBulkEditReceipt == nil { await Task.yield() }
        let receipt = try #require(model.lastBulkEditReceipt)
        #expect(QuantityLedgerPane.bulkEditSuccessText(receipt) == "Changed 1 markup. One Undo takes the whole change back.")

        // Another selection is another edit: the old outcome goes.
        model.applyExternalSelection([second.markupID])
        #expect(model.lastBulkEditReceipt == nil)
    }
}
