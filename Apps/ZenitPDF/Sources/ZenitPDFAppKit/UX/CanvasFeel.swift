import AppKit
import ZPDFAppCore
import ZPDFUIPresentation

/// Canvas preferences a person sets once (NL-UX-14, NL-UX-16): whether a mouse wheel zooms, and
/// the smart-zoom target. Stored as one blob in the process defaults (the standard defaults in
/// the shipping app, memory elsewhere).
///
/// The haptic snap confirmation that used to live here is gone (R-009): the taps
/// were unbearable and the app makes no sound or tap on pointer movement. A
/// blob an older build stored still carries `snapHaptics`; decoding ignores it.
struct ZenitCanvasPreferences: Codable, Equatable {
    /// The zoom a two-finger double-tap goes to from the fitted page, as a factor (2 = 200 %).
    var smartZoomLevel: Double = 2.0
    /// A mouse wheel notch without ⌘ zooms about the pointer instead of scrolling (NL-UX-14).
    /// Off by default. Only a phase-less, coarse wheel event is affected: a trackpad or a
    /// gesture mouse still scrolls, and ⌘ still zooms either way.
    var wheelZooms: Bool = false

    init(smartZoomLevel: Double = 2.0, wheelZooms: Bool = false) {
        self.smartZoomLevel = smartZoomLevel
        self.wheelZooms = wheelZooms
    }

    private enum CodingKeys: String, CodingKey { case smartZoomLevel, wheelZooms }

    /// Every key is optional: synthesized decoding would refuse a blob stored before a field
    /// existed, and the whole preference set would fall back to its defaults — losing a
    /// person's smart-zoom level the day `wheelZooms` arrived.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        smartZoomLevel = try container.decodeIfPresent(Double.self, forKey: .smartZoomLevel) ?? 2.0
        wheelZooms = try container.decodeIfPresent(Bool.self, forKey: .wheelZooms) ?? false
    }

    static let defaultsKey = "Zenit.CanvasPreferences"

    @MainActor
    static var current: ZenitCanvasPreferences {
        get { ZenitProcessDefaults.layout.decode(ZenitCanvasPreferences.self, forKey: defaultsKey) ?? ZenitCanvasPreferences() }
        set { ZenitProcessDefaults.layout.encode(newValue, forKey: defaultsKey) }
    }
}

// MARK: - Smart zoom (NL-UX-16)

/// Two-finger double-tap on the canvas: from the fitted page to the smart-zoom level around
/// the pointer, and from anywhere else back to the fitted page — the trackpad's standard
/// "smart magnify" gesture, which the canvas ignored.
enum CanvasSmartZoom {

    /// What a double-tap does at `zoom`, given the fitted-page zoom.
    enum Step: Equatable {
        /// Zoom in to this level, about the pointer.
        case zoomIn(to: Double)
        /// Go back to the fitted page.
        case fit
    }

    /// Within 3 % of the fitted zoom counts as "at fit": a page fitted by a window resize is
    /// rarely a bit-exact match.
    static func step(currentZoom: Double, fitZoom: Double, target: Double) -> Step {
        guard fitZoom > 0 else { return .fit }
        let atFit = abs(currentZoom - fitZoom) / fitZoom < 0.03
        return atFit ? .zoomIn(to: max(target, fitZoom * 1.5)) : .fit
    }
}

extension PDFCanvasViewController {

    /// The fitted-page zoom for the page on screen, without changing the viewport: the
    /// presenter's own fit rule, the one Fit Page applies (S-003). This used to be a second copy
    /// that fitted the crop box under the PDF's `/Rotate` into the whole view, so on a sheet
    /// turned or cropped in the view it disagreed with Fit Page by more than the 3 % "at fit"
    /// tolerance, and a double-tap at fit asked for Fit Page again — a no-op.
    func fittedZoomForSmartMagnify() -> Double? {
        core.canvas.fitZoom
    }

    /// The trackpad's smart-magnify gesture (two-finger double-tap).
    override public func smartMagnify(with event: NSEvent) {
        let current = core.canvas.viewport.zoom
        let fit = fittedZoomForSmartMagnify() ?? current
        switch CanvasSmartZoom.step(currentZoom: current, fitZoom: fit, target: ZenitCanvasPreferences.current.smartZoomLevel) {
        case .zoomIn(let target):
            zoom(by: target / max(current, 1e-9), aboutWindowPoint: event.locationInWindow)
        case .fit:
            onShellCommand?(.fitPage)
        }
    }
}
