import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFRenderer

/// One complete, reproducible scene: a page, its markups, a selection, a snap state and a
/// viewport. Everything a golden image needs, and nothing that varies between runs.
public struct RenderScene: Sendable {
    /// File-safe name; the golden PNG is `<name>.png`.
    public let name: String
    /// One line saying what the scene is for, printed by the regeneration tool.
    public let purpose: String
    public let page: PageDescriptor
    public let markups: [RenderableMarkup]
    public let selection: SelectionSnapshot
    public let snapFeedback: RenderSnapFeedback?
    public let viewport: RenderViewport

    public init(
        name: String,
        purpose: String,
        page: PageDescriptor,
        markups: [RenderableMarkup],
        selection: SelectionSnapshot = .empty,
        snapFeedback: RenderSnapFeedback? = nil,
        viewport: RenderViewport
    ) {
        self.name = name
        self.purpose = purpose
        self.page = page
        self.markups = markups
        self.selection = selection
        self.snapFeedback = snapFeedback
        self.viewport = viewport
    }

    /// Pushes the scene into a renderer and rasterises it.
    public func render(with renderer: any OffscreenMarkupRendering) throws -> RasterImage {
        renderer.update(
            page: page,
            markups: markups,
            selection: selection,
            snapFeedback: snapFeedback,
            viewport: viewport
        )
        return try renderer.renderOffscreen()
    }
}

/// Fixed identifiers, so a scene's markup ids are the same in every process.
public enum SceneIdentity {
    public static let documentID = DocumentID(
        UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301") ?? UUID()
    )
    public static let pageID = PageID(
        UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3302") ?? UUID()
    )

    /// A US Letter page at the requested rotation, with an optional crop-box offset so the
    /// crop-translation step of the coordinate contract is exercised rather than assumed away.
    public static func page(
        rotation: PageRotation = .degrees0,
        cropInset: Double = 0,
        origin: PDFPoint = PDFPoint(x: 0, y: 0)
    ) -> PageDescriptor {
        let media = PDFRect(x: origin.x, y: origin.y, width: 612, height: 792)
        let crop = PDFRect(
            x: origin.x + cropInset,
            y: origin.y + cropInset,
            width: 612 - 2 * cropInset,
            height: 792 - 2 * cropInset
        )
        return PageDescriptor(
            id: pageID,
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: media, crop: crop),
            rotation: rotation,
            userUnit: 1.0
        )
    }
}

/// The Zenit takeoff palette, as plain colour values. The design system owns the real one; these
/// exist so a golden scene is a fixed set of numbers.
public enum SceneColors {
    public static let ink = RGBAColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)
    public static let concrete = RGBAColor(red: 0.36, green: 0.55, blue: 0.85, alpha: 0.45)
    public static let steel = RGBAColor(red: 0.85, green: 0.42, blue: 0.20, alpha: 0.55)
    public static let insulation = RGBAColor(red: 0.42, green: 0.72, blue: 0.38, alpha: 0.5)
    public static let outline = RGBAColor(red: 0.20, green: 0.28, blue: 0.52, alpha: 1)
    public static let count = RGBAColor(red: 0.75, green: 0.15, blue: 0.30, alpha: 1)
    public static let label = RGBAColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    /// The committed measurement ink, `#50D6DE`, as fixed numbers.
    public static let measurement = RGBAColor(red: 0x50 / 255.0, green: 0xD6 / 255.0, blue: 0xDE / 255.0, alpha: 1)
    /// The measurement fill: the ink at the visual reference's ~18 % alpha.
    public static let measurementFill = RGBAColor(red: 0x50 / 255.0, green: 0xD6 / 255.0, blue: 0xDE / 255.0, alpha: 0.18)

    public static let all: [RGBAColor] = [ink, concrete, steel, insulation, outline, count, label]
}
