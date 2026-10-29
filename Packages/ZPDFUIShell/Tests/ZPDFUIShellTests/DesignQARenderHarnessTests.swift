import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Design round d9 (visual QA): an off-screen render harness for the main window.
///
/// Every region of the shell — the top bar, the document tabs, the Navigator, the canvas, the
/// Inspector, the Quantity Ledger bar and the whole content composition at the mockup's
/// 1672 × 941 — is rendered into a bitmap **without a window**. Views are laid out standalone
/// and drawn with `cacheDisplay(in:to:)` into a 1× bitmap, so nothing is ever ordered on
/// screen, no window server focus is taken and no `NSWindow` is created.
///
/// Each render is checked for the invariants that make it a useful comparison at all: it has
/// the requested size, it is not blank, and in the dark appearance it is predominantly dark
/// chrome, as the 2026-09-23 mockup is. When `ZENIT_DESIGN_QA_OUT` names a directory the
/// PNGs are also written there for side-by-side review against crops of the mockup. The
/// variable is unset in normal runs, so the suite writes nothing.
@MainActor
@Suite("Design QA — off-screen render harness", .shellTierSerialised)
struct DesignQARenderHarnessTests {

    // MARK: - Mockup geometry (pixels of the 1672 × 941 mockup, treated as points at 1×)

    static let mockupSize = NSSize(width: 1_672, height: 941)
    static let navigatorWidth: CGFloat = 284
    static let inspectorWidth: CGFloat = 308
    static let ledgerBarHeight: CGFloat = 77

    // MARK: - Rendering

    enum Appearance: String {
        case dark, light

        var nsAppearance: NSAppearance {
            NSAppearance(named: self == .dark ? .darkAqua : .aqua)!
        }
    }

    /// Lays a view out at `size` and draws it into a 1× RGBA bitmap, outside any window.
    static func render(_ view: NSView, size: NSSize, appearance: Appearance) async -> NSBitmapImageRep {
        view.appearance = appearance.nsAppearance
        view.frame = NSRect(origin: .zero, size: size)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        // SwiftUI resolves @Observable reads and hosting-view sizing on the next main-actor
        // turn; give it two short turns before drawing.
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            view.layoutSubtreeIfNeeded()
        }
        // Tag the bitmap sRGB *before* drawing. A device-RGB bitmap means "no matching" in a
        // process with no window-server connection but "the main display's profile" once one
        // exists (any earlier test that touched NSApplication), which shifted every dark tone by
        // up to 15 levels depending on test order. With an sRGB destination the token values
        // land byte for byte, whatever ran before.
        let device = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let rep = device.retagging(with: .sRGB) ?? device
        rep.size = size
        appearance.nsAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        return rep
    }

    /// Hosts a SwiftUI view in an `NSHostingView` that never joins a window.
    static func host<Content: View>(_ content: Content, appearance: Appearance) -> NSView {
        let colorScheme: ColorScheme = appearance == .dark ? .dark : .light
        return NSHostingView(rootView: content.environment(\.colorScheme, colorScheme))
    }

    /// Writes the bitmap to `ZENIT_DESIGN_QA_OUT/<name>.png` when the variable is set.
    static func emit(_ rep: NSBitmapImageRep, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["ZENIT_DESIGN_QA_OUT"],
              !directory.isEmpty,
              let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? data.write(to: url.appendingPathComponent("\(name).png"))
    }

    /// Fraction of sampled pixels that are painted, and fraction of those that are dark.
    static func coverage(_ rep: NSBitmapImageRep) -> (painted: Double, dark: Double, distinct: Int) {
        var painted = 0, dark = 0, total = 0
        var colours = Set<UInt32>()
        let step = 4
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                total += 1
                let colour = pixel(rep, x, y)
                guard colour.a > 127 else { continue }
                painted += 1
                let luminance = (0.2126 * Double(colour.r) + 0.7152 * Double(colour.g) + 0.0722 * Double(colour.b)) / 255
                if luminance < 0.35 { dark += 1 }
                let key = (UInt32(colour.r >> 3) << 10) | (UInt32(colour.g >> 3) << 5) | UInt32(colour.b >> 3)
                colours.insert(key)
            }
        }
        let paintedFraction = total == 0 ? 0 : Double(painted) / Double(total)
        let darkFraction = painted == 0 ? 0 : Double(dark) / Double(painted)
        return (paintedFraction, darkFraction, colours.count)
    }

    // MARK: - Fixtures

    /// A mock environment with an area measurement selected, the state the mockup shows.
    static func makeEnvironment() -> ProjectShellEnvironment {
        let environment = ProjectShellEnvironment.mock()
        if let area = environment.canvas.visibleMarkups.first(where: { $0.measurementKind == .area })
            ?? ZenitSampleProject.shared.markups.first(where: { $0.measurementKind == .area }) {
            environment.canvas.select(markupIDs: [area.id], additive: false)
        }
        return environment
    }

    static func makeLayout(_ environment: ProjectShellEnvironment) -> ProjectWindowLayoutController {
        let layout = ProjectWindowLayoutController(
            environment: environment,
            // `.firstLaunch`, as the application passes: nothing stored, ledger as its bar.
            store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: "design-qa.layout",
                                            fallback: .firstLaunch)
        )
        layout.presentDetachedLedgerWindow = { _ in }
        layout.detachedLedgerAutosaveName = ""
        return layout
    }

    /// The whole window content — top band, tab row, panels, canvas column, ledger bar — laid out
    /// at the mockup's size. Since the design round the window draws its own top band
    /// (``ProjectTopBandView``) inside the content view, under a transparent titlebar, so the
    /// content view *is* the frame a person sees, apart from the system window controls.
    static func renderShell(_ appearance: Appearance) async -> (ProjectWindowLayoutController, NSBitmapImageRep) {
        let layout = makeLayout(makeEnvironment())
        let rep = await render(layout.view, size: mockupSize, appearance: appearance)
        return (layout, rep)
    }

    /// A horizontal band of a render, top-left origin.
    static func crop(_ rep: NSBitmapImageRep, y: CGFloat, height: CGFloat) -> NSBitmapImageRep? {
        guard let image = rep.cgImage,
              let band = image.cropping(to: CGRect(x: 0, y: y, width: CGFloat(image.width), height: height))
        else { return nil }
        return NSBitmapImageRep(cgImage: band)
    }

    // MARK: - Region renders

    @Test("The window's own top band renders off screen, brand, tools and workspace group on dark chrome")
    func topBand() async throws {
        for appearance in [Appearance.dark, .light] {
            let (layout, whole) = await Self.renderShell(appearance)
            let band = try #require(layout.topBand, "the window draws its top band in its content view")
            #expect(layout.isTopBandShown)
            let rep = try #require(Self.crop(whole, y: 0, height: band.preferredHeight))
            Self.emit(rep, name: "toolbar-\(appearance.rawValue)")
            let stats = Self.coverage(rep)
            #expect(rep.pixelsWide == Int(Self.mockupSize.width))
            #expect(stats.painted > 0.95, "top band must paint its whole strip; painted \(stats.painted)")
            #expect(stats.distinct > 8, "top band renders more than a flat fill; \(stats.distinct) colours")
            if appearance == .dark {
                #expect(stats.dark > 0.7, "the dark top band is dark chrome; dark fraction \(stats.dark)")
            }
        }
    }

    /// The sRGB bytes at a pixel, 0…255. Read raw: `colorAt` hands back a device-RGB colour
    /// whose conversion goes through the main display's profile and lifts dark tones.
    static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var p = [Int](repeating: 0, count: 4)
        rep.getPixel(&p, atX: x, y: y)
        return (p[0], p[1], p[2], p[3])
    }

    @Test("The harness reproduces a token's dark value exactly, so sampled colours can be trusted")
    func pipelineIsColourFaithful() async throws {
        for token in [ZPDFColorToken.background, .surface, .canvasBackdrop, .accent] {
            let view = ZPDFPanelBackgroundView(token: token)
            let rep = await Self.render(view, size: NSSize(width: 16, height: 16), appearance: .dark)
            let sampled = Self.pixel(rep, 8, 8)
            let value = ZPDFColor.rgba(token, .dark)
            let expected = (Int((value.red * 255).rounded()), Int((value.green * 255).rounded()),
                            Int((value.blue * 255).rounded()))
            let delta = max(abs(sampled.r - expected.0), abs(sampled.g - expected.1), abs(sampled.b - expected.2))
            #expect(delta <= 2, "\(token): sampled \(sampled), token \(value.hexString)")
        }
    }

    @Test("The document tab bar renders off screen")
    func tabBar() async throws {
        let environment = Self.makeEnvironment()
        let view = Self.host(DocumentTabBarView(model: environment.tabBar), appearance: .dark)
        let size = NSSize(width: Self.mockupSize.width, height: ProjectWindowLayoutController.tabBarHeight + 14)
        let rep = await Self.render(view, size: size, appearance: .dark)
        Self.emit(rep, name: "tabs-dark")
        #expect(Self.coverage(rep).distinct > 3)
    }

    @Test("The canvas top bar renders off screen at the mockup's canvas width")
    func canvasTopBar() async throws {
        let environment = Self.makeEnvironment()
        let view = Self.host(CanvasTopBar(environment: environment), appearance: .dark)
        let rep = await Self.render(view, size: NSSize(width: 1_076, height: 52), appearance: .dark)
        Self.emit(rep, name: "canvasbar-dark")
        #expect(Self.coverage(rep).distinct > 3, "the canvas top bar draws its controls")
    }

    @Test("The Navigator renders off screen at the mockup's width")
    func navigator() async throws {
        let environment = Self.makeEnvironment()
        let layout = Self.makeLayout(environment)
        let view = Self.host(NavigatorSidebar(environment: environment, panelState: layout.panelState), appearance: .dark)
        let size = NSSize(width: Self.navigatorWidth, height: 772)
        let rep = await Self.render(view, size: size, appearance: .dark)
        Self.emit(rep, name: "navigator-dark")
        let stats = Self.coverage(rep)
        #expect(stats.painted > 0.9, "Navigator paints its whole column; painted \(stats.painted)")
        #expect(stats.dark > 0.6, "Navigator is dark chrome; dark fraction \(stats.dark)")
    }

    @Test("The Inspector renders off screen with an area measurement selected")
    func inspector() async throws {
        let environment = Self.makeEnvironment()
        let layout = Self.makeLayout(environment)
        let view = Self.host(InspectorPanel(environment: environment, panelState: layout.panelState), appearance: .dark)
        let size = NSSize(width: Self.inspectorWidth, height: 772)
        let rep = await Self.render(view, size: size, appearance: .dark)
        Self.emit(rep, name: "inspector-dark")
        let stats = Self.coverage(rep)
        #expect(stats.painted > 0.9, "Inspector paints its whole column; painted \(stats.painted)")
        #expect(stats.dark > 0.6, "Inspector is dark chrome; dark fraction \(stats.dark)")
    }

    @Test("The Quantity Ledger pane renders off screen, as a bar and expanded")
    func ledger() async throws {
        let environment = Self.makeEnvironment()
        let layout = Self.makeLayout(environment)
        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.fix2c2.tests")
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let pane = QuantityLedgerPane(
            environment: environment,
            panelState: layout.panelState,
            preferences: LedgerPanePreferences(defaults: defaults)
        )
        for (name, height) in [("ledger-bar-dark", Self.ledgerBarHeight), ("ledger-expanded-dark", CGFloat(260))] {
            let view = Self.host(pane, appearance: .dark)
            let rep = await Self.render(view, size: NSSize(width: Self.mockupSize.width, height: height), appearance: .dark)
            Self.emit(rep, name: name)
            #expect(Self.coverage(rep).distinct > 3, "\(name) renders content")
        }
    }

    @Test("The canvas placeholder renders off screen at the mockup's canvas size")
    func canvas() async throws {
        let environment = Self.makeEnvironment()
        let view = Self.host(CanvasHostPlaceholder(environment: environment), appearance: .dark)
        let rep = await Self.render(view, size: NSSize(width: 1_080, height: 716), appearance: .dark)
        Self.emit(rep, name: "canvas-dark")
        #expect(Self.coverage(rep).distinct > 3)
    }

    @Test("The whole shell composes at 1672 × 941 off screen, in dark and light")
    func wholeShell() async throws {
        for appearance in [Appearance.dark, .light] {
            let (_, rep) = await Self.renderShell(appearance)
            Self.emit(rep, name: "shell-\(appearance.rawValue)")
            let stats = Self.coverage(rep)
            #expect(rep.pixelsWide == Int(Self.mockupSize.width) && rep.pixelsHigh == Int(Self.mockupSize.height))
            #expect(stats.painted > 0.95, "the shell paints edge to edge; painted \(stats.painted)")
            if appearance == .dark {
                #expect(stats.dark > 0.5, "the dark shell is dark chrome around a light page; dark \(stats.dark)")
            }
        }
    }
}
