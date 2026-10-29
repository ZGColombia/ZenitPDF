import CoreGraphics
import Foundation
import ZPDFContracts

/// Draws one page's complete appearance into a context the caller owns — the page content
/// **and** the drawing's own annotation appearances, with the project's layer visibility.
///
/// This is the seam the PDFKit bridge fills (BH-079): `PDFPage.draw(with:to:)` renders
/// annotation appearances (revision clouds, stamps, annotation-borne linework) that a replay of
/// the content stream never draws. The export layer cannot call PDFKit itself — the bridge owns
/// that engine and its barrier — so it takes the drawing as a closure the composition root builds
/// from the bridge.
///
/// - Returns from the closure: `true` when the page was drawn completely; `false` to let the
///   next source try.
public typealias FlattenPageAppearanceDrawer = (
    _ sourcePageIndex: Int,
    _ context: CGContext,
    _ rect: CGRect,
    _ page: PageDescriptor?
) -> Bool

/// A page-content source that prefers a complete-appearance drawer and falls back, page by
/// page, to another source (normally ``CGPDFPageContentSource``).
///
/// The fallback keeps the old behaviour for any page the preferred drawer cannot draw — an
/// encrypted page, a bridge that is not ready — so preferring the richer source can never make
/// an export worse than it was. ``fellBackPages`` records which pages needed the fallback, so
/// the caller's omission note can name exactly those sheets instead of every sheet.
public final class PreferredPageContentSource: FlattenPageContentDrawing {

    private let preferred: FlattenPageAppearanceDrawer
    private let fallback: (any FlattenPageContentDrawing)?

    /// Source pages the preferred drawer refused and the fallback drew (or left white).
    public private(set) var fellBackPages: Set<Int> = []

    /// Creates the source.
    public init(preferred: @escaping FlattenPageAppearanceDrawer, fallback: (any FlattenPageContentDrawing)?) {
        self.preferred = preferred
        self.fallback = fallback
    }

    public func drawPageContent(sourcePageIndex: Int, into context: CGContext, rect: CGRect) -> Bool {
        if drawPreferred(sourcePageIndex, context, rect, nil) { return true }
        fellBackPages.insert(sourcePageIndex)
        return fallback?.drawPageContent(sourcePageIndex: sourcePageIndex, into: context, rect: rect) ?? false
    }

    public func drawPageContent(
        sourcePageIndex: Int,
        into context: CGContext,
        rect: CGRect,
        page: PageDescriptor
    ) -> Bool {
        if drawPreferred(sourcePageIndex, context, rect, page) { return true }
        fellBackPages.insert(sourcePageIndex)
        return fallback?.drawPageContent(sourcePageIndex: sourcePageIndex, into: context, rect: rect, page: page) ?? false
    }

    /// Runs the preferred drawer inside its own graphics-state save, so a drawer that fails
    /// half-way cannot leave a transform or clip behind for the fallback.
    private func drawPreferred(_ index: Int, _ context: CGContext, _ rect: CGRect, _ page: PageDescriptor?) -> Bool {
        context.saveGState()
        defer { context.restoreGState() }
        return preferred(index, context, rect, page)
    }
}
