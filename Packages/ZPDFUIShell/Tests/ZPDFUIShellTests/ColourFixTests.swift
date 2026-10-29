import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The colour fixes: NL-MARKUP-01 (the Inspector swatches that could not be clicked, LT3-01)
/// and the tool style nothing ever set.
///
/// What a click does in a binary stamped like the app is `zpdf-hit-probe`'s job — `xctest` runs
/// the modern SwiftUI hit-testing and cannot see that class of defect, which is exactly how
/// LT3-01 shipped. These tests pin the value rules and the wiring beneath the click.
@MainActor
@Suite("Colour fix: swatches, palette, tool style", .shellTierSerialised)
struct ColourFixTests {

    private let red = ZPDFMarkupInk.red.color
    private let green = ZPDFMarkupInk.green.color

    // MARK: - Swatch value rules

    @Test("A pick of the colour already in force is not an edit, compared by hue")
    func samePickIsNoEdit() {
        #expect(InspectorColourControl.pickedColour(red, current: red) == nil)
        var translucentRed = red
        translucentRed.alpha = 0.2
        // The fill row's value carries the fill's alpha; the palette offers opaque inks.
        #expect(InspectorColourControl.pickedColour(red, current: translucentRed) == nil)
        #expect(InspectorColourControl.pickedColour(green, current: red) == green)
    }

    @Test("A mixed selection writes a deliberate pick and never the transparent placeholder")
    func mixedSelectionRules() {
        #expect(InspectorColourControl.pickedColour(red, current: nil) == red)
        #expect(InspectorColourControl.pickedColour(ColorRGBA(red: 0, green: 0, blue: 0, alpha: 0), current: nil) == nil)
    }

    @Test("Swatch markers are stable and distinct, so the probe can find each swatch")
    func swatchMarkers() {
        let roles = ["border", "fill", "tool.border", "tool.fill"]
        let ids = roles.map(InspectorColourControl.markerIdentifier(role:))
        #expect(Set(ids).count == roles.count)
        #expect(InspectorColourControl.markerIdentifier(role: "border") == "zpdf.inspector.swatch.border")
        #expect(!ids.contains(InspectorPanel.removeFillMarker))
    }

    @Test("The hover stepper keeps a fixed slot, so nothing shifts when it appears")
    func stepperSlot() {
        #expect(InspectorNumberControl.stepperSlot.width > 0)
        #expect(InspectorNumberControl.stepperSlot.height > 0)
        #expect(InspectorNumberControl.showsStepper(isHovering: true, isEditing: false))
        #expect(InspectorNumberControl.showsStepper(isHovering: false, isEditing: true))
        #expect(!InspectorNumberControl.showsStepper(isHovering: false, isEditing: false))
    }

    @Test("The environment's palette services default to the product's and are injectable")
    func paletteServices() {
        let env = ProjectShellEnvironment.mock()
        #expect(env.colourPalettePresenter is ZPDFSystemPopoverPresenter)
        #expect(env.colourPanel === ZPDFColourPanelController.shared)
        #expect(env.recentColours === ProjectShellEnvironment.sharedRecentColours)
        let recents = ZPDFRecentColours()
        env.recentColours = recents
        #expect(InspectorColourServices(environment: env).recents === recents)
        // A test process keeps recent colours in memory: nothing reaches the real defaults.
        #expect(!ZPDFShellAutosaveName.appKitAutosavesEnabled)
    }

    // MARK: - Tool style: the rule

    @Test("A new stroke carries a fill that was the old stroke's tint along with it")
    func strokeCarriesDerivedFill() {
        let base = ToolStyleSelection.zenitInk
        let next = ZenitToolbarModel.style(base, applying: MarkupStyleEdit(color: red))
        #expect(next.stroke == ZPDFColourMath.opaque(red))
        #expect(next.fill.map { ZPDFColourMath.sameHue($0, red) } == true)
        #expect(next.fill?.alpha == base.fill?.alpha, "the tint keeps its 20 %")
        #expect(next.lineWidth == base.lineWidth)
    }

    @Test("An explicit fill, No Fill, width and text size are each taken; nonsense is not")
    func styleFields() {
        var base = ToolStyleSelection.zenitInk
        base.fill = green
        let recoloured = ZenitToolbarModel.style(base, applying: MarkupStyleEdit(color: red))
        #expect(recoloured.fill == green, "a fill the person chose is not a tint and stays")
        #expect(ZenitToolbarModel.style(base, applying: MarkupStyleEdit(removesFill: true)).fill == nil)
        #expect(ZenitToolbarModel.style(base, applying: MarkupStyleEdit(lineWidth: 4)).lineWidth == 4)
        #expect(ZenitToolbarModel.style(base, applying: MarkupStyleEdit(fontSize: 18)).fontSize == 18)
        #expect(ZenitToolbarModel.style(base, applying: MarkupStyleEdit(lineWidth: .nan)).lineWidth == base.lineWidth)
        #expect(ZenitToolbarModel.style(base, applying: MarkupStyleEdit(fontSize: 0)).fontSize == base.fontSize)
        // NL-MARKUP-04: opacity is a tool field now; a
        // non-finite value is still refused.
        #expect(ZenitToolbarModel.style(base, applying: MarkupStyleEdit(opacity: 0.5)).opacity == 0.5)
        #expect(ZenitToolbarModel.style(base, applying: MarkupStyleEdit(opacity: .nan)) == base)
    }

    // MARK: - Tool style: the setter now has callers, and they reach the armed tool

    @Test("setStyle re-arms an armed markup tool with the new style")
    func setStyleReachesArmedMarkupTool() {
        let toolbar = ZenitToolbarModel()
        toolbar.activateShape(.rectangle)
        var announced: [ZenitToolSelection] = []
        toolbar.onSelectionChange = { announced.append($0) }
        var persisted = 0
        toolbar.onPersistableChange = { persisted += 1 }
        var style = ToolStyleSelection.zenitInk
        style.stroke = red
        toolbar.setStyle(style)
        #expect(toolbar.toolStyle == style)
        #expect(toolbar.activeSelection.style == style)
        #expect(toolbar.activeSelection.mode == .markup(.rectangle))
        #expect(announced.count == 1, "the canvas hears about it through the one seam")
        #expect(persisted == 1)
        toolbar.setStyle(style)
        #expect(announced.count == 1 && persisted == 1, "an unchanged style announces nothing")
    }

    @Test("setStyle leaves a measurement tool exactly as it is, and the next markup tool takes it")
    func setStyleLeavesMeasurementAlone() {
        let toolbar = ZenitToolbarModel()
        toolbar.activateMeasurement(.area)
        let armed = toolbar.activeSelection
        var announced = 0
        toolbar.onSelectionChange = { _ in announced += 1 }
        var style = ToolStyleSelection.zenitInk
        style.stroke = green
        style.lineWidth = 3
        toolbar.setStyle(style)
        #expect(announced == 0, "re-arming would end a boundary capture or a half-placed measurement")
        #expect(toolbar.activeSelection == armed)
        toolbar.selectTool(.text)
        #expect(toolbar.activeSelection.mode == .markup(.text))
        #expect(toolbar.activeSelection.style == style)
        toolbar.selectTool(.callout)
        #expect(toolbar.activeSelection.style == style)
        toolbar.activateShape(.cloud)
        #expect(toolbar.activeSelection.style == style)
    }

    @Test("rememberStyle folds a markup style edit into the tools' style")
    func rememberStyle() {
        let toolbar = ZenitToolbarModel()
        toolbar.rememberStyle(MarkupStyleEdit(color: red, lineWidth: 2.5))
        #expect(toolbar.toolStyle.stroke == ZPDFColourMath.opaque(red))
        #expect(toolbar.toolStyle.lineWidth == 2.5)
        toolbar.activateShape(.ellipse)
        #expect(toolbar.activeSelection.style == toolbar.toolStyle)
    }

    @Test("A restored tool style is taken silently, and a nonsensical one is refused")
    func restoreToolStyle() {
        let toolbar = ZenitToolbarModel()
        var persisted = 0
        toolbar.onPersistableChange = { persisted += 1 }
        var style = ToolStyleSelection.zenitInk
        style.stroke = red
        toolbar.restoreToolStyle(style)
        #expect(toolbar.toolStyle == style)
        #expect(persisted == 0, "a restore is not a user choice and must not write the store")
        var broken = style
        broken.lineWidth = .infinity
        toolbar.restoreToolStyle(broken)
        #expect(toolbar.toolStyle == style)
        toolbar.restoreToolStyle(nil)
        #expect(toolbar.toolStyle == style)
    }

    @Test("The layout state carries the tool style, and an older layout without it still decodes")
    func layoutStateCarriesToolStyle() throws {
        var style = ToolStyleSelection.zenitInk
        style.stroke = green
        let state = ProjectWindowLayoutState(toolStyle: style)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(ProjectWindowLayoutState.self, from: data).toolStyle == style)
        // An older blob: the same state with the key removed.
        let json = try JSONSerialization.jsonObject(with: data)
        var object = try #require(json as? [String: Any])
        object.removeValue(forKey: "toolStyle")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ProjectWindowLayoutState.self, from: old)
        #expect(decoded.toolStyle == nil)
        #expect(decoded.normalized() == ProjectWindowLayoutState().normalized())
    }

    // MARK: - The Inspector's two callers

    @Test("Only a selection holding a drawn markup becomes the tools' last-used style")
    func whichSelectionsAreRemembered() throws {
        let env = ProjectShellEnvironment.mock()
        let canvas = try #require(env.canvas as? MockCanvasPresenter)
        let area = try #require(canvas.visibleMarkups.first { $0.measurementKind == .area })
        var shape = area
        shape.kind = .rectangle
        shape.measurementKind = nil
        #expect(!InspectorPanel.remembersToolStyle(for: InspectorSelectionSummary(markups: [area])))
        #expect(InspectorPanel.remembersToolStyle(for: InspectorSelectionSummary(markups: [shape])))
        #expect(InspectorPanel.remembersToolStyle(for: InspectorSelectionSummary(markups: [area, shape])))
    }

    @Test("A style edit to a drawn markup sets the next markup's style; one to a measured area does not")
    func applyStyleRemembers() throws {
        let env = ProjectShellEnvironment.mock()
        let canvas = try #require(env.canvas as? MockCanvasPresenter)
        let area = try #require(canvas.visibleMarkups.first { $0.measurementKind == .area && !$0.locked })
        let panel = InspectorPanel(environment: env, panelState: ShellPanelState())
        panel.applyStyle(MarkupStyleEdit(color: red), to: InspectorSelectionSummary(markups: [area]))
        #expect(env.toolbar.toolStyle == .zenitInk)
        var shape = area
        shape.kind = .callout
        shape.measurementKind = nil
        panel.applyStyle(MarkupStyleEdit(color: red), to: InspectorSelectionSummary(markups: [shape]))
        #expect(env.toolbar.toolStyle.stroke == ZPDFColourMath.opaque(red))
    }

    @Test("The tool style card appears for a drawable markup tool and nothing else")
    func styleableTool() {
        #expect(InspectorPanel.styleableTool(ZenitToolSelection(mode: .markup(.text))) == .text)
        #expect(InspectorPanel.styleableTool(ZenitToolSelection(mode: .markup(.rectangle))) == .rectangle)
        #expect(InspectorPanel.styleableTool(ZenitToolSelection(mode: .measure(.area))) == nil)
        #expect(InspectorPanel.styleableTool(ZenitToolSelection(mode: .select)) == nil)
        #expect(InspectorPanel.styleableTool(ZenitToolSelection(mode: .markup(.stamp))) == nil, "a kind the tools cannot draw has no tool style")
        #expect(InspectorPanel.toolAcceptsFill(.rectangle))
        #expect(!InspectorPanel.toolAcceptsFill(.line))
        #expect(!InspectorPanel.toolAcceptsFill(.text))
    }

    // MARK: - The opacity lint, run from the package gate as well

    /// The source half of `verify-hosted-hit-targets.sh`, so a transparent hosted control fails
    /// this package's own suite too — not only the gate script. The script's scanner runs its
    /// fixtures first and refuses to vouch for the tree if it cannot catch LT3-01's well.
    @Test("No UI source draws a hosted AppKit control transparent")
    func noTransparentHostedControls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Scripts/verify-hosted-hit-targets.sh")
        try #require(FileManager.default.isExecutableFile(atPath: script.path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--scan-only"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(output)")
        #expect(output.contains("self-test: PASS"), "\(output)")
        #expect(output.contains("0 offence(s)"), "\(output)")
    }
}
