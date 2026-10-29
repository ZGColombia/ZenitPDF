import CoreGraphics
import Foundation

/// The operator handlers that need to resolve a resource or recurse.
///
/// Kept apart from the operator table so the table reads as a list of operators and the
/// interesting logic — form recursion, the depth cap, cycle detection — is in one place.
enum VectorFormScanner {

    // MARK: - Do

    /// `Do`: draw an XObject. A `/Form` is recursed into with the composed CTM; an
    /// `/Image` is recorded as a raster region and produces no geometry.
    ///
    /// PDF 32000-1 8.11.3.3, *Optional Content in XObjects*: "An optional content group or
    /// optional content membership dictionary may be attached to an image or form XObject
    /// via the OC entry in its dictionary … the XObject shall be drawn only if the optional
    /// content is visible". Producers that assign layers per form draw such forms with a
    /// bare `Do` and no `BDC`, so the `/OC` entry used to be the one door through which a
    /// switched-off layer became full-confidence snap targets (BH-328). The entry is
    /// treated exactly as a `BDC /OC … EMC` wrapped around the `Do`: the form's content is
    /// scanned under the hidden depth and counted, so the page reports what it excluded,
    /// and with ``VectorExtractionOptions/includesHiddenOptionalContent`` it is emitted,
    /// tagged with the layer. A hidden image is not recorded as a raster region.
    static func performDo(named name: String, scanner: CGPDFScannerRef, state: VectorScanState) {
        let contentStream = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(contentStream, "XObject", name) else {
            // A `Do` naming an XObject the resources do not contain. The malformed
            // fixture is full of these.
            state.noteMalformedOperands()
            return
        }
        guard let stream = PDFObject.stream(object),
              let streamDictionary = CGPDFStreamGetDictionary(stream)
        else {
            state.noteMalformedOperands()
            return
        }

        var layerID: String?
        var hidden = false
        if let optionalContent = PDFObject.dictionaryEntry(streamDictionary, "OC") {
            layerID = state.layerID(for: optionalContent, fallbackName: name)
            hidden = state.isHidden(optionalContentDictionary: optionalContent)
                && !state.options.includesHiddenOptionalContent
        }

        switch PDFObject.nameEntry(streamDictionary, "Subtype") {
        case "Image":
            guard !hidden else { return }
            state.appendRasterRegion(isInline: false, resourceName: name)
        case "Form":
            let wrapped = layerID != nil || hidden
            if wrapped { state.beginMarkedContent(hidesContent: hidden, layerID: layerID) }
            recurseIntoForm(
                named: name,
                stream: stream,
                streamDictionary: streamDictionary,
                parentContentStream: contentStream,
                state: state
            )
            if wrapped { state.endMarkedContent() }
        default:
            // `/PS` and unknown subtypes carry no geometry this extractor can read.
            break
        }
    }

    private static func recurseIntoForm(
        named name: String,
        stream: CGPDFStreamRef,
        streamDictionary: CGPDFDictionaryRef,
        parentContentStream: CGPDFContentStreamRef,
        state: VectorScanState
    ) {
        let limit = state.budget.maximumFormNestingDepth
        guard state.nestingDepth + 1 <= limit else {
            state.note(.formNestingDepthExceeded(limit: limit))
            return
        }

        let identity = PDFObject.identity(stream: stream)
        guard !state.activeFormStreams.contains(identity) else {
            // A form that draws itself, directly or through a cycle. Cut here: a
            // malformed file must not be able to choose the recursion depth.
            state.note(.cyclicFormReference)
            return
        }

        let matrix = PDFObject.matrix(streamDictionary, "Matrix") ?? .identity
        let bbox = PDFObject.box(streamDictionary, "BBox")
        // PDF resource inheritance: a form without `/Resources` sees its parent's, which
        // `CGPDFContentStreamCreateWithStream` implements through the parent chain. The
        // stream's own dictionary is passed when there is nothing else, because the C
        // API requires a non-null dictionary and lookups fall through to the parent.
        let resources = PDFObject.dictionaryEntry(streamDictionary, "Resources") ?? streamDictionary

        // A form is drawn as if wrapped in `q … Q`, with its `/Matrix` concatenated onto
        // the CTM in force at the `Do`. Reversing that order is the classic bug the
        // nested-form fixture exists to catch. The wrapper is a scope, not a bare
        // `saveState`/`restoreState` pair: at the `q`-stack cap the save cannot push, and a
        // bare restore would then pop a state that belongs to the outer stream (CR-51).
        let scope = state.beginFormScope()
        state.concatenate(matrix)
        if let bbox {
            // PDF 32000-1 8.10.1: the `/BBox` "shall be used to clip the form"; 8.5.4:
            // clips intersect. A BBox disjoint from the clip in force empties the clip;
            // it used to replace it, so an off-viewport form painted `.insideClip`
            // (BH-329).
            let clipped = bbox.applying(state.state.ctm.concatenating(state.pageTransform.matrix))
            state.state.intersectClip(with: clipped)
        }
        state.resetPathForFormBoundary()
        // The content part of the block identity (NL-AUTO-12): a digest of the form's bytes,
        // hashed once per stream. `popForm` folds in the sub-forms this drawing drew (W-080);
        // that part is not cached per stream, because an inherited `/Resources` can resolve
        // the same stream's names differently under different parents.
        let digest: UInt64
        if let cached = state.formDigestCache[identity] {
            digest = cached
        } else {
            var hash = FNVHash()
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(stream, &format) as Data? {
                hash.combine([UInt8](data))
            }
            digest = hash.value
            state.formDigestCache[identity] = digest
        }
        state.pushForm(
            streamIdentity: identity,
            resourceName: name,
            contentDigest: digest,
            formToPage: state.state.ctm.concatenating(state.pageTransform.matrix)
        )

        let byteCount = PDFObject.encodedLength(of: stream)
        state.noteContentStreamEntered(bytes: byteCount)

        let childStream = CGPDFContentStreamCreateWithStream(stream, resources, parentContentStream)
        if let table = state.operatorTable {
            let info = Unmanaged.passUnretained(state).toOpaque()
            let childScanner = CGPDFScannerCreate(childStream, table, info)
            CGPDFScannerScan(childScanner)
            CGPDFScannerRelease(childScanner)
        }
        CGPDFContentStreamRelease(childStream)

        if !state.stopRequested { state.noteContentStreamCompleted(bytes: byteCount) }

        state.popForm()
        state.resetPathForFormBoundary()
        state.endFormScope(scope)
    }

    // MARK: - gs

    static func applyExtGState(named name: String, scanner: CGPDFScannerRef, state: VectorScanState) {
        let contentStream = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(contentStream, "ExtGState", name),
              let dictionary = PDFObject.dictionary(object)
        else {
            state.noteMalformedOperands()
            return
        }
        if let width = PDFObject.number(dictionary, "LW"), width >= 0 {
            state.state.lineWidth = width
        }
        if let alpha = PDFObject.number(dictionary, "CA"), alpha >= 0 {
            state.state.strokeAlpha = alpha
        }
        if let alpha = PDFObject.number(dictionary, "ca"), alpha >= 0 {
            state.state.fillAlpha = alpha
        }
        if let dash = PDFObject.arrayEntry(dictionary, "D"), CGPDFArrayGetCount(dash) == 2 {
            var pattern: CGPDFArrayRef?
            if CGPDFArrayGetArray(dash, 0, &pattern), let pattern {
                state.state.isDashed = CGPDFArrayGetCount(pattern) > 0
            }
        }
        let softMaskName = PDFObject.nameEntry(dictionary, "SMask")
        let softMaskDictionary = PDFObject.dictionaryEntry(dictionary, "SMask")
        if (softMaskName != nil && softMaskName != "None") || softMaskDictionary != nil {
            state.state.hasSoftMask = true
            state.note(.softMaskNotComposited)
        }
    }

    // MARK: - cs / CS

    /// The colour space a `cs`/`CS` operand names: a device (or `Cal*`) name directly,
    /// otherwise the page or form `/ColorSpace` resource. `ICCBased` is read by its `/N`;
    /// every other family, and a name the resources do not contain, is unsupported.
    static func resolveColorSpace(named name: String, scanner: CGPDFScannerRef) -> VectorColorSpace {
        if let direct = VectorColorSpace.named(name) { return direct }
        let contentStream = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(contentStream, "ColorSpace", name) else {
            return .unsupported
        }
        if let alias = PDFObject.nameValue(object) {
            return VectorColorSpace.named(alias) ?? .unsupported
        }
        guard let array = PDFObject.array(object), CGPDFArrayGetCount(array) >= 1 else {
            return .unsupported
        }
        var familyPointer: UnsafePointer<Int8>?
        guard CGPDFArrayGetName(array, 0, &familyPointer), let family = PDFObject.name(familyPointer) else {
            return .unsupported
        }
        switch family {
        case "CalGray": return .deviceGray
        case "CalRGB": return .deviceRGB
        case "ICCBased":
            var profile: CGPDFStreamRef?
            guard CGPDFArrayGetCount(array) >= 2,
                  CGPDFArrayGetStream(array, 1, &profile), let profile,
                  let dictionary = CGPDFStreamGetDictionary(profile),
                  let count = PDFObject.integer(dictionary, "N")
            else { return .unsupported }
            return VectorColorSpace.withComponentCount(count)
        default:
            // A one-element array such as `[/DeviceRGB]` names a device family.
            if CGPDFArrayGetCount(array) == 1, let device = VectorColorSpace.named(family),
               device != .unsupported {
                return device
            }
            return .unsupported
        }
    }

    // MARK: - Tf

    /// Text is never a snap source. The font is inspected only to
    /// notice a Type 3 font, whose glyph procedures may be carrying the page's linework.
    static func inspectFont(named name: String, scanner: CGPDFScannerRef, state: VectorScanState) {
        let contentStream = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(contentStream, "Font", name),
              let dictionary = PDFObject.dictionary(object)
        else { return }
        if PDFObject.nameEntry(dictionary, "Subtype") == "Type3" {
            state.note(.type3GlyphGeometryNotExtracted)
        }
    }

    // MARK: - BDC

    static func beginMarkedContentWithProperties(scanner: CGPDFScannerRef, state: VectorScanState) {
        var propertiesObject: CGPDFObjectRef?
        let hasProperties = CGPDFScannerPopObject(scanner, &propertiesObject)
        var tagPointer: UnsafePointer<Int8>?
        let hasTag = CGPDFScannerPopName(scanner, &tagPointer)
        let tag = hasTag ? PDFObject.name(tagPointer) : nil
        if !hasTag { state.noteMalformedOperands() }

        var layerID: String?
        var hidden = false
        if tag == "OC", hasProperties, let propertiesObject {
            if let propertyName = PDFObject.nameValue(propertiesObject) {
                let contentStream = CGPDFScannerGetContentStream(scanner)
                let groupDictionary = CGPDFContentStreamGetResource(contentStream, "Properties", propertyName)
                    .flatMap(PDFObject.dictionary)
                // The name is form-local; the layer is the dictionary it names (CR-48).
                layerID = state.layerID(forPropertyName: propertyName, resolving: groupDictionary)
                if let groupDictionary {
                    hidden = state.isHidden(optionalContentDictionary: groupDictionary)
                }
            } else if let inlineDictionary = PDFObject.dictionary(propertiesObject) {
                hidden = state.isHidden(optionalContentDictionary: inlineDictionary)
            }
        }
        // With `includesHiddenOptionalContent` on, default-hidden geometry is emitted
        // anyway (still layer-tagged) so a query-time layer filter owns visibility in
        // both directions without a re-extraction.
        if state.options.includesHiddenOptionalContent { hidden = false }
        // Always pushed, even when the operands were unreadable, so that the matching
        // `EMC` finds something to pop and the hidden-content counter stays balanced.
        state.beginMarkedContent(hidesContent: hidden, layerID: layerID)
    }
}
