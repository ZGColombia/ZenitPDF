import Foundation
@testable import ZPDFExport

/// Source drawings for the layered export, written as raw PDF bytes.
///
/// Written by hand rather than produced by Core Graphics for the same reason
/// `AnnotationLayerBindingTests` writes its own: the test has to control the exact structure it
/// claims to preserve. A drawing that already carries its own optional-content group is the
/// fourth item of ADR-0013 §3's verification bar, and there is no way to ask Core Graphics for
/// one — it cannot write optional content at all, which is the reason this whole export shape
/// needs an object layer of its own.
enum LayeredSourceFixtures {

    /// The page geometry every fixture shares, and the geometry
    /// `FlattenedPDFWriterTests.page()` describes: a 420 x 340 media box with a 400 x 300 crop
    /// box offset to (10, 20), so a writer that confused the two is caught.
    static let mediaBox = (width: 420.0, height: 340.0)
    static let cropOrigin = (x: 10.0, y: 20.0)
    static let cropSize = (width: 400.0, height: 300.0)

    /// The drawing's own ink, in page space. Three marks, so "the drawing is still there" is a
    /// count and not an impression.
    static let drawingContent = """
        0.15 0.15 0.15 RG 3 w
        30 40 m 390 300 l S
        0.75 0.78 0.86 rg
        60 220 120 70 re f
        0 0 0 rg
        200 60 80 40 re f
        """

    /// A drawing with no optional content of its own.
    static func plain(rotate: Int = 0) -> Data {
        document(rotate: rotate, ownLayerNamed: nil)
    }

    /// A drawing that already has one optional-content group, with page content bound to it.
    ///
    /// ADR-0013 §2: the export appends to this, never replaces it.
    static func withOwnLayer(named name: String = "Drawing Layer", rotate: Int = 0) -> Data {
        document(rotate: rotate, ownLayerNamed: name)
    }

    /// A catalog whose `/OCProperties` is an array rather than a dictionary.
    ///
    /// Not a file any producer writes — a file some producer got wrong, or a file that was
    /// tampered with. ADR-0013 §2 says what must happen to it: refusal with a sentence, never a
    /// quiet fall back to a flattened export the recipient cannot tell apart.
    static func hostileOptionalContent() -> Data {
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R /OCProperties [5 0 R] >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append(
            "<< /Type /Page /Parent 2 0 R"
                + " /MediaBox [0 0 \(fixed(mediaBox.width)) \(fixed(mediaBox.height))]"
                + " /CropBox [\(fixed(cropOrigin.x)) \(fixed(cropOrigin.y))"
                + " \(fixed(cropOrigin.x + cropSize.width))"
                + " \(fixed(cropOrigin.y + cropSize.height))]"
                + " /Contents 4 0 R /Resources 6 0 R >>"
        )
        objects.append(
            "<< /Length \(drawingContent.utf8.count) >>\nstream\n\(drawingContent)\nendstream"
        )
        objects.append("<< /Type /OCG /Name (Drawing Layer) >>")
        objects.append("<< /ProcSet [/PDF] >>")
        return assemble(objects)
    }

    /// Two sheets that **share one `/Resources` object**, the way a drawing set produced from one
    /// model does.
    ///
    /// The sharing is the point. A layer added by editing that shared object would put sheet 2's
    /// markup properties on sheet 1 — the quiet cross-page defect an export like this is most
    /// likely to have, and the one nothing catches by looking at a single sheet.
    static func sharedResourcePair() -> Data {
        let first = drawingContent
        let second = """
            0.1 0.4 0.1 RG 4 w
            40 260 m 380 60 l S
            0.9 0.9 0.6 rg
            240 210 100 80 re f
            """
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>")
        for (index, contents) in [5, 6].enumerated() {
            objects.append(
                "<< /Type /Page /Parent 2 0 R"
                    + " /MediaBox [0 0 \(fixed(mediaBox.width)) \(fixed(mediaBox.height))]"
                    + " /CropBox [\(fixed(cropOrigin.x)) \(fixed(cropOrigin.y))"
                    + " \(fixed(cropOrigin.x + cropSize.width))"
                    + " \(fixed(cropOrigin.y + cropSize.height))]"
                    + " /Contents \(contents) 0 R /Resources 7 0 R >>"
            )
            _ = index
        }
        for body in [first, second] {
            objects.append("<< /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream")
        }
        objects.append("<< /ProcSet [/PDF] >>")
        return assemble(objects)
    }

    /// The same drawing written the way anything produced since about 2005 writes one: the
    /// catalog, the page tree, the page and its resources compressed inside an `/ObjStm`, and a
    /// cross-reference **stream** instead of a table.
    ///
    /// This is not an exotic shape — it is the common one, and it is the shape in which a
    /// scanner that only understood `xref` tables would find no catalog at all and an exporter
    /// that only appended tables would produce a file strict readers refuse. Both paths are exercised
    /// here and nowhere else.
    static func modern() -> Data {
        let content = drawingContent
        let compressed: [(number: Int, body: String)] = [
            (2, "<< /Type /Catalog /Pages 3 0 R >>"),
            (3, "<< /Type /Pages /Kids [4 0 R] /Count 1 >>"),
            (
                4,
                "<< /Type /Page /Parent 3 0 R"
                    + " /MediaBox [0 0 \(fixed(mediaBox.width)) \(fixed(mediaBox.height))]"
                    + " /CropBox [\(fixed(cropOrigin.x)) \(fixed(cropOrigin.y))"
                    + " \(fixed(cropOrigin.x + cropSize.width))"
                    + " \(fixed(cropOrigin.y + cropSize.height))]"
                    + " /Contents 5 0 R /Resources 6 0 R >>"
            ),
            (6, "<< /ProcSet [/PDF] >>")
        ]

        // An object stream is a header of `number offset` pairs, then the bodies, with every
        // offset measured from `/First`.
        var header = ""
        var bodies = ""
        for entry in compressed {
            header += "\(entry.number) \(bodies.utf8.count) "
            bodies += entry.body + "\n"
        }
        let payload = Data((header + bodies).utf8)
        let first = header.utf8.count
        let deflated = PDFStreamCodec.flateEncode(payload)
        let streamBytes = deflated ?? payload
        let filter = deflated == nil ? "" : " /Filter /FlateDecode"

        var pdf = Data("%PDF-1.6\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int: Int] = [:]

        offsets[1] = pdf.count
        let objectStreamHeader = "1 0 obj\n<< /Type /ObjStm /N \(compressed.count)"
            + " /First \(first)\(filter) /Length \(streamBytes.count) >>\nstream\n"
        pdf.append(Data(objectStreamHeader.utf8))
        pdf.append(streamBytes)
        pdf.append(Data("\nendstream\nendobj\n".utf8))

        offsets[5] = pdf.count
        pdf.append(Data(
            "5 0 obj\n<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream\nendobj\n"
                .utf8
        ))

        let xrefOffset = pdf.count
        var entries = Data()
        func row(_ type: UInt8, _ field2: Int, _ field3: Int) {
            entries.append(type)
            entries.append(UInt8((field2 >> 24) & 0xFF))
            entries.append(UInt8((field2 >> 16) & 0xFF))
            entries.append(UInt8((field2 >> 8) & 0xFF))
            entries.append(UInt8(field2 & 0xFF))
            entries.append(UInt8((field3 >> 8) & 0xFF))
            entries.append(UInt8(field3 & 0xFF))
        }
        row(0, 0, 65535)                    // 0: the free-list head
        row(1, offsets[1] ?? 0, 0)          // 1: the object stream
        row(2, 1, 0)                        // 2: catalog, inside it
        row(2, 1, 1)                        // 3: page tree
        row(2, 1, 2)                        // 4: page
        row(1, offsets[5] ?? 0, 0)          // 5: the page's content stream
        row(2, 1, 3)                        // 6: resources
        row(1, xrefOffset, 0)               // 7: this cross-reference stream

        let crossReferenceHeader = "7 0 obj\n<< /Type /XRef /Size 8 /Index [0 8] /W [1 4 2]"
            + " /Root 2 0 R"
            + " /ID [<1112131415161718191A1B1C1D1E1F20> <1112131415161718191A1B1C1D1E1F20>]"
            + " /Length \(entries.count) >>\nstream\n"
        pdf.append(Data(crossReferenceHeader.utf8))
        pdf.append(entries)
        pdf.append(Data("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return pdf
    }

    // MARK: - Assembly

    private static func document(rotate: Int, ownLayerNamed name: String?) -> Data {
        var content = drawingContent
        var properties = ""
        var optionalContent = ""
        if name != nil {
            content += "\n/OC /L1 BDC\n0.9 0.35 0.1 rg\n300 200 60 60 re f\nEMC\n"
            properties = " /Properties << /L1 5 0 R >>"
            optionalContent =
                " /OCProperties << /OCGs [5 0 R] /D << /Order [5 0 R] /ON [5 0 R] /OFF [] >> >>"
        }

        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R\(optionalContent) >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append(
            "<< /Type /Page /Parent 2 0 R"
                + " /MediaBox [0 0 \(fixed(mediaBox.width)) \(fixed(mediaBox.height))]"
                + " /CropBox [\(fixed(cropOrigin.x)) \(fixed(cropOrigin.y))"
                + " \(fixed(cropOrigin.x + cropSize.width)) \(fixed(cropOrigin.y + cropSize.height))]"
                + " /Rotate \(rotate) /Contents 4 0 R /Resources 6 0 R >>"
        )
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        objects.append("<< /Type /OCG /Name (\(name ?? "Unused")) >>")
        // The page's resources are their own object, shared the way a real drawing shares them,
        // so the exporter is made to resolve an indirect `/Resources` rather than a handy inline
        // dictionary.
        objects.append("<< /ProcSet [/PDF]\(properties) >>")
        return assemble(objects)
    }

    /// Object bodies to a file: a classic cross-reference table and a trailer.
    private static func assemble(_ objects: [String]) -> Data {
        var pdf = Data("%PDF-1.6\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            table += String(format: "%010d 00000 n \n", offset)
        }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R"
            + " /ID [<0102030405060708090A0B0C0D0E0F10> <0102030405060708090A0B0C0D0E0F10>] >>\n"
            + "startxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    private static func fixed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
