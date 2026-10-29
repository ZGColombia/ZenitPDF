import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The precision magnifier shown while placing a point at high zoom.
///
/// The loupe chrome itself belongs to the design system; what this adds is the measurement
/// meaning: which page point the crosshair is over, what the snap would be, and — when a scale
/// is set — where that point sits in real-world terms.
public struct MeasurementLoupe<Content: View>: View {

    private let pagePoint: PDFPointValue
    private let magnification: Double
    private let snapCandidate: SnapFeedbackSnapshot?
    private let scale: ScaleSummary?
    private let formatter: MeasurementValueFormatter
    private let diameter: CGFloat
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - pagePoint: the page point under the crosshair.
    ///   - magnification: how much the content is magnified, shown as a badge.
    ///   - snapCandidate: the acquired candidate, named under the lens.
    ///   - scale: the active scale, used for the real-world readout.
    ///   - formatter: unit and precision settings.
    ///   - diameter: the lens size in points.
    ///   - content: the magnified canvas content, already rendered by the caller.
    public init(
        pagePoint: PDFPointValue,
        magnification: Double = 4,
        snapCandidate: SnapFeedbackSnapshot? = nil,
        scale: ScaleSummary? = nil,
        formatter: MeasurementValueFormatter = MeasurementValueFormatter(),
        diameter: CGFloat = 132,
        @ViewBuilder content: () -> Content
    ) {
        self.pagePoint = pagePoint
        self.magnification = magnification
        self.snapCandidate = snapCandidate
        self.scale = scale
        self.formatter = formatter
        self.diameter = diameter
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: snapCandidate == nil ? 0 : ZPDFSpacing.xs) {
            ZPDFLoupe(
                chrome: .circle,
                diameter: diameter,
                showsCrosshair: true,
                readout: coordinateReadout,
                magnification: magnification
            ) {
                content
            }

            MeasurementLoupeChip(snap: snapCandidate, reduceMotion: reduceMotion)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(NSLocalizedString("Precision magnifier", comment: "Accessibility label for the measurement loupe"))
        )
        .accessibilityValue(Text(accessibilityValue))
    }

    /// Page coordinates, plus the real-world offset when a scale exists.
    private var coordinateReadout: String {
        MeasurementLoupeReadout.coordinates(pagePoint: pagePoint, scale: scale, formatter: formatter)
    }

    private var accessibilityValue: String {
        var value = MeasurementInputStateMachine.coordinateDescription(pagePoint)
        if let snapCandidate {
            value += ", " + snapCandidate.accessibilityAnnouncement
        }
        value += ", " + String(
            format: NSLocalizedString("magnified %.1f times", comment: "Accessibility: loupe magnification"),
            magnification
        )
        return value
    }
}

/// A separate view graph keeps the chip's 90 ms transition out of the lens graph. In an
/// off-screen window SwiftUI can tick an animation on every run-loop turn; wrapping the whole
/// lens made each tick redraw its coordinates, chrome and picture as well as the tiny chip.
private struct MeasurementLoupeChip: NSViewRepresentable {
    let snap: SnapFeedbackSnapshot?
    let reduceMotion: Bool

    func makeNSView(context: Context) -> MeasurementLoupeChipHost {
        MeasurementLoupeChipHost(snap: snap, reduceMotion: reduceMotion)
    }

    func updateNSView(_ host: MeasurementLoupeChipHost, context: Context) {
        host.update(snap: snap, reduceMotion: reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeasurementLoupeChipHost, context: Context) -> CGSize? {
        nsView.chipSize
    }
}

/// SwiftUI draws the static chip; Core Animation owns its opacity transition. A nested
/// SwiftUI animation still asks the containing window to lay out on every tick, even with
/// NSHostingView.sizingOptions disabled. Native layer animation never asks SwiftUI to tick.
final class MeasurementLoupeChipHost: NSView {
    private let contentHost = NSHostingView(rootView: MeasurementLoupeChipContent(snapCandidate: nil))
    private var kind: SnapCandidateKind?
    private var source: String?
    private var reduceMotion: Bool
    private(set) var chipSize: CGSize = .zero

    init(snap: SnapFeedbackSnapshot?, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        contentHost.wantsLayer = true
        contentHost.sizingOptions = [.intrinsicContentSize]
        addSubview(contentHost)
        update(snap: snap, reduceMotion: reduceMotion)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(snap:reduceMotion:)") }

    func update(snap: SnapFeedbackSnapshot?, reduceMotion: Bool) {
        guard kind != snap?.kind || source != snap?.sourceLabel || self.reduceMotion != reduceMotion else { return }
        let wasVisible = kind != nil
        let changesKind = kind != snap?.kind
        kind = snap?.kind
        source = snap?.sourceLabel
        self.reduceMotion = reduceMotion
        // Keep the outgoing content alive for its fade, even after the outer lens drops its
        // occupied space. The native child keeps its frame; no SwiftUI removal transition runs.
        if let snap {
            contentHost.rootView = MeasurementLoupeChipContent(snapCandidate: snap)
            chipSize = contentHost.fittingSize
            contentHost.frame.size = chipSize
        } else {
            chipSize = .zero
        }
        invalidateIntrinsicContentSize()
        guard let layer = contentHost.layer else { return }
        let opacity: Float = snap == nil ? 0 : 1
        let previousOpacity = layer.presentation()?.opacity ?? (wasVisible ? 1 : 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        layer.removeAllAnimations()
        if !reduceMotion {
            if wasVisible != (snap != nil) {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = previousOpacity
                fade.toValue = opacity
                fade.duration = ZPDFMotion.micro.duration
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "loupeChipOpacity")
            } else if changesKind {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = ZPDFMotion.micro.duration
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "loupeChipKind")
            }
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // Centre the retained outgoing chip when this container has already collapsed.
        contentHost.frame.origin = CGPoint(x: (bounds.width - contentHost.frame.width) / 2, y: 0)
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { chipSize }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

struct MeasurementLoupeChipContent: View {
    let snapCandidate: SnapFeedbackSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            if let snapCandidate {
                HStack(spacing: ZPDFSpacing.xs) {
                    ZPDFGlyphView(.measurement(.vectorSnap), size: ZPDFSpacing.Control.iconSmall)
                        .foregroundStyle(ZPDFColor.snapHighlight)
                    Text(snapCandidate.kind.displayName)
                        .zpdfText(.caption, .textPrimary)
                    if !snapCandidate.sourceLabel.isEmpty {
                        Text(snapCandidate.sourceLabel)
                            .zpdfText(.caption, .textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, ZPDFSpacing.s)
                .padding(.vertical, 1)
                .zpdfControlBackground(fill: .elevated, cornerRadius: ZPDFRadius.hairline)
            }
        }
        .fixedSize()
    }
}

/// The caption under the loupe, as one rule the lens and its host share.
///
/// Public so a host that positions the lens can tell when the caption changed *shape*: its
/// figures are tabular (`monoNumeric`), so a new coordinate with the same non-digit characters
/// has the same width and the lens needs no new measurement (Z15, iteration 4).
public enum MeasurementLoupeReadout {

    /// Page coordinates, plus the real-world offset when a scale exists.
    public static func coordinates(
        pagePoint: PDFPointValue,
        scale: ScaleSummary?,
        formatter: MeasurementValueFormatter
    ) -> String {
        let base = String(
            format: NSLocalizedString(
                "%1$.2f, %2$.2f pt",
                comment: "Loupe readout: page-space coordinates"
            ),
            pagePoint.x,
            pagePoint.y
        )
        guard let scale else { return base }
        let live = formatter.forLiveReadout
        return base + "  ·  "
            + live.lengthString(metres: Decimal(pagePoint.x * scale.sx)) + ", "
            + live.lengthString(metres: Decimal(pagePoint.y * scale.sy))
    }
}
