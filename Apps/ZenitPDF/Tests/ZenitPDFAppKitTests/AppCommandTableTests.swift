import AppKit
import Testing
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// IM-183: every application command is described once, in ``ZenitAppCommandTable``, and the
/// menu bar, validation and dispatch all read that entry.
///
/// Old: each ``ZenitAppCommand`` kept its title and shortcut in `ZenitMenuBar`, its enablement in
/// a switch in `ProjectWindowController.validateMenuItem` and its action in a switch in
/// `perform(app:)`. These tests pin the table's invariants; the expected enablement below is
/// written out from the old switch, independently of the table, so a rule that drifts fails.
@MainActor
@Suite(.appTierSerialised)
struct AppCommandTableTests {

    // MARK: - Helpers

    /// Every row of the built bar, with the path of menu titles that leads to it.
    private func rows(of bar: NSMenu) -> [(path: [String], item: NSMenuItem)] {
        var found: [(path: [String], item: NSMenuItem)] = []
        func walk(_ menu: NSMenu, path: [String]) {
            for item in menu.items {
                found.append((path, item))
                if let submenu = item.submenu { walk(submenu, path: path + [submenu.title]) }
            }
        }
        walk(bar, path: [])
        return found
    }

    private func appCommand(of item: NSMenuItem) -> ZenitAppCommand? {
        (item.representedObject as? String).flatMap(ZenitAppCommand.init(rawValue:))
    }

    // MARK: - The table

    @Test("The table holds exactly one entry per command, in declaration order")
    func oneEntryPerCommand() {
        #expect(ZenitAppCommandTable.specs.map(\.command) == ZenitAppCommand.allCases)
        for command in ZenitAppCommand.allCases {
            let spec = ZenitAppCommandTable.spec(for: command)
            #expect(spec.command == command)
            #expect(!spec.title.isEmpty, "\(command) has no title")
        }
    }

    @Test("Each slot lists its commands in the order the menus showed them")
    func slotOrder() {
        func slot(_ slot: ZenitAppCommandSlot) -> [ZenitAppCommand] {
            ZenitAppCommandTable.specs(in: slot).map(\.command)
        }
        #expect(slot(.fileAfterSaveAs) == [.createProject, .saveMarkupsIntoPDF])
        // nl-collaboration: the review import and the three Shared Review commands follow Send.
        #expect(slot(.fileAfterExport) == [.importLedgerJSON, .exportMeasurementOverlay, .importMeasurementOverlay, .importSpreadsheetChanges, .sendProject, .shareLastExport, .saveExportProfile, .exportWithProfile, .exportSnippet, .shareSnippet, .createPDFFromDocuments, .setUpPrintToZenit])
        // L-02: the review-exchange family in File ▸ Review.
        #expect(slot(.fileReview) == [.importReviewAnnotations, .connectSharedReview, .syncSharedReview, .disconnectSharedReview, .exportReviewFile, .importReviewFile, .shareReviewFile, .exportXFDF, .importXFDF])
        // L-03: the Navigator's five drawing-set actions in File ▸ Drawing Set, in its order.
        // L-57/L-93: Add Revision… joins them, before the report that needs a revision.
        #expect(slot(.fileDrawingSet) == [.exportArrangedSet, .linkSheetReferences, .addRevision, .setCompareReport, .splitIntoSheets, .combineOpenDrawings])
        #expect(slot(.fileExportDrawing) == [.exportFlattenedPDF, .exportAnnotatedPDF, .exportCleanPDF, .exportLayeredPDF, .optimizeCopy, .saveSearchableCopy, .signDrawingCopy])
        #expect(slot(.editAfterCopy) == [.copySnippet, .pasteInPlace, .duplicateMarkups, .pasteToPages])
        #expect(slot(.editSelection) == [.toggleLockSelection, .hideSelection, .showHiddenMarkups, .selectSameSubject, .selectSameKind, .selectAllInDocument, .copyStyle, .pasteStyle])
        #expect(slot(.toolsCapture) == [.readScannedText, .batchApply, .snippetRegion, .batchHeaderFooter, .newSignatureStamp, .cleanUpScans, .processPDFFiles, .stopProcessingPDFFiles])
        // L-02: Tools ▸ Redaction.
        #expect(slot(.toolsRedaction) == [.markRedaction, .applyRedactions, .clearRedactionMarks])
        // nl-automation: Name Sheets from Title Block sits with the other drawing-data reads.
        #expect(slot(.toolsDrawingData) == [.importTableFromDrawing, .nameSheetsFromTitleBlock, .makeDrawingAnnotationsEditable, .fillFormFields])
        #expect(slot(.toolsJobTemplates) == [.saveJobTemplate, .applyJobTemplate, .exportJobTemplate, .importJobTemplate])
        // r2-platform: New from Template… under New; packs after the Job Templates submenu.
        // NL-DOCS-15: the folder index follows New from Template….
        #expect(slot(.fileAfterNew) == [.newFromTemplate])
        // L-02: File ▸ Indexed Drawings.
        #expect(slot(.fileIndexedDrawings) == [.indexDrawingFolder, .searchDrawingFolder, .forgetDrawingFolder])
        #expect(slot(.toolsLibrary) == [.installPack, .createPack])
        // nl-automation: the trace options, the library search and the geometry search follow the
        // symbol schedule.
        #expect(slot(.measure) == [.calibrateScale, .applyScaleToPages, .pageScales, .findScaleRegions, .verifyScale, .splitArea, .continueMeasurement, .mergeAreas, .numberCountMarks, .precisionMagnifier, .recalculateStale, .drawFenceLine, .clearFenceLines, .curveEdge])
        // L-02: Measure ▸ Automation — the checks, the detectors and the Takeoff Assistant.
        #expect(slot(.measureAutomation) == [.checkDrawnDimensions, .createSymbolSchedule, .autoTraceOptions, .findLibrarySymbols, .findGeometry, .detectRooms, .findWalls, .findRepeatedSheets, .prepareSet, .assistantInbox])
        // NL-UX-20: New Window for Project heads the Window menu's document block.
        #expect(slot(.windowTabs) == [.newWindowForProject, .showNextTab, .showPreviousTab])
        // nl-collaboration: the Review List and author tint sit above the command palette.
        #expect(slot(.viewExtras) == [.reviewList, .tintByAuthor, .commandPalette])
        // r2-markup: group, link, image; Arrange and Align submenus.
        #expect(slot(.editGroup) == [.groupMarkups, .ungroupMarkups, .editMarkupLink, .insertImage])
        #expect(slot(.editArrange) == [.bringToFront, .bringForward, .sendBackward, .sendToBack])
        #expect(slot(.editAlign) == [.alignLeft, .alignCentres, .alignRight, .alignTop, .alignMiddles, .alignBottom, .distributeHorizontally, .distributeVertically, .makeSameWidth, .makeSameHeight])
        let placed = ZenitAppCommandSlot.allCases.flatMap(slot)
        #expect(placed.count == ZenitAppCommand.allCases.count, "a command sits in no slot, or in two")
    }

    // MARK: - The menu bar reads the table

    @Test("Every table command appears in the bar exactly once, with its title, key equivalent and tooltip")
    func everyCommandIsInTheBarOnce() throws {
        let rows = rows(of: ZenitMenuBar.make())
        for spec in ZenitAppCommandTable.specs {
            let visible = rows.filter { appCommand(of: $0.item) == spec.command && !$0.item.isHidden }
            try #require(visible.count == 1, "\(spec.command) has \(visible.count) visible rows")
            let item = visible[0].item
            #expect(item.title == spec.title)
            #expect(item.action == #selector(ZenitCommandResponding.performZenitCommand(_:)))
            #expect(item.toolTip == spec.toolTip)
            if let chord = spec.keyEquivalent {
                #expect(item.keyEquivalent == chord.key, "\(spec.command)'s shortcut is not on its row")
                #expect(item.keyEquivalentModifierMask == chord.modifiers)
            } else {
                #expect(item.keyEquivalent.isEmpty, "\(spec.command) carries a shortcut the table does not give it")
            }
            // Each further chord is one hidden twin that still answers its key.
            let hidden = rows.filter { appCommand(of: $0.item) == spec.command && $0.item.isHidden }
            #expect(hidden.count == spec.hiddenKeyEquivalents.count)
            for chord in spec.hiddenKeyEquivalents {
                let twin = hidden.filter {
                    $0.item.keyEquivalent == chord.key && $0.item.keyEquivalentModifierMask == chord.modifiers
                }
                #expect(twin.count == 1, "\(spec.command) has no hidden row for \(chord.key.debugDescription)")
                #expect(twin.first?.item.allowsKeyEquivalentWhenHidden == true)
            }
        }
        // No row carries an application command the table does not know.
        let unknown = rows.filter {
            ($0.item.representedObject as? String)?.hasPrefix("zenit.app.") == true && appCommand(of: $0.item) == nil
        }
        #expect(unknown.isEmpty)
    }

    @Test("Each row sits in the menu, and submenu, its slot names")
    func rowsSitInTheirSlotsMenu() throws {
        let rows = rows(of: ZenitMenuBar.make())
        for spec in ZenitAppCommandTable.specs {
            let row = try #require(rows.first { appCommand(of: $0.item) == spec.command && !$0.item.isHidden })
            let menuTitle = spec.slot.group?.displayName
                ?? NSLocalizedString("Window", comment: "Menu bar title")
            var expected = [menuTitle]
            if let submenu = spec.slot.submenuTitle { expected.append(submenu) }
            #expect(row.path == expected, "\(spec.command) is under \(row.path), not \(expected)")
        }
    }

    @Test("A table shortcut never collides with another row's key equivalent in the bar")
    func noShortcutCollisions() {
        let rows = rows(of: ZenitMenuBar.make())
        for spec in ZenitAppCommandTable.specs {
            for chord in [spec.keyEquivalent].compactMap({ $0 }) + spec.hiddenKeyEquivalents {
                let holders = rows.filter {
                    $0.item.keyEquivalent == chord.key
                        && $0.item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                            == chord.modifiers.intersection(.deviceIndependentFlagsMask)
                }
                #expect(holders.count == 1, "\(spec.command)'s \(chord.key.debugDescription) is held by \(holders.count) rows")
            }
        }
    }

    // MARK: - Validation reads the table

    /// A window state with every property set by hand.
    private struct State: ZenitAppCommandState {
        var hasActiveDocument = false
        var isQuickPDF = false
        var hasDrawing = false
        var hasSearchIndex = false
        var hasLoadedCore = false
        var hasPagesAndStampPreset = false
        var hasMarkupSelection = false
        var selectionIsLocked = false
        var hasHiddenMarkups = false
        var tabCount = 0
        var isSaveActivityBusy = false
        var isBatchProcessing = false
    }

    /// The old `validateMenuItem` switch, written out by hand as the oracle.
    private func oldEnablement(_ command: ZenitAppCommand, _ s: State) -> Bool {
        switch command {
        case .createProject: return !s.isSaveActivityBusy && s.isQuickPDF && s.hasDrawing
        case .calibrateScale, .applyScaleToPages, .pageScales, .findScaleRegions, .verifyScale, .precisionMagnifier, .recalculateStale, .drawFenceLine, .clearFenceLines: return s.hasDrawing
        case .readScannedText: return s.hasSearchIndex
        case .importLedgerJSON: return true
        case .exportMeasurementOverlay, .importMeasurementOverlay: return s.hasDrawing
        case .importSpreadsheetChanges: return s.hasLoadedCore
        // U-022: Send Project posts its refusal to the takeoff, so a project still opening has
        // nowhere to say it; the row waits for the loaded takeoff, as T-018 did for others.
        case .sendProject: return s.hasLoadedCore
        // r2-platform: Share Last Export acts on the document in front; New from Template and
        // the pack commands need nothing open. T-018: Share Last Export, the Review List and the
        // palette need the loaded takeoff — while a drawing opened they were enabled and did
        // nothing.
        case .shareLastExport: return s.hasLoadedCore
        case .newFromTemplate, .installPack, .createPack: return true
        // NL-DOCS-15: the folder index works on files that are not open.
        case .indexDrawingFolder, .searchDrawingFolder, .forgetDrawingFolder: return true
        // r2-platform, NL-AUTO-20/21/16: the sheet's geometry; the inbox needs the takeoff core.
        case .findWalls, .findRepeatedSheets, .prepareSet: return s.hasDrawing
        case .assistantInbox: return s.hasLoadedCore
        case .saveExportProfile, .exportWithProfile: return s.hasLoadedCore
        // nl-collaboration, NL-COLLAB-08: a reviewer's annotations need the drawing they were made on.
        case .importReviewAnnotations: return s.hasDrawing
        // NL-COLLAB-12: the shared review commands act on the drawing in front. Connect explains
        // its refusal on a Quick PDF; Sync, Disconnect and Share Review File did nothing there,
        // so they need a project (R-029).
        case .connectSharedReview: return s.hasDrawing
        case .syncSharedReview, .disconnectSharedReview: return !s.isQuickPDF && s.hasDrawing
        case .exportReviewFile, .importReviewFile, .exportXFDF, .importXFDF: return s.hasDrawing
        case .shareReviewFile: return !s.isQuickPDF && s.hasDrawing
        // NL-COLLAB-04: the Review List needs a document tab in front.
        case .reviewList: return s.hasLoadedCore
        case .tintByAuthor: return s.hasDrawing
        case .batchApply: return s.hasPagesAndStampPreset
        case .copySnippet, .exportSnippet: return s.hasMarkupSelection
        // r2-pdf, NL-PDF-21: the shelf is of the selection too.
        case .shareSnippet: return s.hasMarkupSelection
        // r2-pdf, NL-PDF-18: making a PDF needs nothing open.
        case .createPDFFromDocuments, .setUpPrintToZenit: return true
        case .pasteInPlace, .pasteToPages: return s.hasLoadedCore
        case .duplicateMarkups: return s.hasMarkupSelection
        case .snippetRegion: return s.hasDrawing
        case .exportFlattenedPDF, .exportAnnotatedPDF, .exportCleanPDF, .exportLayeredPDF: return s.hasDrawing
        case .optimizeCopy, .saveMarkupsIntoPDF, .signDrawingCopy: return s.hasDrawing
        case .saveSearchableCopy: return s.hasSearchIndex
        case .batchHeaderFooter: return s.hasLoadedCore
        // r2-pdf, NL-PDF-22: the stamp joins the takeoff's library.
        case .newSignatureStamp: return s.hasLoadedCore
        // r2-pdf, NL-PDF-12: clean-up reads the drawing.
        case .cleanUpScans: return s.hasDrawing
        // r2-pdf, NL-PDF-14: redaction marks belong to a drawing.
        case .markRedaction, .applyRedactions, .clearRedactionMarks: return s.hasDrawing
        // r2-pdf, NL-PDF-17: the form is the drawing's own.
        case .fillFormFields: return s.hasDrawing
        // r2-pdf, NL-PDF-19: a batch works on files that are not open. Stop is enabled only
        // while a run is in progress (R-023).
        case .processPDFFiles: return true
        case .stopProcessingPDFFiles: return s.isBatchProcessing
        case .saveJobTemplate, .applyJobTemplate: return s.hasLoadedCore
        // U-023: the template library is per-user, so Export and Import Job Template need
        // nothing open, as Install Pack and Create Pack do.
        case .exportJobTemplate, .importJobTemplate: return true
        case .showNextTab, .showPreviousTab: return s.tabCount > 1
        // NL-UX-20: a second window needs the document's takeoff core to share.
        case .newWindowForProject: return s.hasLoadedCore
        case .toggleLockSelection, .hideSelection: return s.hasMarkupSelection
        case .showHiddenMarkups: return s.hasHiddenMarkups
        case .splitArea, .continueMeasurement, .mergeAreas, .numberCountMarks, .curveEdge: return s.hasMarkupSelection
        case .checkDrawnDimensions, .importTableFromDrawing, .createSymbolSchedule: return s.hasDrawing
        // nl-automation, NL-AUTO-11: the trace options belong to a drawing.
        case .autoTraceOptions, .findLibrarySymbols, .findGeometry, .detectRooms, .nameSheetsFromTitleBlock: return s.hasDrawing
        // nl-ux, NL-UX-05: the palette needs a document tab in front.
        case .commandPalette: return s.hasLoadedCore
        case .makeDrawingAnnotationsEditable: return s.hasDrawing
        case .selectSameSubject, .selectSameKind: return s.hasMarkupSelection
        case .selectAllInDocument: return s.hasLoadedCore
        case .copyStyle, .pasteStyle: return s.hasMarkupSelection
        // r2-markup: every round-2 verb acts on the selection; Insert Image on the drawing.
        case .groupMarkups, .ungroupMarkups, .editMarkupLink,
             .bringToFront, .bringForward, .sendBackward, .sendToBack,
             .alignLeft, .alignCentres, .alignRight, .alignTop, .alignMiddles, .alignBottom,
             .distributeHorizontally, .distributeVertically, .makeSameWidth, .makeSameHeight:
            return s.hasMarkupSelection
        case .insertImage: return s.hasDrawing
        // L-03: the drawing-set actions; each flow says what it cannot do (no earlier revision,
        // no project to combine into). Combine needs another drawing open.
        case .exportArrangedSet, .setCompareReport, .splitIntoSheets: return s.hasDrawing
        // L-57/L-93: a revision is added to a drawing.
        case .addRevision: return s.hasDrawing
        case .linkSheetReferences: return s.hasLoadedCore
        // L-40: and a drawing to combine into — never the empty untitled start document.
        case .combineOpenDrawings: return s.hasDrawing && s.tabCount > 1
        }
    }

    /// Every combination of the state's flags, with one and two tabs.
    private func allStates() -> [State] {
        var states: [State] = []
        for mask in 0..<(1 << 11) {
            for tabs in [1, 2] {
                func bit(_ index: Int) -> Bool { mask & (1 << index) != 0 }
                states.append(State(
                    hasActiveDocument: bit(0), isQuickPDF: bit(1), hasDrawing: bit(2),
                    hasSearchIndex: bit(3), hasLoadedCore: bit(4), hasPagesAndStampPreset: bit(5),
                    hasMarkupSelection: bit(6), selectionIsLocked: bit(7), hasHiddenMarkups: bit(8),
                    tabCount: tabs, isSaveActivityBusy: bit(9), isBatchProcessing: bit(10)
                ))
            }
        }
        return states
    }

    @Test("Validation covers every table entry and answers exactly as the old switch did, in every state")
    func validationMatchesTheOldRules() {
        let states = allStates()
        for command in ZenitAppCommand.allCases {
            var mismatches = 0
            for state in states where ZenitAppCommandTable.validate(command, item: nil, state: state)
                != oldEnablement(command, state) {
                mismatches += 1
            }
            #expect(mismatches == 0, "\(command) differs from the old rule in \(mismatches) states")
        }
    }

    @Test("Only Create Project is shut by a running save")
    func saveActivityDoor() {
        let ready = State(
            hasActiveDocument: true, isQuickPDF: true, hasDrawing: true, hasSearchIndex: true,
            hasLoadedCore: true, hasPagesAndStampPreset: true, hasMarkupSelection: true,
            hasHiddenMarkups: true, tabCount: 2, isBatchProcessing: true
        )
        // Create Project needs a Quick PDF and the shared-review rows a project (R-029), so no
        // one state enables every row: each command is checked in whichever of the two does.
        var project = ready
        project.isQuickPDF = false
        for command in ZenitAppCommand.allCases {
            let base = ZenitAppCommandTable.validate(command, item: nil, state: ready) ? ready : project
            #expect(ZenitAppCommandTable.validate(command, item: nil, state: base), "\(command) should be enabled")
            var busy = base
            busy.isSaveActivityBusy = true
            #expect(
                ZenitAppCommandTable.validate(command, item: nil, state: busy) == (command != .createProject),
                "\(command) answers wrongly while a save runs"
            )
        }
        #expect(ZenitAppCommandTable.specs.filter(\.refusedWhileSaving).map(\.command) == [.createProject])
    }

    @Test("The Lock row says Unlock over a locked selection, and names what it would do while disabled")
    func lockTitleFollowsTheSelection() {
        let item = NSMenuItem(title: "Lock Selection", action: nil, keyEquivalent: "")
        var state = State(hasActiveDocument: true, hasLoadedCore: true, hasMarkupSelection: true, selectionIsLocked: true)
        #expect(ZenitAppCommandTable.validate(.toggleLockSelection, item: item, state: state))
        #expect(item.title == "Unlock Selection")
        state.selectionIsLocked = false
        #expect(ZenitAppCommandTable.validate(.toggleLockSelection, item: item, state: state))
        #expect(item.title == "Lock Selection")

        // Disabled: the row still names what it would do now (V-025). The old guard-then-rename
        // left "Unlock Selection" on a row disabled by deselecting a locked selection.
        item.title = "Unlock Selection"
        state.hasMarkupSelection = false
        #expect(!ZenitAppCommandTable.validate(.toggleLockSelection, item: item, state: state))
        #expect(item.title == "Lock Selection")

        // No other command renames its row, except the precision magnifier's Show / Hide
        // (r2-measure, NL-MEASURE-15), which follows a preference rather than the selection.
        let titled = ZenitAppCommandTable.specs.filter { $0.stateTitle != nil }.map(\.command)
        #expect(Set(titled) == [.toggleLockSelection, .precisionMagnifier])
    }

    // MARK: - Dispatch reads the table

    @Test("Dispatch covers every table entry; only Import Zenit JSON and the file-level PDF commands run with no document in front")
    func dispatchCoversEveryEntry() {
        // r2-pdf, NL-PDF-18: New PDF from Documents and Set Up "Print to Zenit PDF" make a PDF
        // rather than act on one.
        // r2-platform: New from Template… and the two pack commands work with no document too.
        let documentFree: Set<ZenitAppCommand> = [.importLedgerJSON, .createPDFFromDocuments, .setUpPrintToZenit, .processPDFFiles, .stopProcessingPDFFiles,
                                                  .newFromTemplate, .installPack, .createPack,
                                                  .indexDrawingFolder, .searchDrawingFolder, .forgetDrawingFolder,
                                                  // U-023: the job-template file rows work on the per-user library.
                                                  .exportJobTemplate, .importJobTemplate]
        for spec in ZenitAppCommandTable.specs {
            #expect(spec.action.needsDocument == !documentFree.contains(spec.command), "\(spec.command)")
        }
    }

    // MARK: - The document's own rows

    @Test("The document action table holds the document's selectors, in its order")
    func documentActionTableMatchesTheDocument() {
        // Drift guard until ZenitPDFProjectDocument delegates to the table.
        #expect(ZenitDocumentActionTable.saveActivityActions == ZenitPDFProjectDocument.saveActivityActions)
        #expect(ZenitDocumentActionTable.revertActions == ZenitPDFProjectDocument.revertActions)
        #expect(ZenitDocumentActionTable.saveActivityActions.count == 8)
    }

    @Test("The document action rules answer as the document's validateUserInterfaceItem did")
    func documentActionRules() {
        func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }
        typealias Rules = ZenitDocumentActionTable

        // Revert and Browse Versions are refused while a session exists (BH-355).
        for action in [#selector(NSDocument.revertToSaved(_:)), #selector(NSDocument.browseVersions(_:))] {
            #expect(Rules.validate(item(action), hasSession: true, isSaveActivityBusy: false, hasDrawing: true) == false)
        }
        #expect(Rules.validate(item(#selector(NSDocument.browseVersions(_:))), hasSession: false, isSaveActivityBusy: true, hasDrawing: false) == nil)

        // The save-activity doors: refused while a save runs, with the reason in the tooltip
        // (CR-147, IM-177), refused with nothing loaded (CR-161), otherwise AppKit decides.
        for action in Rules.saveActivityActions {
            let busy = item(action)
            #expect(Rules.validate(busy, hasSession: false, isSaveActivityBusy: true, hasDrawing: true) == false)
            #expect(busy.toolTip == "Saving… available when the save finishes")
            let empty = item(action)
            empty.toolTip = "stale"
            #expect(Rules.validate(empty, hasSession: false, isSaveActivityBusy: false, hasDrawing: false) == false)
            #expect(empty.toolTip == nil, "the reason is cleared when the save is over")
            #expect(Rules.validate(item(action), hasSession: false, isSaveActivityBusy: false, hasDrawing: true) == nil)
        }

        // A row the table has no rule for reads none of the document's state.
        var reads = 0
        func probe() -> Bool { reads += 1; return true }
        #expect(Rules.validate(item(#selector(NSText.copy(_:))), hasSession: probe(), isSaveActivityBusy: probe(), hasDrawing: probe()) == nil)
        #expect(reads == 0)
    }
}
