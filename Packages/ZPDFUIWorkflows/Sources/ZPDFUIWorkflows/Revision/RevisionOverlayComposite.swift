import CoreGraphics
import Foundation
import ZPDFUIPresentation

/// One composited picture of the stacked revisions, and everything the interface has to
/// be able to say about it.
///
/// The composite is produced by the compare engine from the same page rasters Revision
/// Compare obtains through `GeometryService` — this package never sees a PDF, a document
/// handle or a file URL, and could not parse one if it wanted to. What arrives here is a
/// finished bitmap plus the geometry needed to place a click back on the sheet.
///
/// `CGImage` is `Sendable`, which is why this value can be handed across from whichever
/// executor did the compositing.
public struct RevisionOverlayComposite: Sendable, Identifiable {

    /// Stable identity, so a view can tell one composite from the next without comparing
    /// megabytes of pixels.
    public let id: UUID
    /// The composited picture.
    public let image: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The page box the composite covers, in the baseline revision's page space.
    public let pageBox: PDFRectValue
    /// Pixels per PDF point the composite was actually produced at.
    public let scale: Double
    /// Pixels per PDF point that were asked for — the canvas zoom times the backing scale.
    public let requestedScale: Double
    /// Which layers contributed, bottom first. A hidden layer is not in this list.
    public let contributingLayerIDs: [RevisionSummary.ID]
    /// How long the composite took to produce, end to end.
    public let elapsedNanoseconds: UInt64

    /// Creates a composite.
    public init(
        id: UUID = UUID(),
        image: CGImage,
        pixelWidth: Int,
        pixelHeight: Int,
        pageBox: PDFRectValue,
        scale: Double,
        requestedScale: Double,
        contributingLayerIDs: [RevisionSummary.ID],
        elapsedNanoseconds: UInt64
    ) {
        self.id = id
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pageBox = pageBox
        self.scale = scale
        self.requestedScale = requestedScale
        self.contributingLayerIDs = contributingLayerIDs
        self.elapsedNanoseconds = elapsedNanoseconds
    }

    /// Whether the composite is coarser than the canvas is currently showing.
    public var isReducedResolution: Bool { scale < requestedScale - 1e-9 }

    /// The composite's linear resolution as a fraction of what was asked for, `0…1`.
    public var resolutionFraction: Double {
        guard requestedScale > 0 else { return 1 }
        return min(1, scale / requestedScale)
    }

    /// A localized sentence stating what resolution the picture is at.
    ///
    /// Shown whenever the composite is coarser than the canvas. An overlay that is quietly
    /// blurrier than the drawing behind it is an overlay a person will read a missing hairline
    /// off, so Zenit says the number rather than hoping nobody looks.
    public var resolutionSummary: String? {
        guard isReducedResolution else { return nil }
        let format = NSLocalizedString(
            "Composited at %1$d %% of the zoom you are at: the whole sheet at this zoom would need %2$@ pixels. Fine detail is softer here than on the drawing.",
            comment: "Statement that the overlay composite is coarser than the canvas: percentage, pixel count"
        )
        let requestedPixels = Double(pixelWidth) * Double(pixelHeight)
            / max(1e-9, resolutionFraction * resolutionFraction)
        return String(
            format: format,
            Int((resolutionFraction * 100).rounded()),
            Self.pixelCountFormatter.string(from: NSNumber(value: requestedPixels.rounded()))
                ?? "\(Int(requestedPixels.rounded()))"
        )
    }

    /// Where a point on the picture falls on the sheet.
    ///
    /// - Parameter unitPoint: `0…1` across and down the image, `y` measured **downwards**
    ///   the way a view reports a click.
    /// - Returns: the page-space point, `y` measured upwards the way PDF does.
    public func pagePoint(atUnitPoint unitPoint: CGPoint) -> PDFPointValue {
        PDFPointValue(
            x: pageBox.minX + Double(unitPoint.x) * pageBox.size.width,
            y: pageBox.minY + (1 - Double(unitPoint.y)) * pageBox.size.height
        )
    }

    private static let pixelCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

/// What the overlay canvas is currently able to show.
public enum RevisionOverlayCompositeStatus: Sendable, Hashable {

    /// Nothing has been asked for yet.
    case idle
    /// A composite is being produced. Any previous one stays on screen while it is.
    case rendering
    /// A composite is on screen and current.
    case ready
    /// The composite could not be produced, and this is why, in one sentence.
    case failed(String)
    /// There is nothing to composite, and this is why — one revision, or none.
    case unavailable(String)

    /// The sentence to show, or `nil` when there is nothing to say.
    public var message: String? {
        switch self {
        case .idle, .ready: return nil
        case .rendering:
            return NSLocalizedString(
                "Stacking the revisions…",
                comment: "Revision Overlay status while the composite is being produced"
            )
        case let .failed(reason): return reason
        case let .unavailable(reason): return reason
        }
    }

    /// Whether a composite is being produced right now.
    public var isRendering: Bool { self == .rendering }
}

/// One line of the legend: which revision a colour on the picture belongs to.
///
/// The legend is part of the feature rather than decoration. Two tinted revisions on one
/// sheet are told apart by hue and by nothing else unless something names them, and hue
/// alone fails for the eight percent of men who cannot separate the two most useful ones.
/// Every entry therefore carries the revision's name, its sheet designation and its
/// colour's spoken name, and the opacity it is drawn at.
public struct RevisionOverlayLegendEntry: Sendable, Hashable, Identifiable {

    public let id: RevisionSummary.ID
    public let revisionName: String
    public let revisionLabel: String
    public let colorName: String
    public let colorRGBA: ColorRGBA
    public let opacity: Double
    /// Where this layer sits in the stack, `1` being the bottom sheet.
    public let position: Int

    public init(
        id: RevisionSummary.ID,
        revisionName: String,
        revisionLabel: String,
        colorName: String,
        colorRGBA: ColorRGBA,
        opacity: Double,
        position: Int
    ) {
        self.id = id
        self.revisionName = revisionName
        self.revisionLabel = revisionLabel
        self.colorName = colorName
        self.colorRGBA = colorRGBA
        self.opacity = opacity
        self.position = position
    }

    /// A localized VoiceOver label naming the revision, its colour and its opacity.
    public var accessibilityLabel: String {
        let format = NSLocalizedString(
            "Layer %1$d, %2$@ %3$@, drawn in %4$@ at %5$d percent",
            comment: "VoiceOver label for a legend entry: position, revision name, revision label, colour name, opacity"
        )
        return String(
            format: format,
            position,
            revisionName,
            revisionLabel,
            colorName,
            Int((opacity * 100).rounded())
        )
    }
}

/// Where the person is in the two-click gesture that marks one alignment point.
public enum RevisionAlignmentCaptureStage: Sendable, Hashable {

    /// Not marking anything; a click on the overlay does nothing.
    case off
    /// Waiting for the click on the feature as the **baseline** sheet draws it.
    case awaitingBaseline
    /// Waiting for the click on the same feature as the **comparison** sheet draws it.
    /// Carries the baseline click, so a cancelled second click loses nothing else.
    case awaitingComparison(PDFPointValue)

    /// Whether a click on the overlay is currently being collected.
    public var isCapturing: Bool { self != .off }

    /// A localized instruction for the step the person is on.
    public var instruction: String? {
        switch self {
        case .off:
            return nil
        case .awaitingBaseline:
            return NSLocalizedString(
                "Click a feature on the sheet as the first revision draws it — a grid intersection or a title-block corner.",
                comment: "Instruction for the first click of an alignment point"
            )
        case .awaitingComparison:
            return NSLocalizedString(
                "Now click the same feature as the other revision draws it. The two clicks are one point.",
                comment: "Instruction for the second click of an alignment point"
            )
        }
    }
}
