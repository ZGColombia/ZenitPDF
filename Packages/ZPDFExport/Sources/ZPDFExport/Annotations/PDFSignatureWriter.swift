import Foundation
import ZPDFContracts

/// Signs a drawing with a detached CMS signature, as an incremental update (NL-PDF-16,
/// ADR-0028).
///
/// # What is written
///
/// The source byte for byte, then: a signature dictionary whose `/Contents` is a zero-filled
/// placeholder and whose `/ByteRange` names everything except that placeholder, an invisible
/// signature widget on the first page, and a superseding catalog whose `/AcroForm` lists the
/// field (the drawing's own fields kept) with `/SigFlags 3`. The byte ranges are filled in after
/// the update is serialised — the same number of digits, so no offset moves — the covered bytes
/// are handed to `signer`, and its DER is written into the placeholder.
///
/// # Who signs
///
/// This type holds no key and no crypto. `signer` receives the exact bytes the signature must
/// cover and returns a detached CMS `SignedData`: the app passes one built with the Security
/// framework and a certificate from the person's keychain, and a test passes one built by
/// `/usr/bin/openssl` with a throwaway certificate. Verification is `SignatureInspector`'s.
///
/// Because the source is untouched, an existing signature in it stays valid too: it becomes a
/// signature over an earlier revision, which is what a second signer's signature always is.
public struct PDFSignatureWriter: Sendable {

    public struct Options: Sendable, Hashable {
        /// The signature field's name (`/T`). A name the drawing's form already uses gets a number
        /// ("Signature 2") so a countersignature is a field of its own (R-105).
        public var fieldName: String
        /// `/Reason`, e.g. "Approved for construction".
        public var reason: String?
        /// `/Location`.
        public var location: String?
        /// `/Name`: who signs, as the person states it. The certificate is the authority.
        public var signerName: String?
        /// The signing time written as `/M`.
        public var signingTime: Date
        /// Bytes reserved for the DER signature. 16 KiB holds a certificate chain of three.
        public var placeholderByteCount: Int
        /// The signature profile, written as `/SubFilter`.
        public var profile: Profile
        /// A visible seal; `nil` signs invisibly.
        public var seal: Seal?

        public init(
            fieldName: String = "Signature",
            reason: String? = nil,
            location: String? = nil,
            signerName: String? = nil,
            signingTime: Date = Date(),
            placeholderByteCount: Int = 16_384,
            profile: Profile = .pkcs7Detached,
            seal: Seal? = nil
        ) {
            self.fieldName = fieldName
            self.reason = reason
            self.location = location
            self.signerName = signerName
            self.signingTime = signingTime
            self.placeholderByteCount = placeholderByteCount
            self.profile = profile
            self.seal = seal
        }
    }

    /// Which signature format the CMS the signer returns follows.
    public enum Profile: String, Sendable, Hashable, CaseIterable {
        /// `adbe.pkcs7.detached`: detached CMS with a signing-time attribute.
        case pkcs7Detached = "adbe.pkcs7.detached"
        /// `ETSI.CAdES.detached`: the PAdES baseline (B-B) profile — detached CAdES with the
        /// signing-certificate-v2 attribute and no signing-time attribute (the time is `/M`).
        case cadesDetached = "ETSI.CAdES.detached"
    }

    /// A signature you can see: a box on a sheet with the seal's picture and the signing facts.
    ///
    /// Drawn with the PDF standard Helvetica and the stamp artwork's own geometry, so every
    /// reader shows the same seal. It is the signature field's appearance: the signature covers
    /// it, and it cannot be moved or changed without the signature reading "modified".
    public struct Seal: Sendable, Hashable {
        /// Zero-based page the seal sits on.
        public var pageIndex: Int
        /// The seal's box in the page's own space.
        public var rect: PDFRect
        /// Text lines, top to bottom — typically "Digitally signed by …", the date, the reason.
        public var lines: [String]
        /// A stamp's compiled artwork, drawn on the left of the box; `nil` for text only.
        public var artwork: ArtworkGeometry?
        /// Ink for the border, the text and colourless artwork.
        public var color: RGBAColor
        /// The sheet's `/Rotate`. The appearance is turned by it, so the seal reads upright on
        /// the sheet as it is displayed; `rect` stays in page space (R-106).
        public var rotation: PageRotation

        public init(pageIndex: Int, rect: PDFRect, lines: [String], artwork: ArtworkGeometry? = nil,
                    color: RGBAColor = RGBAColor(red: 0.1, green: 0.2, blue: 0.55), rotation: PageRotation = .degrees0) {
            self.pageIndex = pageIndex
            self.rect = rect
            self.lines = lines
            self.artwork = artwork
            self.color = color
            self.rotation = rotation
        }

        /// A seal laid out on the sheet as it is displayed — `displayed` in the rotated sheet's
        /// own coordinates, origin at its bottom-left corner — and placed on `page` by the same
        /// matrix the annotated export places its ink with. On a sheet stored portrait with
        /// `/Rotate 90`, a seal meant for the bottom-right corner used to land in the displayed
        /// bottom-left, its text running up the sheet (R-106).
        public init(on page: PageDescriptor, displayed: PDFRect, lines: [String], artwork: ArtworkGeometry? = nil,
                    color: RGBAColor = RGBAColor(red: 0.1, green: 0.2, blue: 0.55)) {
            let m = LayeredMarkupExporter.placementMatrix(for: page)
            let corners = [(displayed.minX, displayed.minY), (displayed.maxX, displayed.maxY)]
                .map { x, y in (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]) }
            let xs = corners.map(\.0), ys = corners.map(\.1)
            let minX = xs.min() ?? 0, minY = ys.min() ?? 0
            self.init(pageIndex: page.index,
                      rect: PDFRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY),
                      lines: lines, artwork: artwork, color: color, rotation: page.rotation)
        }
    }

    public init() {}

    static let rangePlaceholder = "[9999999999 9999999999 9999999999 9999999999]"

    /// Produces the signed artefact.
    ///
    /// - Parameter signer: receives the bytes the signature covers; returns DER-encoded,
    ///   detached CMS `SignedData`.
    public func data(
        source: Data,
        options: Options = Options(),
        signer: (Data) throws -> Data
    ) throws -> Data {
        let scan: PDFDocumentScan
        let pages: [PDFDocumentScan.PageEntry]
        do {
            scan = try PDFDocumentScan(data: source)
            pages = try scan.pages()
        } catch let error as ExportError {
            throw ExportError.annotationExportRefused(
                error.description.replacingOccurrences(of: "a layer added to it", with: "a signature added to it")
            )
        }
        guard let first = pages.first,
              let root = scan.rootReference, let catalogNumber = root.referenceValue?.number,
              var catalog = scan.dictionary(root)
        else {
            throw ExportError.annotationExportRefused("the drawing has no page or no readable catalog to sign.")
        }

        var update = PDFIncrementalUpdate()
        var allocator = scan.nextObjectNumber
        func allocate() -> Int {
            defer { allocator += 1 }
            return allocator
        }

        let signatureNumber = allocate()
        var signature: [String: PDFObject] = [
            "Type": .name("Sig"),
            "Filter": .name("Adobe.PPKLite"),
            "SubFilter": .name(options.profile.rawValue),
            "ByteRange": .array(Array(repeating: PDFObject.integer(9_999_999_999), count: 4)),
            "Contents": .hexString([UInt8](repeating: 0, count: max(1_024, options.placeholderByteCount))),
            "M": .string(Array(StandardAnnotationWriter.pdfDate(options.signingTime).utf8))
        ]
        if let reason = options.reason { signature["Reason"] = OptionalContentCatalog.textString(reason) }
        if let location = options.location { signature["Location"] = OptionalContentCatalog.textString(location) }
        if let name = options.signerName { signature["Name"] = OptionalContentCatalog.textString(name) }
        update.objects[signatureNumber] = .dictionary(signature)

        // The widget sits on the seal's sheet, or invisibly on the first.
        let target: PDFDocumentScan.PageEntry
        if let seal = options.seal {
            guard pages.indices.contains(seal.pageIndex) else {
                throw ExportError.annotationExportRefused("the seal names sheet \(seal.pageIndex + 1), and the drawing has \(pages.count).")
            }
            target = pages[seal.pageIndex]
        } else {
            target = first
        }
        let widgetNumber = allocate()
        let pageReference = PDFObject.reference(number: target.number, generation: scan.generation(of: target.number))
        var form: [String: PDFObject] = scan.dictionary(catalog["AcroForm"]) ?? [:]
        let fields = scan.object(form["Fields"])?.arrayValue ?? []
        var widgetDictionary: [String: PDFObject] = [
            "Type": .name("Annot"),
            "Subtype": .name("Widget"),
            "FT": .name("Sig"),
            "T": OptionalContentCatalog.textString(Self.freeFieldName(options.fieldName, among: Self.fieldNames(fields, scan: scan))),
            "V": .reference(number: signatureNumber, generation: 0),
            "Rect": .array([.integer(0), .integer(0), .integer(0), .integer(0)]),
            "F": .integer(132),
            "P": pageReference
        ]
        if let seal = options.seal {
            let appearanceNumber = allocate()
            update.objects[appearanceNumber] = Self.sealAppearance(seal)
            widgetDictionary["Rect"] = .array([seal.rect.minX, seal.rect.minY, seal.rect.maxX, seal.rect.maxY].map { .real($0) })
            // Print, and locked: the seal is part of what was signed.
            widgetDictionary["F"] = .integer(4 | 128)
            widgetDictionary["AP"] = .dictionary(["N": .reference(number: appearanceNumber, generation: 0)])
        }
        update.objects[widgetNumber] = .dictionary(widgetDictionary)
        let widget = PDFObject.reference(number: widgetNumber, generation: 0)

        var page = target.dictionary
        page["Annots"] = .array(StandardAnnotationWriter.existingAnnotations(of: target, scan: scan) + [widget])
        update.objects[target.number] = .dictionary(page)

        form["Fields"] = .array(fields + [widget])
        form["SigFlags"] = .integer(3)
        catalog["AcroForm"] = .dictionary(form)
        update.objects[catalogNumber] = .dictionary(catalog)

        // Serialised with a byte range of four ten-digit placeholders; the real ranges are
        // written into the same number of digits, so every cross-reference offset stays true.
        var bytes = [UInt8](try update.appended(to: source, scan: scan))
        let placeholder = Array(Self.rangePlaceholder.utf8)
        // /Contents is looked for after /ByteRange, inside the signature dictionary (keys are
        // written sorted): the rewritten page and the catalog come before it, and a page whose
        // annotations carry a hex /Contents of their own was matched first (R-115).
        guard let rangeAt = PDFObjectParser.find(placeholder, in: bytes, from: source.count),
              let contentsAt = PDFObjectParser.find(Array("/Contents <".utf8), in: bytes, from: rangeAt + placeholder.count)
        else { throw ExportError.annotationExportRefused("the signature placeholder could not be found after writing.") }
        let open = contentsAt + "/Contents ".utf8.count            // the '<'
        guard let close = bytes[open...].firstIndex(of: UInt8(ascii: ">")) else {
            throw ExportError.annotationExportRefused("the signature placeholder is not terminated.")
        }
        let after = close + 1
        // Ten digits each, from the Int itself: `%010d` wrapped past 2 GiB and an eleven-character
        // result shifted every byte after the placeholder (T-044).
        guard let ranges = PDFFixedWidthField.byteRange(open: open, after: after, total: bytes.count),
              ranges.utf8.count == placeholder.count else {
            throw ExportError.annotationExportRefused("the drawing is too large for a signature's byte range.")
        }
        bytes.replaceSubrange(rangeAt..<rangeAt + placeholder.count, with: Array(ranges.utf8))

        let covered = Data(bytes[0..<open]) + Data(bytes[after..<bytes.count])
        let der = try signer(covered)
        let capacity = close - open - 1
        let hex = Array(der.map { String(format: "%02X", $0) }.joined().utf8)
        guard hex.count <= capacity else {
            throw ExportError.annotationExportRefused(
                "the signature is \(der.count) bytes, larger than the \(capacity / 2) bytes reserved for it."
            )
        }
        bytes.replaceSubrange(open + 1..<open + 1 + hex.count, with: hex)
        return Data(bytes)
    }

    // MARK: - The seal

    /// The seal's appearance: a form XObject with a border, the artwork on the left (scaled into
    /// a square, its proportions kept) and the lines in Helvetica on the right.
    static func sealAppearance(_ seal: Seal) -> PDFObject {
        // Drawn in the displayed sheet's orientation: on a quarter-turned sheet the page-space
        // box is the seal turned on its side.
        let turned = seal.rotation == .degrees90 || seal.rotation == .degrees270
        let width = max(1, turned ? seal.rect.height : seal.rect.width)
        let height = max(1, turned ? seal.rect.width : seal.rect.height)
        func n(_ value: Double) -> String { PDFObject.format(value.isFinite ? (value * 10_000).rounded() / 10_000 : 0) }
        let ink = "\(n(seal.color.red)) \(n(seal.color.green)) \(n(seal.color.blue))"
        var ops: [String] = ["q", "\(ink) RG \(ink) rg", "1 w", "0.5 0.5 \(n(width - 1)) \(n(height - 1)) re S"]
        var textLeft = 6.0
        if let artwork = seal.artwork, !artwork.regions.isEmpty || !artwork.strokes.isEmpty {
            let side = height - 8
            let aspect = artwork.sourceAspectRatio > 0 ? artwork.sourceAspectRatio : 1
            let boxW = aspect >= 1 ? side : side * aspect
            let boxH = aspect >= 1 ? side / aspect : side
            let originX = 4 + (side - boxW) / 2, originY = 4 + (side - boxH) / 2
            func point(_ p: PDFPoint) -> String { "\(n(originX + p.x * boxW)) \(n(originY + p.y * boxH))" }
            for region in artwork.regions {
                if let colour = region.color { ops.append("\(n(colour.red)) \(n(colour.green)) \(n(colour.blue)) rg") } else { ops.append("\(ink) rg") }
                for ring in [region.outer] + region.holes where ring.count >= 3 {
                    ops.append("\(point(ring[0])) m")
                    for p in ring.dropFirst() { ops.append("\(point(p)) l") }
                    ops.append("h")
                }
                ops.append("f*")
            }
            for stroke in artwork.strokes where stroke.points.count >= 2 {
                ops.append("\(ink) RG \(n(max(0.5, stroke.widthFraction * side))) w")
                ops.append("\(point(stroke.points[0])) m")
                for p in stroke.points.dropFirst() { ops.append("\(point(p)) l") }
                if stroke.isClosed { ops.append("h") }
                ops.append("S")
            }
            textLeft = side + 10
        }
        let lines = seal.lines.filter { !$0.isEmpty }
        let size = max(5, min(11, (height - 8) / Double(max(1, lines.count)) * 0.8))
        ops.append("\(ink) rg BT /Helv \(n(size)) Tf")
        var y = height - 4 - size
        for line in lines {
            ops.append("1 0 0 1 \(n(textLeft)) \(n(y)) Tm (\(Self.winAnsiLiteral(line))) Tj")
            y -= size * 1.25
        }
        ops.append("ET Q")
        let content = Data(ops.joined(separator: "\n").utf8)
        // The rotation part of the placement matrix: a reader fits the turned box onto the
        // widget's page-space rectangle, and the sheet's own /Rotate turns it back upright.
        let turn: [Double]
        switch seal.rotation {
        case .degrees0: turn = [1, 0, 0, 1, 0, 0]
        case .degrees90: turn = [0, 1, -1, 0, 0, 0]
        case .degrees180: turn = [-1, 0, 0, -1, 0, 0]
        case .degrees270: turn = [0, -1, 1, 0, 0, 0]
        }
        return .stream(dictionary: [
            "Type": .name("XObject"),
            "Subtype": .name("Form"),
            "Matrix": .array(turn.map { .integer(Int($0)) }),
            "BBox": .array([.integer(0), .integer(0), .real(width), .real(height)]),
            "Resources": .dictionary([
                "Font": .dictionary([
                    "Helv": .dictionary([
                        "Type": .name("Font"),
                        "Subtype": .name("Type1"),
                        "BaseFont": .name("Helvetica"),
                        "Encoding": .name("WinAnsiEncoding")
                    ])
                ])
            ]),
            "Length": .integer(content.count)
        ], data: content)
    }

    /// A seal line as a PDF literal string body in WinAnsi — the one Windows-1252 table the OCR
    /// layer and the export profiles use too (R-113); control characters become spaces.
    static func winAnsiLiteral(_ text: String) -> String {
        Windows1252.pdfLiteral(text, controlsAsSpace: true)
    }

    // MARK: - Helpers

    /// Every fully qualified field name in the form (`parent.child`), kids included.
    static func fieldNames(_ fields: [PDFObject], scan: PDFDocumentScan) -> Set<String> {
        var names: Set<String> = []
        var budget = 10_000
        func walk(_ items: [PDFObject], prefix: String?, depth: Int) {
            guard depth < 32 else { return }
            for item in items {
                guard budget > 0 else { return }
                budget -= 1
                guard let field = scan.dictionary(item) else { continue }
                var qualified = prefix
                if let bytes = VectorRedactor.stringBytes(scan.object(field["T"])) {
                    let partial = VectorRedactor.text(bytes)
                    qualified = prefix.map { "\($0).\(partial)" } ?? partial
                    names.insert(qualified ?? partial)
                }
                if let kids = scan.object(field["Kids"])?.arrayValue { walk(kids, prefix: qualified, depth: depth + 1) }
            }
        }
        walk(fields, prefix: nil, depth: 0)
        return names
    }

    /// `base`, or the first of "base 2", "base 3", … that no field of the form is called.
    static func freeFieldName(_ base: String, among taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}
