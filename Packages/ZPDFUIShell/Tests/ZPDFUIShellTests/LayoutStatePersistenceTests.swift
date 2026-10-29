import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Asserts that a project window's layout survives a relaunch, and that nothing a corrupted or
/// out-of-range defaults entry can contain is able to leave a pane the user cannot recover.
@MainActor
@Suite("Layout state persistence", .shellTierSerialised)
struct LayoutStatePersistenceTests {

    private func makeStore() -> (ProjectWindowLayoutStore, ZPDFInMemoryDefaults) {
        let defaults = ZPDFInMemoryDefaults()
        return (ProjectWindowLayoutStore(defaults: defaults, key: "test.layout"), defaults)
    }

    @Test("An unwritten store loads the shipped default")
    func loadsDefaultWhenNothingStored() {
        let (store, defaults) = makeStore()
        #expect(defaults.isEmpty)
        #expect(store.load() == ProjectWindowLayoutState.default)
    }

    @Test("Every persisted field round-trips")
    func roundTripsEveryField() {
        let (store, _) = makeStore()
        let presetID = UUID()
        let state = ProjectWindowLayoutState(
            navigatorWidth: 312,
            inspectorWidth: 420,
            ledgerHeight: 288,
            isNavigatorCollapsed: false,
            isInspectorCollapsed: true,
            isLedgerCollapsed: true,
            isLedgerBarCollapsed: false,
            isLedgerDetached: false,
            detachedLedgerFrame: ZPDFWindowFrame(x: 120, y: 200, width: 820, height: 340),
            navigatorSection: .zones,
            expandedInspectorSections: [.measurement, .customData],
            lastUsedMeasurementKind: .wallArea,
            lastUsedCountPresetID: presetID
        )
        #expect(store.save(state))

        let loaded = store.load()
        #expect(loaded.navigatorWidth == 312)
        #expect(loaded.inspectorWidth == 420)
        #expect(loaded.ledgerHeight == 288)
        #expect(loaded.isInspectorCollapsed)
        #expect(loaded.isLedgerCollapsed)
        #expect(loaded.navigatorSection == .zones)
        #expect(loaded.expandedInspectorSections == [.measurement, .customData])
        #expect(loaded.lastUsedMeasurementKind == .wallArea)
        #expect(loaded.lastUsedCountPresetID == presetID)
        #expect(loaded.detachedLedgerFrame?.width == 820)
        #expect(loaded == state.normalized())
    }

    @Test("The bar-collapsed ledger state round-trips")
    func roundTripsLedgerBarCollapse() {
        let (store, _) = makeStore()
        store.save(ProjectWindowLayoutState(ledgerHeight: 300, isLedgerBarCollapsed: true))
        let loaded = store.load()
        #expect(loaded.isLedgerBarCollapsed)
        // The height the pane restores to survives the collapse.
        #expect(loaded.ledgerHeight == 300)
    }

    @Test("A detached ledger is never also bar-collapsed")
    func detachedLedgerIsNotBarCollapsed() {
        let state = ProjectWindowLayoutState(
            isLedgerBarCollapsed: true,
            isLedgerDetached: true
        ).normalized()
        #expect(state.isLedgerDetached)
        #expect(!state.isLedgerBarCollapsed)
    }

    @Test("A fully hidden ledger is never also bar-collapsed")
    func hiddenLedgerIsNotBarCollapsed() {
        let state = ProjectWindowLayoutState(
            isLedgerCollapsed: true,
            isLedgerBarCollapsed: true
        ).normalized()
        #expect(state.isLedgerCollapsed)
        #expect(!state.isLedgerBarCollapsed)
    }

    @Test("A version-1 blob resolves to the shipped default, not to a half-read layout")
    func schemaOneBlobLoadsDefault() {
        // A stored layout from before `isLedgerBarCollapsed` existed and while the Navigator
        // still had a Bookmarks page. It must not decode halfway.
        let v1JSON = """
        {"schemaVersion":1,"navigatorWidth":300,"inspectorWidth":320,"ledgerHeight":200,\
        "isNavigatorCollapsed":false,"isInspectorCollapsed":false,"isLedgerCollapsed":false,\
        "isLedgerDetached":false,"navigatorSection":"bookmarks",\
        "expandedInspectorSections":["measurement"]}
        """
        let defaults = ZPDFInMemoryDefaults()
        defaults.setPersistedData(Data(v1JSON.utf8), forKey: "test.layout")
        let store = ProjectWindowLayoutStore(defaults: defaults, key: "test.layout")
        #expect(store.load() == ProjectWindowLayoutState.default)
    }

    @Test("Out-of-range pane sizes are clamped, not restored")
    func clampsOutOfRangeSizes() {
        let (store, _) = makeStore()
        store.save(
            ProjectWindowLayoutState(
                navigatorWidth: 4,
                inspectorWidth: 9_000,
                ledgerHeight: -50
            )
        )
        let loaded = store.load()
        #expect(loaded.navigatorWidth == ProjectWindowLayoutState.minimumNavigatorWidth)
        #expect(loaded.inspectorWidth == ProjectWindowLayoutState.maximumInspectorWidth)
        #expect(loaded.ledgerHeight == ProjectWindowLayoutState.minimumLedgerHeight)
    }

    @Test("A non-finite width falls back to the shipped default rather than clamping")
    func rejectsNonFiniteSizes() {
        let state = ProjectWindowLayoutState(navigatorWidth: .nan).normalized()
        #expect(state.navigatorWidth == ProjectWindowLayoutState.default.navigatorWidth)
    }

    @Test("A detached ledger is never also recorded as collapsed in the dock")
    func detachedLedgerIsNotCollapsed() {
        let state = ProjectWindowLayoutState(
            isLedgerCollapsed: true,
            isLedgerDetached: true
        ).normalized()
        #expect(state.isLedgerDetached)
        #expect(!state.isLedgerCollapsed)
    }

    @Test("An unusably small detached frame is discarded so the window re-centres")
    func discardsUnusableDetachedFrame() {
        let state = ProjectWindowLayoutState(
            detachedLedgerFrame: ZPDFWindowFrame(x: 0, y: 0, width: 40, height: 20)
        ).normalized()
        #expect(state.detachedLedgerFrame == nil)
    }

    /// U-047: this test used to pin the opposite — an empty set normalized back to the shipped
    /// set — which is what reopened a section the person had just collapsed on every tab switch
    /// and relaunch. An empty set is the person's choice and is kept; a missing value still
    /// loads the shipped set through the decode fallback (`survivesCorruptData`).
    @Test("An empty Inspector section set is kept through normalized() and a save/load round trip")
    func keepsAnEmptyInspectorSectionSet() {
        let state = ProjectWindowLayoutState(expandedInspectorSections: []).normalized()
        #expect(state.expandedInspectorSections.isEmpty)
        let defaults = ZPDFInMemoryDefaults()
        let store = ProjectWindowLayoutStore(defaults: defaults, key: "test.layout")
        store.save(state)
        #expect(store.load().expandedInspectorSections.isEmpty)
    }

    @Test("Corrupt stored data loads the default instead of failing")
    func survivesCorruptData() {
        let defaults = ZPDFInMemoryDefaults()
        defaults.setPersistedData(Data("not json".utf8), forKey: "test.layout")
        let store = ProjectWindowLayoutStore(defaults: defaults, key: "test.layout")
        #expect(store.load() == ProjectWindowLayoutState.default)
    }

    @Test("State written by a newer schema is ignored rather than half-read")
    func ignoresFutureSchema() throws {
        let defaults = ZPDFInMemoryDefaults()
        var future = ProjectWindowLayoutState(navigatorWidth: 400)
        future.schemaVersion = ProjectWindowLayoutState.currentSchemaVersion + 1
        defaults.setPersistedData(try JSONEncoder().encode(future), forKey: "test.layout")
        let store = ProjectWindowLayoutStore(defaults: defaults, key: "test.layout")
        #expect(store.load() == ProjectWindowLayoutState.default)
    }

    @Test("Reset forgets the stored layout")
    func resetClearsStorage() {
        let (store, defaults) = makeStore()
        store.save(ProjectWindowLayoutState(navigatorWidth: 300))
        #expect(!defaults.isEmpty)
        store.reset()
        #expect(defaults.isEmpty)
        #expect(store.load() == ProjectWindowLayoutState.default)
    }

    @Test("Two stores with different keys keep separate layouts")
    func separateKeysAreIndependent() {
        let defaults = ZPDFInMemoryDefaults()
        let left = ProjectWindowLayoutStore(defaults: defaults, key: "window.a")
        let right = ProjectWindowLayoutStore(defaults: defaults, key: "window.b")
        left.save(ProjectWindowLayoutState(navigatorWidth: 200))
        right.save(ProjectWindowLayoutState(navigatorWidth: 400))
        #expect(left.load().navigatorWidth == 200)
        #expect(right.load().navigatorWidth == 400)
    }

    @Test("Autosave names are unique and non-empty")
    func autosaveNamesAreUnique() {
        let names = ZPDFShellAutosaveName.all
        #expect(!names.isEmpty)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    @Test("Panel state changes are reported so the layout owner can persist them")
    func panelStateReportsChanges() {
        let state = ShellPanelState()
        var changes = 0
        state.onChange = { changes += 1 }

        state.navigatorSection = .layers
        #expect(changes == 1)

        // Setting the same value again is not a change worth writing to disk.
        state.navigatorSection = .layers
        #expect(changes == 1)

        state.setExpanded(true, section: .actions)
        #expect(changes == 2)
        #expect(state.isExpanded(.actions))

        state.setExpanded(true, section: .actions)
        #expect(changes == 2)
    }

    /// CR-100 — the toolbar's last-used memory was written every session and read back never.
    ///
    /// CR-120: this test carried the word "captured" in its title and never ran a capture or a
    /// restore. It copied a field between two structs by hand and asserted the store could
    /// round-trip it, which the round-trip test above already covers. The controller was the
    /// half that was broken, and it went untested: `init` seeded `panelState` from the loaded
    /// state and left the toolbar on its defaults, after which the first `captureLayoutState()`
    /// wrote those defaults straight over the stored values. Old output, against the code
    /// before the fix:
    ///
    /// ```
    /// ✘ Test "The toolbar's last-used memory survives a relaunch" recorded an issue at
    ///   LayoutStatePersistenceTests.swift:263:9: Expectation failed:
    ///   (relaunched.toolbar.lastUsedMeasurementKind → .length) == .volume
    /// ✘ Test "The toolbar's last-used memory survives a relaunch" recorded an issue at
    ///   LayoutStatePersistenceTests.swift:267:9: Expectation failed:
    ///   (relaunched.toolbar.measureButtonTitle → "Length")
    ///   == (MeasurementKind.volume.displayName → "Volume")
    /// ✘ Test "The toolbar's last-used memory survives a relaunch" recorded an issue at
    ///   LayoutStatePersistenceTests.swift:272:9: Expectation failed:
    ///   (secondLayout.layoutState.lastUsedMeasurementKind → .length) == .volume
    /// ✘ Test "The toolbar's last-used memory survives a relaunch" recorded an issue at
    ///   LayoutStatePersistenceTests.swift:284:9: Expectation failed:
    ///   (third.toolbar.lastUsedCountPresetID → nil) == (presetID → F8A16906-…)
    /// ```
    @Test("The toolbar's last-used memory survives a relaunch")
    func toolbarMemorySurvivesARelaunch() {
        let defaults = ZPDFInMemoryDefaults()
        let key = "test.layout.toolbarMemory"
        let presetID = UUID()

        // Session one: the estimator spends it in Volume, and the layout is written.
        let first = ProjectShellEnvironment.mock()
        let firstLayout = ProjectWindowLayoutController(
            environment: first,
            store: ProjectWindowLayoutStore(defaults: defaults, key: key)
        )
        _ = firstLayout.view
        first.toolbar.activateMeasurement(.volume)
        firstLayout.captureLayoutState()
        #expect(ProjectWindowLayoutStore(defaults: defaults, key: key).save(firstLayout.layoutState))

        let stored = ProjectWindowLayoutStore(defaults: defaults, key: key).load()
        #expect(stored.lastUsedMeasurementKind == .volume)

        // Session two: the same defaults, a new window.
        let relaunched = ProjectShellEnvironment.mock()
        let secondLayout = ProjectWindowLayoutController(
            environment: relaunched,
            store: ProjectWindowLayoutStore(defaults: defaults, key: key)
        )
        #expect(
            relaunched.toolbar.lastUsedMeasurementKind == .volume,
            "the Measure button re-arms Length after a session spent in Volume"
        )
        #expect(relaunched.toolbar.measureButtonTitle == MeasurementKind.volume.displayName)

        // …and the next capture must not overwrite the memory with a default it never read.
        _ = secondLayout.view
        secondLayout.captureLayoutState()
        #expect(secondLayout.layoutState.lastUsedMeasurementKind == .volume)

        // The count preset takes the same route.
        let third = ProjectShellEnvironment.mock()
        var withPreset = ProjectWindowLayoutState()
        withPreset.lastUsedCountPresetID = presetID
        let presetDefaults = ZPDFInMemoryDefaults()
        #expect(ProjectWindowLayoutStore(defaults: presetDefaults, key: key).save(withPreset))
        _ = ProjectWindowLayoutController(
            environment: third,
            store: ProjectWindowLayoutStore(defaults: presetDefaults, key: key)
        )
        #expect(third.toolbar.lastUsedCountPresetID == presetID)
    }

    @Test("Restoring the memory is not a user action, so it writes nothing back")
    func restoringTheMemoryDoesNotPersist() {
        let toolbar = ZenitToolbarModel()
        var persistCount = 0
        toolbar.onPersistableChange = { persistCount += 1 }

        toolbar.restoreLastUsed(measurementKind: .wallArea, countPresetID: UUID())
        #expect(toolbar.lastUsedMeasurementKind == .wallArea)
        #expect(
            persistCount == 0,
            "a restore that writes the store from inside the window's initializer is an overwrite"
        )
        #expect(toolbar.activeSelection.mode == .select, "a restore arms nothing")

        // A real choice still announces itself.
        toolbar.activateMeasurement(.trueSlopedArea)
        #expect(persistCount == 1)
    }

    /// CR-106 — arming a count preset that is not in the palette.
    ///
    /// CR-120: this test passed on both branches of an `if let`, so it asserted only that the
    /// property was either set or not set. Old output, against the code before the fix:
    ///
    /// ```
    /// ✘ Test "A count preset that is not in the palette is refused, not remembered" recorded an
    ///   issue at LayoutStatePersistenceTests.swift:335:9: Expectation failed:
    ///   (toolbar.lastUsedCountPresetID → 57FD6239-979D-4F3F-8DE1-2945CD806D34) == nil
    /// ✘ Test "A count preset that is not in the palette is refused, not remembered" recorded an
    ///   issue at LayoutStatePersistenceTests.swift:337:9: Expectation failed:
    ///   (toolbar.activeSelection.presetID → 57FD6239-979D-4F3F-8DE1-2945CD806D34) == nil
    /// ✘ Test "A count preset that is not in the palette is refused, not remembered" recorded an
    ///   issue at LayoutStatePersistenceTests.swift:339:9: Expectation failed:
    ///   (announced → [57FD6239-979D-4F3F-8DE1-2945CD806D34]).isEmpty → false
    /// ```
    @Test("A count preset that is not in the palette is refused, not remembered")
    func armingAMissingCountPresetIsRefused() {
        let toolbar = ZenitToolbarModel()
        toolbar.updateCountPalette(from: ZenitSampleProject.shared.presets)
        #expect(!toolbar.countPalette.isEmpty, "the sample project must offer count presets")

        var persisted = 0
        toolbar.onPersistableChange = { persisted += 1 }
        var announced: [UUID] = []
        toolbar.onCountPreset = { announced.append($0) }

        let ghost = UUID()
        toolbar.activateCountPreset(id: ghost)

        #expect(toolbar.lastUsedCountPresetID == nil, "an id the palette does not hold was remembered")
        #expect(toolbar.activeSelection.mode == .measure(.count), "the person still asked for Count")
        #expect(toolbar.activeSelection.presetID == nil)
        #expect(toolbar.activeSelection.countSymbolName == nil, "a presetID with no symbol behind it")
        #expect(announced.isEmpty, "the Tool Library was asked for a preset that does not exist")
        #expect(persisted == 1, "one persistable change: the plain Count tool being armed")
    }

    @Test("A count preset that is in the palette arms with its symbol and is remembered")
    func armingARealCountPresetKeepsWorking() throws {
        let toolbar = ZenitToolbarModel()
        toolbar.updateCountPalette(from: ZenitSampleProject.shared.presets)
        let preset = try #require(toolbar.countPalette.first)

        var announced: [UUID] = []
        toolbar.onCountPreset = { announced.append($0) }
        toolbar.activateCountPreset(id: preset.id)

        #expect(toolbar.lastUsedCountPresetID == preset.id)
        #expect(toolbar.activeSelection.presetID == preset.id)
        #expect(toolbar.activeSelection.countSymbolName == preset.countSymbolName)
        #expect(announced == [preset.id])
    }

    /// CR-120 — this passed on both branches of an `if let`, so it asserted only that a
    /// property was either set or not set.
    ///
    /// `updateCountPalette(from:)` already forgot a vanished id, so there is no old output to
    /// paste: this is a **vacuous test made real**, not a product regression. What it now pins
    /// is the whole rule — forgotten, persisted, and the button falling back to the first
    /// preset — instead of a tautology.
    @Test("A remembered count preset that no longer exists is forgotten by the palette refresh")
    func forgetsMissingCountPreset() {
        let ghost = UUID()
        let toolbar = ZenitToolbarModel(lastUsedCountPresetID: ghost)
        var persisted = 0
        toolbar.onPersistableChange = { persisted += 1 }

        toolbar.updateCountPalette(from: ZenitSampleProject.shared.presets)

        #expect(!toolbar.countPalette.contains { $0.id == ghost })
        #expect(
            toolbar.lastUsedCountPresetID == nil,
            "a button pointing at a preset that is gone must forget it, not keep pointing"
        )
        #expect(persisted == 1, "forgetting it is worth writing, or the next launch restores it again")
        #expect(toolbar.lastUsedCountPreset?.id == toolbar.countPalette.first?.id)
    }
}
