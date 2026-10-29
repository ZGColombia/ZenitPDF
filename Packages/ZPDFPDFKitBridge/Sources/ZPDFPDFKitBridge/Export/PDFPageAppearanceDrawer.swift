import CoreGraphics
import Foundation
import PDFKit
import ZPDFContracts

/// Draws a drawing's complete page appearance — the content stream **and** the file's own
/// annotation appearances — into a context the caller owns (BH-079).
///
/// A flatten or print that replays only the content stream (`CGContext.drawPDFPage`) never
/// draws annotation appearances: revision clouds, stamps and linework that another tool stored
/// as annotations vanish from the exported sheet. `PDFPage.draw(with:to:)` draws them. This type
/// is that path, shaped for the export layer's synchronous `FlattenPageAppearanceDrawer`
/// closure: open once, draw each page on the thread that owns the context.
///
/// ### Layer visibility
///
/// Annotations bound to a layer the project hides are switched off through
/// `PDFAnnotation.shouldDisplay`, which `draw(with:to:)` honours. Page *content* bound to a
/// layer is different: PDFKit has no optional-content toggle, so a page whose content carries
/// a layer whose effective visibility differs from the file's default cannot be drawn truthfully
/// here, and ``drawPageAppearance(sourcePageIndex:into:rect:page:)`` returns `false` for it so
/// the caller's next source draws it and the omission can be named.
///
/// ### Zenit's own annotations
///
/// A drawing that went through Save Markups into PDF carries one annotation per Zenit markup,
/// named by the markup's id. An output that paints the project's markups (Marked, Print) or
/// promises none (Clean) must not draw those as well, or every markup appears twice (L-23). With
/// `hidingZenitAnnotations`, each page's annotations that stand for one of the given markups —
/// the rule of ``ZenitAnnotationOwnership/supersedes(name:subject:markupNames:)`` — are switched
/// off through `shouldDisplay` before it is drawn. Everybody else's are drawn as before,
/// including the ones a colleague's Zenit wrote for markups this project does not hold: the
/// canvas draws those too, so an output that dropped them lost content without a word.
///
/// PDFKit parses the drawing inside the application; this type adds no parser. It reads the
/// same file the canvas already opened, through the same engine barrier.
public final class PDFPageAppearanceDrawer {

    private let document: PDFDocument
    /// Source pages whose content cannot honour the project's layer visibility.
    private let pagesNeedingContentVisibility: Set<Int>
    /// The canonical names of the markups whose Zenit-written annotations are left undrawn, or
    /// `nil` to draw every annotation.
    private let hiddenMarkupNames: Set<String>?
    /// Pages whose Zenit-written annotations have been switched off already.
    private var pagesWithZenitAnnotationsHidden: Set<Int> = []

    /// Opens `url` for drawing.
    ///
    /// - Parameters:
    ///   - password: the password the user supplied for an encrypted drawing, if any.
    ///   - layerTree: the drawing's layer catalogue, when it has one.
    ///   - bindings: the drawing's annotation→layer bindings.
    ///   - hiddenLayerIDs: the layers the project currently hides.
    ///   - hidingZenitAnnotations: the names (`/NM`, a markup id's `uuidString`) of the markups
    ///     whose Zenit-written annotations are left undrawn (L-23) — every markup of the session,
    ///     painted or not. Any set, even an empty one, also leaves out the first export's unnamed
    ///     `/Subj (Zenit)` annotations. `nil` draws every annotation.
    /// - Returns: `nil` when PDFKit will not open the file, or it stays locked.
    public init?(
        url: URL,
        password: String? = nil,
        layerTree: PDFLayerTree? = nil,
        bindings: [AnnotationLayerBindingReader.Binding] = [],
        hiddenLayerIDs: Set<PDFLayerID> = [],
        hidingZenitAnnotations markupNames: Set<String>? = nil
    ) {
        let opened: PDFDocument?? = try? EngineBarrier.guarded("appearanceOpen") { PDFDocument(url: url) }
        guard let document = opened.flatMap({ $0 }) else { return nil }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password), !document.isLocked else {
                return nil
            }
        }
        self.document = document
        self.hiddenMarkupNames = markupNames.map { Set($0.map(ZenitAnnotationOwnership.canonicalName)) }

        for binding in bindings {
            guard let page = document.page(at: binding.pageIndex),
                  let annotation = PDFKitDocumentProvider.matchAnnotation(binding, in: page.annotations)
            else { continue }
            annotation.shouldDisplay = binding.shouldDisplay(hiddenLayerIDs: hiddenLayerIDs)
        }

        var affected: Set<Int> = []
        if let layerTree {
            let differing = Set(layerTree.layers.compactMap { layer -> PDFLayerID? in
                let projectVisible = !hiddenLayerIDs.contains(layer.id)
                return projectVisible == layer.isVisibleByDefault ? nil : layer.id
            })
            if !differing.isEmpty {
                for binding in layerTree.pageBindings
                where binding.propertyNamesByLayer.keys.contains(where: differing.contains) {
                    affected.insert(binding.pageIndex)
                }
            }
        }
        pagesNeedingContentVisibility = affected
    }

    /// Source pages this drawer refuses because their content carries a layer the project
    /// shows or hides differently from the file.
    public var pagesRefusedForLayerVisibility: Set<Int> { pagesNeedingContentVisibility }

    /// Draws page `sourcePageIndex` onto `rect`.
    ///
    /// With a descriptor, the page is mapped by the descriptor's crop box and `/Rotate` — the
    /// geometry the markups on the same sheet are mapped with — stretched onto `rect`. Without
    /// one, the page's own crop box and rotation are used the same way. Content outside the crop
    /// box stays outside. The graphics state is restored before returning.
    ///
    /// - Returns: `false` when the page is missing, degenerate, raised inside PDFKit, or cannot
    ///   honour the project's layer visibility — the caller's next source then draws it.
    public func drawPageAppearance(
        sourcePageIndex: Int,
        into context: CGContext,
        rect: CGRect,
        page descriptor: PageDescriptor?
    ) -> Bool {
        guard !pagesNeedingContentVisibility.contains(sourcePageIndex),
              sourcePageIndex >= 0, sourcePageIndex < document.pageCount,
              let page = document.page(at: sourcePageIndex)
        else { return false }

        if let hiddenMarkupNames, pagesWithZenitAnnotationsHidden.insert(sourcePageIndex).inserted {
            for annotation in page.annotations where Self.supersedes(annotation, markupNames: hiddenMarkupNames) {
                annotation.shouldDisplay = false
            }
        }

        let crop: CGRect
        let rotation: Int
        if let descriptor {
            let box = descriptor.visibleBox
            crop = CGRect(x: box.origin.x, y: box.origin.y, width: box.size.width, height: box.size.height)
            rotation = descriptor.rotation.rawValue
        } else {
            crop = page.bounds(for: .cropBox).standardized
            rotation = PageRotationMath.normalised(page.rotation)
        }
        guard let toSheet = PageDisplayGeometry.pageToRect(box: crop, rotation: rotation, rect: rect) else { return false }

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.concatenate(toSheet)
        context.clip(to: crop)
        // `draw(with:to:)` applies `transform(for:)` — the box origin and the page's own
        // rotation — before drawing. Undoing it leaves page space, which the mapping above
        // already carries onto the sheet, so the descriptor's geometry is the only geometry.
        context.concatenate(page.transform(for: .mediaBox).inverted())
        do {
            try EngineBarrier.guarded("appearanceDraw") { page.draw(with: .mediaBox, to: context) }
        } catch {
            return false
        }
        return true
    }

    /// Whether `annotation` is Zenit's picture of one of `markupNames` (canonical), or one of the
    /// first export's unnamed `/Subj (Zenit)` annotations. The owner key alone does not count: a
    /// colleague's annotation for a markup this project does not hold is drawn, as on the canvas.
    static func supersedes(_ annotation: PDFAnnotation, markupNames: Set<String>) -> Bool {
        let name = (annotation.value(forAnnotationKey: PDFAnnotationKeys.name) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (annotation.value(forAnnotationKey: PDFAnnotationKeys.zenitName) as? String)
        return ZenitAnnotationOwnership.supersedes(
            name: name,
            subject: annotation.value(forAnnotationKey: PDFAnnotationKeys.subject) as? String,
            markupNames: markupNames
        )
    }
}
