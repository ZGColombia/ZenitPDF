import CoreGraphics
import Foundation
import PDFKit

extension PDFKitDocumentProvider {

    // MARK: - Layers

    /// Reads the `/OCProperties` layer catalogue via CoreGraphics.
    ///
    /// PDFKit is deliberately bypassed: `PDFDocument` has no optional-content API, so
    /// there is nothing to route through the engine barrier here — the whole read is a
    /// CoreGraphics catalog walk, bounded by the document's ``DocumentLimits``.
    ///
    /// ### Rendering with layers off — what is honoured where
    ///
    /// - The file's **default** `/D` configuration (its `/OFF` list included) is
    ///   honoured by PDFKit drawing *and* by `CGContextDrawPDFPage`. Default-hidden
    ///   layers stay hidden through either renderer with no work from us.
    /// - **Per-project overrides are honoured by neither.** PDFKit has no layer
    ///   toggle, and CoreGraphics offers no public way to hand
    ///   `CGContextDrawPDFPage` an alternate OC configuration. When the effective
    ///   visibility differs from the document default, the app tier must re-render
    ///   via the CoreGraphics content-stream path (ZPDFRenderer), skipping `BDC /OC`
    ///   sections and `/OC`-tagged XObjects whose group is hidden.
    ///   ``PDFLayerTree/effectiveVisibilityMatchesDocumentDefault(overrides:)`` is the
    ///   test for "is the native render still truthful".
    public func layerTree(of handle: DocumentHandle) async throws -> PDFLayerTree? {
        try checkCancellation()
        let open = try unlockedEntry(handle)
        let coreGraphics = Self.makeCGPDFDocument(
            url: open.origin.fileURL,
            data: open.sourceData,
            password: open.password
        )
        return try LayerCatalogReader.read(document: coreGraphics, limits: open.limits)
    }
}

extension PDFKitDocumentProvider {

    /// Every annotation→layer binding in the document. See ``AnnotationLayerBindingReader``.
    public func annotationLayerBindings(
        of handle: DocumentHandle
    ) async throws -> [AnnotationLayerBindingReader.Binding] {
        try checkCancellation()
        let open = try unlockedEntry(handle)
        guard let coreGraphics = Self.makeCGPDFDocument(
            url: open.origin.fileURL,
            data: open.sourceData,
            password: open.password
        ) else { return [] }
        return AnnotationLayerBindingReader.read(from: coreGraphics, limits: open.limits)
    }

    /// Every annotation→layer binding, and whether the walk was cut short by its budget or by
    /// cancellation. Prefer this to ``annotationLayerBindings(of:)``: a truncated list looks
    /// exactly like a complete one (BH-177).
    public func annotationLayerBindingReport(
        of handle: DocumentHandle
    ) async throws -> AnnotationLayerBindingReader.Report {
        try checkCancellation()
        let open = try unlockedEntry(handle)
        guard let coreGraphics = Self.makeCGPDFDocument(
            url: open.origin.fileURL,
            data: open.sourceData,
            password: open.password
        ) else { return AnnotationLayerBindingReader.Report(bindings: [], wasTruncated: false) }
        return AnnotationLayerBindingReader.readReport(from: coreGraphics, limits: open.limits)
    }

    /// Shows or hides the annotations bound to hidden layers, on the rendering document.
    ///
    /// This is the annotation half of layer visibility, and it deliberately does **not** go
    /// through the content-stream render path: `PDFAnnotation.shouldDisplay` is honoured by
    /// PDFKit's own `draw`, so a drawing whose layers bind only annotations — a common shape
    /// for elevation sets — keeps the native render, in colour, with the bound annotations
    /// switched. The display flag is view state on the open document; nothing here touches the
    /// file, and a save path that reopens pristine bytes is unaffected.
    ///
    /// - Returns: how many annotations changed display state, so a caller — and a test — can
    ///   tell "applied" from "nothing matched".
    @discardableResult
    public func applyAnnotationLayerVisibility(
        of handle: DocumentHandle,
        bindings: [AnnotationLayerBindingReader.Binding],
        hiddenLayerIDs: Set<PDFLayerID>
    ) async throws -> Int {
        try checkCancellation()
        var open = try unlockedEntry(handle)
        var changed = 0
        var hidden: Set<String> = []
        for binding in bindings {
            guard let page = open.document.page(at: binding.pageIndex) else { continue }
            let annotations = page.annotations
            guard let annotation = Self.matchAnnotation(binding, in: annotations) else { continue }
            let shouldDisplay = binding.shouldDisplay(hiddenLayerIDs: hiddenLayerIDs)
            if annotation.shouldDisplay != shouldDisplay {
                annotation.shouldDisplay = shouldDisplay
                changed += 1
            }
            if !shouldDisplay, let position = annotations.firstIndex(where: { $0 === annotation }) {
                hidden.insert("\(binding.pageIndex):\(position)")
            }
        }
        // Thumbnails are keyed by this, so a toggle can never be answered from an image drawn
        // under the previous display state (BH-173, BH-180, BH-181).
        open.annotationDisplayState = Self.displayStateFingerprint(hidden)
        storeEntry(open)
        return changed
    }

    /// Empty for the file's own display state; otherwise a digest of the hidden annotations.
    static func displayStateFingerprint(_ hidden: Set<String>) -> String {
        guard !hidden.isEmpty else { return "" }
        return FileDigestReader.digest(of: Data(hidden.sorted().joined(separator: ",").utf8)).sha256
    }

    /// Resolves a binding to the `PDFAnnotation` it names.
    ///
    /// The binding's `annotationIndex` came from a CoreGraphics `/Annots` walk; assuming
    /// `PDFPage.annotations` is in the same order is an undocumented 1:1 that hides the wrong
    /// annotation when the two diverge (CR-88). Identity is preferred: match by `/NM` name, then
    /// by rect+subtype, and only fall back to the index when identity cannot decide.
    static func matchAnnotation(
        _ binding: AnnotationLayerBindingReader.Binding,
        in annotations: [PDFAnnotation]
    ) -> PDFAnnotation? {
        // 1. `/NM` name — a stable identity independent of array order.
        if let name = binding.annotationName {
            let named = annotations.filter {
                ($0.value(forAnnotationKey: PDFAnnotationKeys.name) as? String) == name
            }
            if named.count == 1 { return named[0] }
        }
        // 2. Rect + subtype. Bounds compared with a small tolerance because PDFKit may round.
        if let rect = binding.rect {
            let matches = annotations.filter { annotation in
                if let subtype = binding.subtype, (annotation.type ?? "") != subtype { return false }
                let b = annotation.bounds
                return abs(b.origin.x - rect.origin.x) < 0.5
                    && abs(b.origin.y - rect.origin.y) < 0.5
                    && abs(b.size.width - rect.size.width) < 0.5
                    && abs(b.size.height - rect.size.height) < 0.5
            }
            if matches.count == 1 { return matches[0] }
        }
        // 3. Last resort: the array index.
        return annotations.indices.contains(binding.annotationIndex)
            ? annotations[binding.annotationIndex]
            : nil
    }
}
