import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Asserts the toolbar against the main-window mockup: Calibrate, Length and Area are
/// always-visible first-class items, the brand block leads,
/// user customization is on and autosaved, and every label is visible next to its icon.
@MainActor
@Suite("Toolbar configuration", .shellTierSerialised)
struct ToolbarConfigurationTests {

    /// Updated 2026-09-23 (design round d2): the new main-window mockup, which replaces the
    /// earlier mockups where they disagree, puts Zoom between Select and Pan. The rule this test
    /// exists for — Calibrate, Length and Area first class and *right after Pan* — is asserted
    /// exactly as strictly as before; only the old mockup's
    /// adjacency of Select and Pan, which the new mockup drops, is no longer demanded.
    @Test("Calibrate, Length and Area are first class, right after Pan")
    func calibrateLengthAndAreaAreFirstClass() {
        let defaults = ZenitToolbarBuilder.defaultItemIdentifiers
        for identifier in [NSToolbarItem.Identifier.zenitCalibrate, .zenitLength, .zenitArea,
                           .zenitSelect, .zenitPan, .zenitCount] {
            #expect(defaults.contains(identifier), "\(identifier.rawValue) missing from the default set")
        }
        // The three first-class tools sit in one uninterrupted run right after Pan.
        let pan = defaults.firstIndex(of: .zenitPan)!
        #expect(Array(defaults[pan...].prefix(4)) == [.zenitPan, .zenitCalibrate, .zenitLength, .zenitArea])
        // Select still leads the tool group.
        let firstTool = defaults.firstIndex { ZenitToolbarBuilder.selectableItemIdentifiers.contains($0) }
        #expect(firstTool.map { defaults[$0] } == .zenitSelect)
    }

    @Test("The default set centres the tool group: brand left, flexible space each side, workspace right")
    func defaultCompositionIsCentred() throws {
        let defaults = ZenitToolbarBuilder.defaultItemIdentifiers

        // Flexible space on BOTH sides of the tool group keeps it
        // horizontally centred as the window resizes.
        let gaps = defaults.indices.filter { defaults[$0] == .flexibleSpace }
        #expect(gaps.count == 2)
        let leading = try #require(gaps.first)
        let trailing = try #require(gaps.last)

        // The brand block is alone on the left of the first gap.
        #expect(Array(defaults[..<leading]) == [.zenitBrand])

        // The tool group is one uninterrupted run between the two gaps, in the 2026-09-23
        // mockup's order, with the hairline separator between Measure and Text.
        let drawing: [NSToolbarItem.Identifier] = [
            .zenitSelect, .zenitZoom, .zenitPan, .zenitCalibrate, .zenitLength, .zenitArea,
            .zenitMeasure, .zenitToolSeparator,
            .zenitText, .zenitCallout, .zenitShapes, .zenitCount, .zenitCutout
        ]
        #expect(Array(defaults[(leading + 1)..<trailing]) == drawing)

        // The rounded workspace group and the author badge close the toolbar (2026-09-23
        // mockup). The group carries Tool Library, Search, Compare and Export in that order.
        #expect(Array(defaults[(trailing + 1)...]) == [.zenitWorkspaceGroup, .zenitAuthor])
        #expect(ZenitToolbarBuilder.workspaceCommands.map(\.identifier)
            == [.zenitToolLibrary, .zenitSearch, .zenitCompare, .zenitExport])

        // No fixed `.space` remains: fixed spaces read as asymmetric padding once the
        // group is centred, and they split AppKit's overflow groups unevenly.
        #expect(!defaults.contains(.space))

        // The centre "Measurement controls" field stays out of the default set — it read
        // as a second toolbar in the middle of the gap. Still available from the palette.
        #expect(!defaults.contains(.zenitMeasurementControls))
        #expect(ZenitToolbarBuilder.allowedItemIdentifiers.contains(.zenitMeasurementControls))
        // The four workspace commands stay individually available for customization.
        for identifier in [NSToolbarItem.Identifier.zenitToolLibrary, .zenitSearch, .zenitCompare, .zenitExport] {
            #expect(ZenitToolbarBuilder.allowedItemIdentifiers.contains(identifier))
        }
    }

    @Test("No bubble: every item sits directly on the bar, never on a glass slab")
    func noGlassSlabBehindTheChips() {
        let environment = ProjectShellEnvironment.mock()
        let builder = ZenitToolbarBuilder(environment: environment)
        let toolbar = builder.makeToolbar()
        for identifier in ZenitToolbarBuilder.allowedItemIdentifiers
        where ![.space, .flexibleSpace, .toggleSidebar, .toggleInspector].contains(identifier) {
            let item = builder.toolbar(
                toolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: true
            )
            // `isBordered == false` is what keeps macOS 26 from wrapping the chips in a
            // shared Liquid Glass container — a dark bubble around the group.
            #expect(item?.isBordered == false, "\(identifier.rawValue) would sit on a glass slab")
        }
    }

    /// v4 since 2026-09-23: the new main-window mockup reordered the tool group and added the
    /// separator, the rounded workspace group and the author badge; without the bump every
    /// existing install would keep its autosaved v3 arrangement. v5 the same day: the window
    /// draws the top band itself and the toolbar is its hidden model (design d8 follow-up).
    @Test("The toolbar autosave identity is v5, so the window-drawn top band reaches existing installs once")
    func toolbarAutosaveIsVersioned() {
        #expect(ZPDFShellAutosaveName.toolbar == "Zenit.ProjectWindow.Toolbar.v5")
        #expect(ZPDFShellAutosaveName.all.contains(ZPDFShellAutosaveName.toolbar))
    }

    @Test("The brand block leads the default set and is not a selectable tool")
    func brandBlockLeads() {
        #expect(ZenitToolbarBuilder.defaultItemIdentifiers.first == .zenitBrand)
        #expect(!ZenitToolbarBuilder.selectableItemIdentifiers.contains(.zenitBrand))
    }

    @Test("Every default item is allowed, so customization can always restore the default")
    func defaultsAreAllowed() {
        let allowed = Set(ZenitToolbarBuilder.allowedItemIdentifiers + [.space, .flexibleSpace])
        for identifier in ZenitToolbarBuilder.defaultItemIdentifiers {
            #expect(allowed.contains(identifier), "\(identifier.rawValue) not in the allowed set")
        }
    }

    @Test("The first-class measurement items can read as the armed tool")
    func firstClassItemsAreSelectable() {
        for identifier in [NSToolbarItem.Identifier.zenitCalibrate, .zenitLength, .zenitArea] {
            #expect(ZenitToolbarBuilder.selectableItemIdentifiers.contains(identifier))
        }
    }

    @Test("The toolbar is user-customizable and autosaved; every item carries its own caption")
    func toolbarIsCustomizableAndLabelled() {
        let environment = ProjectShellEnvironment.mock()
        let builder = ZenitToolbarBuilder(environment: environment)
        let toolbar = builder.makeToolbar()
        #expect(toolbar.allowsUserCustomization)
        // Autosaved in the assembled application; never from a test process, whose standard
        // domain is the runner's (verify-test-tier-hygiene.sh, section 4).
        #expect(toolbar.autosavesConfiguration == ZPDFShellAutosaveName.appKitAutosavesEnabled)
        #expect(!ZPDFShellAutosaveName.appKitAutosavesEnabled, "a swift test process is not the assembled bundle")
        // The chips draw icon *and* caption themselves; the toolbar stays icon-only so
        // AppKit does not double every caption.
        #expect(toolbar.displayMode == .iconOnly)
        #expect(toolbar.identifier == ZPDFShellAutosaveName.toolbar)

        // Every default item is a labelled chip view: the label feeds the overflow menu
        // and the customization sheet, the view carries the visible caption.
        for identifier in ZenitToolbarBuilder.defaultItemIdentifiers
        where ![.space, .flexibleSpace].contains(identifier) {
            let item = builder.toolbar(
                toolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: true
            )
            #expect(item != nil, "\(identifier.rawValue) built no item")
            #expect(item?.view != nil, "\(identifier.rawValue) is not a chip view")
            #expect(!(item?.paletteLabel.isEmpty ?? true), "\(identifier.rawValue) has no palette label")
            if identifier != .zenitBrand {
                #expect(!(item?.label.isEmpty ?? true), "\(identifier.rawValue) has no label")
            }
        }
    }

    @Test("AppKit's grey selection ring stays off — the chips draw the armed state")
    func appKitSelectionRingIsOff() {
        let environment = ProjectShellEnvironment.mock()
        let builder = ZenitToolbarBuilder(environment: environment)
        let toolbar = builder.makeToolbar()
        #expect(builder.toolbarSelectableItemIdentifiers(toolbar).isEmpty)
        // The chip vocabulary is still complete.
        #expect(ZenitToolbarBuilder.selectableItemIdentifiers.count == 12)
    }

    @Test("The armed-tool fill lands on the first-class item for Length and Area")
    func selectionRingFollowsFirstClassItems() {
        #expect(
            ZenitToolbarBuilder.selectionIdentifier(for: .measure, lastUsedMeasurement: .length)
                == .zenitLength
        )
        #expect(
            ZenitToolbarBuilder.selectionIdentifier(for: .measure, lastUsedMeasurement: .area)
                == .zenitArea
        )
        // A rarer tool keeps the ring on the palette button.
        #expect(
            ZenitToolbarBuilder.selectionIdentifier(for: .measure, lastUsedMeasurement: .polylength)
                == .zenitMeasure
        )
        #expect(
            ZenitToolbarBuilder.selectionIdentifier(for: .calibrate, lastUsedMeasurement: .length)
                == .zenitCalibrate
        )
        #expect(
            ZenitToolbarBuilder.selectionIdentifier(for: .select, lastUsedMeasurement: .length)
                == .zenitSelect
        )
    }

    @Test("Arming Length or Area through the environment lands on the right ring")
    func armingThroughTheEnvironment() {
        let environment = ProjectShellEnvironment.mock()
        environment.perform(.measureLength)
        // Length and Area are their own identifiers now (the cases used to be missing): the chip that lights up *is* the tool, not the Measure palette
        // standing in for it.
        #expect(environment.toolbar.activeTool == .length)
        #expect(environment.toolbar.activeSelection.mode == .measure(.length))
        // IM-031 (fix round 2 D2): Length and Area have chips of their own, so they are no
        // longer written into the Measure palette's memory — that turned the Measure button
        // into a second Length button.
        let paletteMemory = environment.toolbar.lastUsedMeasurementKind
        #expect(paletteMemory != .length)
        environment.perform(.measureArea)
        #expect(environment.toolbar.activeTool == .area)
        #expect(environment.toolbar.activeSelection.mode == .measure(.area))
        #expect(environment.toolbar.lastUsedMeasurementKind == paletteMemory)
    }

    @Test("The customization and the ledger commands are declared for the menu bar")
    func newCommandsAreDeclared() {
        let table = ZPDFCommandTable.standard
        #expect(table.command(.customizeToolbar)?.group == .view)
        #expect(table.command(.collapseQuantityLedger)?.group == .panels)
        #expect(table.command(.calibrateScale)?.group == .measure)
        // Calibrate leads the Measure menu, matching its rank in the toolbar.
        #expect(table.commands(in: .measure).first?.id == .calibrateScale)
    }

    @Test("Every tool identifier carries a visible name and a glyph")
    func toolIdentifiersAreComplete() {
        for tool in ZenitToolIdentifier.allCases {
            #expect(!tool.displayName.isEmpty)
        }
        #expect(ZenitToolIdentifier.allCases.contains(.calibrate))
        #expect(!ZenitToolIdentifier.calibrate.showsMeasurementControls)
    }

    /// CR-114 — a palette tooltip named the tool the palette used to re-arm.
    ///
    /// `help:` was a `String`, formatted once when the toolbar was built:
    /// `String(format: helpFormat, environment.toolbar.measureButtonTitle)`. Switching the
    /// Measure palette to Volume moved the button, the caption and the armed tool, and left the
    /// tooltip still offering to "use Length again". Old output, against the code before the
    /// fix:
    ///
    /// ```
    /// ✘ Test "A palette tooltip names the tool the button will actually re-arm" recorded an
    ///   issue at ToolbarConfigurationTests.swift:249:9: Expectation failed:
    ///   (measure.toolTip?.contains(MeasurementKind.volume.displayName) → false) == true
    /// ✘ Test "A palette tooltip names the tool the button will actually re-arm" recorded an
    ///   issue at ToolbarConfigurationTests.swift:250:9: Expectation failed:
    ///   (measure.toolTip?.contains(MeasurementKind.length.displayName) → true) == false
    /// ```
    @Test("A palette tooltip names the tool the button will actually re-arm")
    func paletteTooltipsFollowTheLastUsedMemory() throws {
        let environment = ProjectShellEnvironment.mock()
        // The layout controller is what wires the toolbar model's persistable-change hook to
        // the builder's tooltip refresh, so the window's real wiring is under test. No NSWindow
        // is created — a test may never put one on the user's screen, and the
        // items are built through the delegate exactly as AppKit builds them.
        let layout = ProjectWindowLayoutController(
            environment: environment,
            store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: "t.tooltips")
        )
        let toolbar = layout.toolbarBuilder.makeToolbar()
        toolbar.insertItem(withItemIdentifier: .zenitMeasure, at: 0)
        toolbar.insertItem(withItemIdentifier: .zenitCount, at: 1)

        let measure = try #require(toolbar.items.first { $0.itemIdentifier == .zenitMeasure })
        // IM-031: the Measure button starts on the palette's first tool, not on Length.
        let start = environment.toolbar.lastUsedMeasurementKind
        #expect(measure.toolTip?.contains(start.displayName) == true,
                "the fixture starts on the palette's first tool")

        environment.toolbar.activateMeasurement(.volume)

        #expect(measure.toolTip?.contains(MeasurementKind.volume.displayName) == true)
        #expect(measure.toolTip?.contains(start.displayName) == false,
                "the tooltip still offers the tool the palette no longer re-arms")
        #expect(environment.toolbar.measureButtonTitle == MeasurementKind.volume.displayName)
    }

    @Test("The live tooltip is what the chip and the item both read")
    func liveTooltipIsOneSource() {
        let environment = ProjectShellEnvironment.mock()
        let builder = ZenitToolbarBuilder(environment: environment)
        let toolbar = builder.makeToolbar()
        // Building the item registers its live tooltip; the delegate is how AppKit asks.
        _ = builder.toolbar(toolbar, itemForItemIdentifier: .zenitMeasure, willBeInsertedIntoToolbar: true)
        _ = builder.toolbar(toolbar, itemForItemIdentifier: .zenitShapes, willBeInsertedIntoToolbar: true)
        _ = builder.toolbar(toolbar, itemForItemIdentifier: .zenitCount, willBeInsertedIntoToolbar: true)

        let before = builder.liveHelpText(for: .zenitMeasure)
        #expect(before?.contains(environment.toolbar.lastUsedMeasurementKind.displayName) == true)

        environment.toolbar.activateMeasurement(.wallArea)
        #expect(builder.liveHelpText(for: .zenitMeasure)?.contains(MeasurementKind.wallArea.displayName) == true)

        environment.toolbar.activateShape(.ellipse)
        #expect(builder.liveHelpText(for: .zenitShapes)?.contains(MarkupKind.ellipse.displayName) == true)
    }

    /// CR-120 — the second half of this test asserted a property it had never set.
    ///
    /// "Without a close action the host must not swallow Escape" was followed by
    /// `#expect(passive.onEscape == nil)` — which is true because nothing assigned it, and says
    /// nothing at all about whether Escape travelled on. The claim is about the RESPONDER
    /// CHAIN, so the chain is what is watched now — with a responder that counts what reaches
    /// it, and a second case pinning that a panel WITH a close action does not also pass Escape
    /// on (one key press backing out two levels).
    ///
    /// There is no "old output" to paste here, and that is precisely the defect: the old
    /// `#expect(passive.onEscape == nil)` was true against any product behaviour whatever,
    /// because nothing in the test ever set it. `ZPDFPanelHostViewController.cancelOperation`
    /// already forwarded correctly, so this is a **test-quality fix (CR-120), not a product
    /// regression** — the forwarding is simply watched now instead of assumed.
    @Test("A panel host routes Escape to its close action, and passes it on when it has none")
    func panelHostEscapeRouting() {
        let host = ZPDFPanelHostViewController(
            accessibilityLabel: "Test panel",
            rootView: Text(verbatim: "")
        )
        var closed = 0
        host.onEscape = { closed += 1 }
        host.cancelOperation(nil as Any?)
        #expect(closed == 1)

        // A panel with a close action must NOT also pass Escape on: backing out one level
        // twice from one key press is the double-dismiss the mode registry exists to prevent.
        let handledChain = EscapeCountingResponder()
        host.nextResponder = handledChain
        host.cancelOperation(nil as Any?)
        #expect(closed == 2)
        #expect(handledChain.cancels == 0, "one Escape backed out two levels")

        // Without a close action the host must not swallow Escape — it has to reach the next
        // responder, which is what "passes it on" means.
        let passive = ZPDFPanelHostViewController(
            accessibilityLabel: "Passive panel",
            rootView: Text(verbatim: "")
        )
        let chain = EscapeCountingResponder()
        passive.nextResponder = chain
        passive.cancelOperation(nil as Any?)
        #expect(chain.cancels == 1, "Escape died at a panel that had nothing to close")
    }
}

/// A responder that counts the Escapes reaching it, so "passes it on" is observable.
@MainActor
private final class EscapeCountingResponder: NSResponder {

    private(set) var cancels = 0

    override func cancelOperation(_ sender: Any?) {
        cancels += 1
    }
}
