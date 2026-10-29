import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ZPDFExport

/// One page of a hand-assembled fixture: its content, its resources (nil: inherited from the
/// page tree), and any other keys of its dictionary.
struct HardeningPage {
    var content: Data
    var resources: String?
    var extras: String

    init(_ content: String, resources: String?, extras: String = "") {
        self.init(data: Data(content.utf8), resources: resources, extras: extras)
    }

    init(data: Data, resources: String?, extras: String = "") {
        self.content = data
        self.resources = resources
        self.extras = extras
    }
}

extension RedactionFixturePDF {

    /// A document whose page objects are numbered before anything else is added, so a fixture
    /// can point annotations, destinations and widgets at them.
    static func assemble(
        pageCount: Int,
        mediaBox: String = "[0 0 612 792]",
        treeExtras: String = "",
        _ body: (inout RedactionFixturePDF, [Int]) -> (pages: [HardeningPage], catalog: String)
    ) -> Data {
        var pdf = RedactionFixturePDF()
        let catalog = pdf.reserve()
        let tree = pdf.reserve()
        let numbers = (0..<pageCount).map { _ in pdf.reserve() }
        let (pages, catalogExtras) = body(&pdf, numbers)
        for (index, page) in pages.enumerated() {
            let content = pdf.addStream("", page.content)
            let resources = page.resources.map { " /Resources \($0)" } ?? ""
            pdf.set(numbers[index], "<< /Type /Page /Parent \(tree) 0 R /MediaBox \(mediaBox)\(resources) /Contents \(content) 0 R \(page.extras) >>")
        }
        pdf.set(tree, "<< /Type /Pages /Kids [\(numbers.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(numbers.count) \(treeExtras) >>")
        pdf.set(catalog, "<< /Type /Catalog /Pages \(tree) 0 R \(catalogExtras) >>")
        return pdf.data(root: catalog)
    }
}

/// One fixture per known leak in the vector redaction, built object by object to reproduce
/// the leak.
enum HardeningFixtures {

    static let helvetica = RedactionFixturePDF.helveticaWithWidths
    static let standardHelvetica = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"

    /// RGB samples no other fixture object can contain by accident (a xorshift stream per seed,
    /// so one seed's samples are not a shifted run of another's).
    static func rgb(_ width: Int, _ height: Int, seed: Int) -> [UInt8] {
        var state = UInt32(truncatingIfNeeded: 0x9E37_79B9 &* UInt32(seed + 1))
        return (0..<(width * height * 3)).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state >> 11) | 0x10
        }
    }

    static func imageDictionary(_ width: Int, _ height: Int, extra: String = "") -> String {
        "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /BitsPerComponent 8 /ColorSpace /DeviceRGB \(extra)"
    }

    static func hex(_ text: String) -> String { text.utf8.map { String(format: "%02X", $0) }.joined() }

    // MARK: - Patterns (findings 1, 5, 15)

    /// Finding 1: a tiling pattern whose cell holds text that is visible only where the pattern
    /// fills a rectangle under the box.
    static func tilingPatternText() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            let font = pdf.add(helvetica)
            let pattern = pdf.addStream(
                "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 612 792] /XStep 612 /YStep 792 /Resources << /Font << /F1 \(font) 0 R >> >>",
                "BT /F1 18 Tf 100 700 Td (FALCON SALARY 98000) Tj ET"
            )
            let content = "BT /F1 12 Tf 72 400 Td (Public paragraph text.) Tj ET /Pattern cs /P1 scn 95 690 230 40 re f"
            return ([HardeningPage(content, resources: "<< /Font << /F1 \(font) 0 R >> /Pattern << /P1 \(pattern) 0 R >> >>")], "")
        }
    }

    /// Finding 15 (S1a/S1b): one tile covers the whole sheet; its cell holds hex text and a picture
    /// whose samples spell a word, both partly under boxes.
    static func wholeSheetPattern() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            let font = pdf.add(helvetica)
            var samples: [UInt8] = []
            for row in 0..<4 { samples += Array("PATTERNIMAGESECRET\(row)X".utf8) }
            let image = pdf.addStream("/Type /XObject /Subtype /Image /Width 20 /Height 4 /BitsPerComponent 8 /ColorSpace /DeviceGray", Data(samples))
            let cell = "BT /F1 18 Tf 100 500 Td <\(hex("PATSECRET 4711"))> Tj ET BT /F1 18 Tf 100 300 Td (VISIBLE CELL TEXT) Tj ET q 200 0 0 40 300 100 cm /Img Do Q"
            let pattern = pdf.addStream(
                "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 1000 1000] /XStep 1000 /YStep 1000 /Resources << /Font << /F1 \(font) 0 R >> /XObject << /Img \(image) 0 R >> >>",
                cell
            )
            let content = "BT /F1 12 Tf 72 700 Td (Heading outside) Tj ET q /Pattern cs /P1 scn 0 0 612 792 re f Q"
            return ([HardeningPage(content, resources: "<< /Font << /F1 \(font) 0 R >> /Pattern << /P1 \(pattern) 0 R >> >>")], "")
        }
    }

    static let pictureFillSamples = rgb(40, 40, seed: 3)

    /// Finding 5: a picture fill — a tiling pattern whose single cell draws a 40 × 40 picture and a
    /// red line across the sheet. `step` below 400 makes the cell repeat.
    static func pictureFillPattern(step: Int = 400) -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            let image = pdf.addStream(imageDictionary(40, 40), Data(pictureFillSamples))
            let pattern = pdf.addStream(
                "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 \(step) \(step)] /XStep \(step) /YStep \(step) /Matrix [1 0 0 1 100 200] /Resources << /XObject << /ImP \(image) 0 R >> >>",
                "q 400 0 0 400 0 0 cm /ImP Do Q 1 0 0 RG 6 w 50 200 m 350 200 l S"
            )
            return ([HardeningPage("/Pattern cs /P1 scn 100 200 400 400 re f", resources: "<< /Pattern << /P1 \(pattern) 0 R >> >>")], "")
        }
    }

    // MARK: - Shadings (findings 6, 7)

    static let sampledFunction = (0..<768).map { UInt8(($0 * 37 + 11) % 256) }

    /// Finding 6a: a function-based shading whose sampled function paints only inside the box.
    static func sampledShading() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            let font = pdf.add(helvetica)
            let function = pdf.addStream("/FunctionType 0 /Domain [0 1 0 1] /Range [0 1 0 1 0 1] /Size [16 16] /BitsPerSample 8", Data(sampledFunction))
            let shading = pdf.add("<< /ShadingType 1 /ColorSpace /DeviceRGB /Matrix [200 0 0 200 200 300] /Function \(function) 0 R >>")
            let content = "BT /F1 12 Tf 72 700 Td (Caption outside) Tj ET q 200 300 200 200 re W n /Sh1 sh Q"
            return ([HardeningPage(content, resources: "<< /Font << /F1 \(font) 0 R >> /Shading << /Sh1 \(shading) 0 R >> >>")], "")
        }
    }

    /// Finding 6b: an axial shading pattern whose stitching function paints orange only in the
    /// part of the fill that lies under the box.
    static func axialShadingPattern() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            let font = pdf.add(helvetica)
            let orange = pdf.add("<< /FunctionType 2 /Domain [0 1] /C0 [1 0.5 0] /C1 [1 0.5 0] /N 1 >>")
            let blue = pdf.add("<< /FunctionType 2 /Domain [0 1] /C0 [0 0 1] /C1 [0 0.8 1] /N 1 >>")
            let stitch = pdf.add("<< /FunctionType 3 /Domain [0 1] /Functions [\(orange) 0 R \(blue) 0 R] /Bounds [0.5] /Encode [0 1 0 1] >>")
            let axial = pdf.add("<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [245 0 465 0] /Function \(stitch) 0 R /Extend [false false] >>")
            let pattern = pdf.add("<< /Type /Pattern /PatternType 2 /Shading \(axial) 0 R >>")
            let content = "BT /F1 12 Tf 72 700 Td (Caption outside) Tj ET /Pattern cs /Ax scn 245 40 400 120 re f"
            return ([HardeningPage(content, resources: "<< /Font << /F1 \(font) 0 R >> /Pattern << /Ax \(pattern) 0 R >> >>")], "")
        }
    }

    /// Finding 7: one free-form triangle mesh, 16-bit coordinates, used through a shading
    /// pattern; the triangle lies inside the box.
    static let meshData: [UInt8] = {
        func raw(_ value: Double, _ maximum: Double) -> [UInt8] {
            let scaled = Int((value / maximum * 65535).rounded())
            return [UInt8(scaled >> 8), UInt8(scaled & 0xFF)]
        }
        var data: [UInt8] = []
        for (x, y, colour) in [(250.0, 350.0, [255, 0, 0]), (350.0, 350.0, [0, 255, 0]), (300.0, 450.0, [255, 255, 0])] {
            data.append(0)
            data += raw(x, 612) + raw(y, 792) + colour.map { UInt8($0) }
        }
        return data
    }()

    static func meshPattern() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            let font = pdf.add(helvetica)
            let mesh = pdf.addStream(
                "/ShadingType 4 /ColorSpace /DeviceRGB /BitsPerCoordinate 16 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 612 0 792 0 1 0 1 0 1]",
                Data(meshData)
            )
            let pattern = pdf.add("<< /Type /Pattern /PatternType 2 /Shading \(mesh) 0 R >>")
            let content = "BT /F1 12 Tf 72 700 Td (Caption outside) Tj ET /Pattern cs /M scn 0 0 612 600 re f"
            return ([HardeningPage(content, resources: "<< /Font << /F1 \(font) 0 R >> /Pattern << /M \(pattern) 0 R >> >>")], "")
        }
    }

    // MARK: - Shared resources (finding 4)

    static let secretImage = rgb(32, 32, seed: 1)
    static let publicImage = rgb(32, 32, seed: 2)

    enum SharedCase { case twoSheets, inheritedFromTree, formOnOneSheet, fallbackSheet }

    static func sharedResources(_ variant: SharedCase) -> Data {
        switch variant {
        case .twoSheets, .inheritedFromTree:
            let make: (inout RedactionFixturePDF, [Int]) -> (pages: [HardeningPage], catalog: String) = { pdf, _ in
                let secret = pdf.addStream(imageDictionary(32, 32), Data(secretImage))
                let visible = pdf.addStream(imageDictionary(32, 32), Data(publicImage))
                let sharedNumber = pdf.add("<< /XObject << /ImS \(secret) 0 R /ImP \(visible) 0 R >> >>")
                let resources: String? = variant == .twoSheets ? "\(sharedNumber) 0 R" : nil
                return ([
                    HardeningPage("q 200 0 0 200 200 300 cm /ImS Do Q", resources: resources),
                    HardeningPage("q 100 0 0 100 100 100 cm /ImP Do Q", resources: resources)
                ], "")
            }
            if variant == .twoSheets { return RedactionFixturePDF.assemble(pageCount: 2, make) }
            // The shared dictionary is object 5 (catalog, tree, two pages, then the two images).
            return RedactionFixturePDF.assemble(pageCount: 2, treeExtras: "/Resources 7 0 R", make)
        case .formOnOneSheet:
            return RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
                let secret = pdf.addStream(imageDictionary(32, 32), Data(secretImage))
                let resources = pdf.reserve()
                let form = pdf.addStream("/Type /XObject /Subtype /Form /BBox [0 0 50 50] /Resources \(resources) 0 R", "0 0 1 rg 0 0 50 50 re f")
                pdf.set(resources, "<< /XObject << /Fm1 \(form) 0 R /ImS \(secret) 0 R >> >>")
                return ([HardeningPage("q 200 0 0 200 200 300 cm /ImS Do Q q 1 0 0 1 20 20 cm /Fm1 Do Q", resources: "\(resources) 0 R")], "")
            }
        case .fallbackSheet:
            return RedactionFixturePDF.assemble(pageCount: 2) { pdf, _ in
                let secret = pdf.addStream(imageDictionary(32, 32), Data(secretImage))
                let visible = pdf.addStream(imageDictionary(32, 32), Data(publicImage))
                let font = pdf.add(standardHelvetica)
                let shared = pdf.add("<< /Font << /Std \(font) 0 R >> /XObject << /ImS \(secret) 0 R /ImP \(visible) 0 R >> >>")
                return ([
                    HardeningPage("BT /Std 14 Tf 60 600 Td (STANDARD FONT) Tj ET q 200 0 0 200 200 300 cm /ImS Do Q", resources: "\(shared) 0 R"),
                    HardeningPage("q 100 0 0 100 100 100 cm /ImP Do Q", resources: "\(shared) 0 R")
                ], "")
            }
        }
    }

    // MARK: - Cropped placements (finding 8)

    static let croppedImage = rgb(32, 32, seed: 5)

    static func croppedImageFixture() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            let image = pdf.addStream(imageDictionary(32, 32), Data(croppedImage))
            let content = "q 200 0 0 200 200 300 cm /Im1 Do Q q 50 50 100 100 re W n 200 0 0 200 50 50 cm /Im1 Do Q"
            return ([HardeningPage(content, resources: "<< /XObject << /Im1 \(image) 0 R >> >>")], "")
        }
    }

    /// Model space shown through two viewports: A shows the red X (under the box), B only the
    /// blue line.
    static func viewportFixture() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1, mediaBox: "[0 0 900 700]") { pdf, _ in
            let model = pdf.addStream(
                "/Type /XObject /Subtype /Form /BBox [0 0 400 400]",
                "1 0 0 RG 4 w 20 20 m 180 180 l S 20 180 m 180 20 l S 0 0 1 RG 220 200 m 380 200 l S"
            )
            let content = "q 1 0 0 1 180 280 cm 0 0 200 200 re W n /Model Do Q q 1 0 0 1 420 0 cm 200 200 200 200 re W n /Model Do Q"
            return ([HardeningPage(content, resources: "<< /XObject << /Model \(model) 0 R >> >>")], "")
        }
    }

    // MARK: - Type 3 glyph procedure (finding 9)

    static let signatureImage = (0..<64).map { UInt8(0x30 + $0 % 64) }

    static func type3Signature() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            let square = pdf.addStream("", "1000 0 0 0 1000 1000 d1 0 0 1000 1000 re f")
            var signature = Data("1000 0 d0 q 1000 0 0 1000 0 0 cm BI /W 8 /H 8 /CS /G /BPC 8 ID ".utf8)
            signature.append(contentsOf: signatureImage)
            signature.append(Data("\nEI Q 0 0 1 RG 40 w 100 100 m 300 900 l 500 100 l 700 900 l S".utf8))
            let sig = pdf.addStream("", signature)
            let font = pdf.add("<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /a \(square) 0 R /sig \(sig) 0 R >> /Encoding << /Type /Encoding /Differences [65 /a /sig] >> /FirstChar 65 /LastChar 66 /Widths [1000 1000] /Resources << >> >>")
            let content = "BT /F3 100 Tf 50 350 Td (A) Tj ET BT /F3 100 Tf 250 350 Td (B) Tj ET"
            return ([HardeningPage(content, resources: "<< /Font << /F3 \(font) 0 R >> >>")], "")
        }
    }

    // MARK: - Associated files and attachments (findings 10, 17)

    static let associatedSamples = rgb(32, 32, seed: 7)

    static func attachments() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, pages in
            let font = pdf.add(helvetica)
            let original = pdf.addStream("/Params << /Size 3072 >>", Data(associatedSamples))
            let imageSpec = pdf.add("<< /Type /Filespec /F (orig.raw) /AFRelationship /Source /EF << /F \(original) 0 R >> >>")
            let image = pdf.addStream(imageDictionary(32, 32, extra: "/AF [\(imageSpec) 0 R]"), Data(associatedSamples))
            let pageFile = pdf.addStream("", "ASSOCIATEDFILEDATA for the whole sheet")
            let pageSpec = pdf.add("<< /Type /Filespec /F (sheet.txt) /EF << /F \(pageFile) 0 R >> >>")
            let untyped = pdf.addStream("", "ATTACHEDSECRETDATA in an untyped stream")
            let untypedSpec = pdf.add("<< /Type /Filespec /F (bid.txt) /EF << /F \(untyped) 0 R >> >>")
            let typed = pdf.addStream("/Type /EmbeddedFile", "TYPEDATTACHMENTDATA in a typed stream")
            let typedSpec = pdf.add("<< /Type /Filespec /F (typed.txt) /EF << /F \(typed) 0 R >> >>")
            let first = pdf.add("<< /Type /Annot /Subtype /FileAttachment /Rect [500 700 520 720] /FS \(untypedSpec) 0 R /Contents (attachment) /P \(pages[0]) 0 R >>")
            let second = pdf.add("<< /Type /Annot /Subtype /FileAttachment /Rect [540 700 560 720] /FS \(typedSpec) 0 R /Contents (typed) /P \(pages[0]) 0 R >>")
            let content = "BT /F1 12 Tf 72 740 Td (Sheet heading) Tj ET q 200 0 0 200 200 400 cm /Im Do Q"
            return ([HardeningPage(content, resources: "<< /Font << /F1 \(font) 0 R >> /XObject << /Im \(image) 0 R >> >>",
                                   extras: "/AF [\(pageSpec) 0 R] /Annots [\(first) 0 R \(second) 0 R]")], "")
        }
    }

    // MARK: - PostScript alternate (finding 13)

    static func postScriptAlternate() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            let postScript = pdf.addStream("", "%!PS secret linework 250 350 moveto 350 450 lineto stroke")
            let form = pdf.addStream("/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Subtype2 /PS /PS \(postScript) 0 R", "1 0 0 RG 5 w 250 350 m 350 450 l S")
            return ([HardeningPage("/Fm Do", resources: "<< /XObject << /Fm \(form) 0 R >> >>")], "")
        }
    }

    // MARK: - Revisions (findings 11, 12)

    /// Finding 11: revision 2 frees the secret picture sheet 2 used to draw and redraws sheet 2
    /// without it, but sheet 2's resources still name it.
    static func freedObject() -> Data {
        var pdf = RedactionFixturePDF()
        let catalog = pdf.reserve(), tree = pdf.reserve(), first = pdf.reserve(), second = pdf.reserve()
        let font = pdf.add(helvetica)
        let secret = pdf.addStream(imageDictionary(32, 32), Data(secretImage))
        let content1 = pdf.addStream("", "BT /F1 18 Tf 72 700 Td (SECRET TEXT ONE) Tj ET BT /F1 12 Tf 72 400 Td (Kept text) Tj ET")
        let content2 = pdf.addStream("", "q 200 0 0 200 200 300 cm /ImS Do Q")
        pdf.set(first, "<< /Type /Page /Parent \(tree) 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 \(font) 0 R >> >> /Contents \(content1) 0 R >>")
        let secondResources = "<< /Font << /F1 \(font) 0 R >> /XObject << /ImS \(secret) 0 R >> >>"
        pdf.set(second, "<< /Type /Page /Parent \(tree) 0 R /MediaBox [0 0 612 792] /Resources \(secondResources) /Contents \(content2) 0 R >>")
        pdf.set(tree, "<< /Type /Pages /Kids [\(first) 0 R \(second) 0 R] /Count 2 >>")
        pdf.set(catalog, "<< /Type /Catalog /Pages \(tree) 0 R >>")
        var out = pdf.data(root: catalog)
        let previous = lastStartXref(out)
        let newContent = pdf.count + 1
        var bodies: [(Int, String)] = []
        let sheetTwo = "BT /F1 12 Tf 72 400 Td (Sheet two) Tj ET"
        bodies.append((newContent, "<< /Length \(sheetTwo.utf8.count) >>\nstream\n\(sheetTwo)\nendstream"))
        bodies.append((second, "<< /Type /Page /Parent \(tree) 0 R /MediaBox [0 0 612 792] /Resources \(secondResources) /Contents \(newContent) 0 R >>"))
        var offsets: [Int: Int] = [:]
        for (number, body) in bodies {
            offsets[number] = out.count
            out.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n0 1\n0000000000 65535 f \n\(secret) 1\n0000000000 00001 f \n\(second) 1\n\(String(format: "%010d", offsets[second]!)) 00000 n \n"
        table += "\(newContent) 1\n\(String(format: "%010d", offsets[newContent]!)) 00000 n \n"
        table += "trailer\n<< /Size \(newContent + 1) /Root \(catalog) 0 R /Prev \(previous) >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
    }

    static func lastStartXref(_ data: Data) -> Int {
        let text = String(decoding: data.suffix(64), as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
        guard let index = lines.lastIndex(of: "startxref"), index + 1 < lines.count else { return 0 }
        return Int(lines[index + 1]) ?? 0
    }

    /// Finding 12: revision 1 written with a cross-reference stream (sheet 2 shows a photo);
    /// revision 2 a classic update with a new catalog and a new sheet 2 without the photo.
    static let photo = rgb(32, 32, seed: 9)

    static func mixedCrossReferenceChain() -> Data {
        var out = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\n".utf8)
        var offsets: [Int: Int] = [:]
        func object(_ number: Int, _ body: Data) {
            offsets[number] = out.count
            out.append(Data("\(number) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        func stream(_ dictionary: String, _ data: Data) -> Data {
            var body = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
            body.append(data)
            body.append(Data("\nendstream".utf8))
            return body
        }
        object(1, Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        object(2, Data("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>".utf8))
        object(3, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents 5 0 R >>".utf8))
        object(4, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Photo 8 0 R >> >> /Contents 6 0 R >>".utf8))
        object(5, stream("", Data("BT /F1 18 Tf 72 700 Td (SECRET TEXT ONE) Tj ET BT /F1 12 Tf 72 400 Td (Kept text) Tj ET".utf8)))
        object(6, stream("", Data("q 200 0 0 200 150 250 cm /Photo Do Q".utf8)))
        object(7, Data(helvetica.utf8))
        object(8, stream(imageDictionary(32, 32), Data(photo)))
        let xrefStreamOffset = out.count
        offsets[9] = xrefStreamOffset
        var entries = Data([0, 0, 0, 0, 0, 0xFF, 0xFF])
        for number in 1...9 {
            let offset = offsets[number]!
            entries.append(contentsOf: [1, UInt8(offset >> 24 & 0xFF), UInt8(offset >> 16 & 0xFF), UInt8(offset >> 8 & 0xFF), UInt8(offset & 0xFF), 0, 0])
        }
        out.append(Data("9 0 obj\n".utf8))
        out.append(stream("/Type /XRef /Size 10 /W [1 4 2] /Root 1 0 R", entries))
        out.append(Data("\nendobj\nstartxref\n\(xrefStreamOffset)\n%%EOF\n".utf8))

        object(20, Data("<< /Type /Catalog /Pages 21 0 R >>".utf8))
        object(21, Data("<< /Type /Pages /Kids [3 0 R 22 0 R] /Count 2 >>".utf8))
        object(22, Data("<< /Type /Page /Parent 21 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents 23 0 R >>".utf8))
        object(23, stream("", Data("BT /F1 12 Tf 72 700 Td (Revision two sheet) Tj ET".utf8)))
        let xref = out.count
        var table = "xref\n20 4\n"
        for number in 20...23 { table += String(format: "%010d 00000 n \n", offsets[number]!) }
        table += "trailer\n<< /Size 24 /Root 20 0 R /Prev \(xrefStreamOffset) >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
    }

    // MARK: - Form field (finding 2)

    static func hiddenWidget() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, pages in
            let font = pdf.add(helvetica)
            let appearance1 = pdf.addStream("/Type /XObject /Subtype /Form /BBox [0 0 220 30] /Resources << /Font << /Helv \(font) 0 R >> >>", "BT /Helv 12 Tf 4 10 Td (FALCON-7731) Tj ET")
            let appearance2 = pdf.addStream("/Type /XObject /Subtype /Form /BBox [0 0 220 30] /Resources << /Font << /Helv \(font) 0 R >> >>", "BT /Helv 12 Tf 4 10 Td (FALCON-7731) Tj ET")
            let field = pdf.reserve()
            let visible = pdf.add("<< /Type /Annot /Subtype /Widget /Parent \(field) 0 R /Rect [100 695 320 725] /F 4 /AP << /N \(appearance1) 0 R >> /P \(pages[0]) 0 R >>")
            let hidden = pdf.add("<< /Type /Annot /Subtype /Widget /Parent \(field) 0 R /Rect [100 100 320 130] /F 2 /AP << /N \(appearance2) 0 R >> /P \(pages[0]) 0 R >>")
            pdf.set(field, "<< /FT /Tx /T (codename) /V (FALCON-7731) /Kids [\(visible) 0 R \(hidden) 0 R] >>")
            let content = "BT /F1 12 Tf 72 400 Td (Form sheet) Tj ET"
            return ([HardeningPage(content, resources: "<< /Font << /F1 \(font) 0 R >> >>", extras: "/Annots [\(visible) 0 R \(hidden) 0 R]")],
                    "/AcroForm << /Fields [\(field) 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv \(font) 0 R >> >> >>")
        }
    }

    // MARK: - Bookmarks (finding 3)

    static func bookmarks() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, pages in
            let font = pdf.add(helvetica)
            let outlines = pdf.reserve()
            let items = (0..<4).map { _ in pdf.reserve() }
            let page = pages[0]
            let specs = [
                "/Title (Project Falcon) /Dest [\(page) 0 R /XYZ null 724 null]",
                "/Title (Body) /Dest [\(page) 0 R /FitH 410]",
                "/Title (Heading again) /Dest [\(page) 0 R /FitH 720]",
                "/Title (Other) /Dest [\(page) 0 R /Fit]"
            ]
            for (index, spec) in specs.enumerated() {
                var links = "/Parent \(outlines) 0 R"
                if index > 0 { links += " /Prev \(items[index - 1]) 0 R" }
                if index + 1 < items.count { links += " /Next \(items[index + 1]) 0 R" }
                pdf.set(items[index], "<< \(spec) \(links) >>")
            }
            pdf.set(outlines, "<< /Type /Outlines /First \(items[0]) 0 R /Last \(items[3]) 0 R /Count 4 >>")
            let content = "BT /F1 24 Tf 100 700 Td (PROJECT FALCON) Tj ET BT /F1 12 Tf 72 400 Td (Body text here.) Tj ET"
            return ([HardeningPage(content, resources: "<< /Font << /F1 \(font) 0 R >> >>")], "/Outlines \(outlines) 0 R")
        }
    }

    // MARK: - Hex strings (finding 18)

    static func hexNote() -> Data {
        RedactionFixturePDF.document(
            pages: [("BT /F1 18 Tf 70 192 Td (BIDAMOUNT 4820000) Tj ET BT /F1 14 Tf 60 250 Td (Tender summary) Tj ET", "[NOTE]")],
            resources: "<< /Font << /F1 HELV >> >>",
            extraObjects: { pdf in
                let font = pdf.add(helvetica)
                let note = pdf.add("<< /Type /Annot /Subtype /Text /Rect [360 30 380 50] /Contents <\(hex("bid is 4820000 SEK"))> >>")
                return ["HELV": "\(font) 0 R", "NOTE": "\(note) 0 R"]
            }
        )
    }

    // MARK: - Rotated and cropped sheets (findings 14, 16)

    static func rotatedSheet(rotate: Int, crop: String?, standardFont: Bool) -> Data {
        RedactionFixturePDF.assemble(pageCount: 1, mediaBox: "[0 0 420 300]") { pdf, _ in
            let font = pdf.add(standardFont ? standardHelvetica : helvetica)
            let content = "q 0 0 1 RG 2 w 40 40 340 220 re S Q BT /F1 14 Tf 60 250 Td (Tender summary) Tj ET BT /F1 18 Tf 70 150 Td (BIDAMOUNT 4820000) Tj ET"
            var extras = "/Rotate \(rotate)"
            if let crop { extras += " /CropBox \(crop)" }
            return ([HardeningPage(content, resources: "<< /Font << /F1 \(font) 0 R >> >>", extras: extras)], "")
        }
    }

    static let rotatedMark = CGRect(x: 60, y: 140, width: 180, height: 30)

    // MARK: - Fonts (finding 19)

    /// Core Text text: “tender summary” outside the box, “QXZJK 4820000” under it.
    static func coreTextFonts(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 420, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        func text(_ string: String, at point: CGPoint) {
            let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = point
            CTLineDraw(line, context)
        }
        context.beginPDFPage(nil)
        text("tender summary", at: CGPoint(x: 60, y: 250))
        text("QXZJK 4820000", at: CGPoint(x: 70, y: 150))
        context.endPDFPage()
        context.closePDF()
    }
}

/// Checks the hardening tests share.
enum HardeningProof {

    /// Every image XObject in the file, decoded.
    static func decodedImages(_ url: URL) throws -> [[UInt8]] {
        let scan = try PDFDocumentScan(data: try Data(contentsOf: url))
        var out: [[UInt8]] = []
        for entry in scan.objects.values {
            guard case let .stream(dictionary, data) = entry.object, dictionary["Subtype"]?.nameValue == "Image",
                  let decoded = try? RedactionStreamFilters.decode(dictionary: dictionary, data: data).data else { continue }
            out.append([UInt8](decoded))
        }
        return out
    }

    static func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        haystack.range(of: Data(needle)) != nil
    }

    /// A page rendered by Core Graphics' own drawing transform (not PDFKit), three times finer
    /// and averaged down (so a 300-dpi picture compares with vector), top row first, and the map
    /// from page space into its pixel grid.
    static func coreGraphicsRender(_ url: URL, page index: Int, dpi: Double = 100) throws -> (bitmap: RasterRedactor.Bitmap, transform: CGAffineTransform) {
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: index + 1))
        let crop = page.getBoxRect(.cropBox)
        let displayed = page.rotationAngle % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        let width = Int((displayed.width * dpi / 72).rounded()), height = Int((displayed.height * dpi / 72).rounded())
        let fine = 3, fineWidth = width * fine, fineHeight = height * fine
        let drawing = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: displayed), rotate: 0, preserveAspectRatio: true)
        var finePixels = [UInt8](repeating: 255, count: fineWidth * fineHeight * 4)
        finePixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: fineWidth, height: fineHeight, bitsPerComponent: 8, bytesPerRow: fineWidth * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: fineWidth, height: fineHeight))
            context.scaleBy(x: CGFloat(fineWidth) / displayed.width, y: CGFloat(fineHeight) / displayed.height)
            context.concatenate(drawing)
            context.clip(to: crop)
            context.drawPDFPage(page)
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<3 {
                    var sum = 0
                    for dy in 0..<fine { for dx in 0..<fine { sum += Int(finePixels[((y * fine + dy) * fineWidth + x * fine + dx) * 4 + channel]) } }
                    pixels[(y * width + x) * 4 + channel] = UInt8(sum / (fine * fine))
                }
            }
        }
        let transform = drawing
            .concatenating(CGAffineTransform(scaleX: CGFloat(width) / displayed.width, y: CGFloat(height) / displayed.height))
            .concatenating(CGAffineTransform(scaleX: 1, y: -1))
            .concatenating(CGAffineTransform(translationX: 0, y: CGFloat(height)))
        return (RasterRedactor.Bitmap(width: width, height: height, pixels: pixels), transform)
    }

    /// Dark pixels (mean below 128) outside `excluded`, and the darkest mean inside `inside`.
    static func darkPixels(_ bitmap: RasterRedactor.Bitmap, outside excluded: CGRect) -> Int {
        var count = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where !excluded.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                let offset = (y * bitmap.width + x) * 4
                let mean = (Int(bitmap.pixels[offset]) + Int(bitmap.pixels[offset + 1]) + Int(bitmap.pixels[offset + 2])) / 3
                if mean < 128 { count += 1 }
            }
        }
        return count
    }

    static func brightestMean(_ bitmap: RasterRedactor.Bitmap, inside rect: CGRect) -> Int {
        var brightest = 0
        for y in max(0, Int(rect.minY.rounded(.up)))..<min(bitmap.height, Int(rect.maxY.rounded(.down))) {
            for x in max(0, Int(rect.minX.rounded(.up)))..<min(bitmap.width, Int(rect.maxX.rounded(.down))) {
                let offset = (y * bitmap.width + x) * 4
                brightest = max(brightest, (Int(bitmap.pixels[offset]) + Int(bitmap.pixels[offset + 1]) + Int(bitmap.pixels[offset + 2])) / 3)
            }
        }
        return brightest
    }

    /// The first font dictionary in a page's resources, resolved.
    static func firstFont(_ scan: PDFDocumentScan, page index: Int) throws -> [String: PDFObject] {
        let entry = try scan.pages()[index]
        let fonts = try #require(scan.dictionary(scan.dictionary(entry.inheritedResources)?["Font"]))
        return try #require(fonts.values.first.flatMap { scan.dictionary($0) })
    }
}

// MARK: - Font programs other than TrueType (finding 19)

extension HardeningFixtures {

    /// Core Text text in a CFF-outlined system font: a simple font (`/Type1C`) for a Latin face,
    /// a CID-keyed one (`/CIDFontType0C`) for a CJK face.
    static func coreTextFonts(at url: URL, fontName: String) throws {
        var box = CGRect(x: 0, y: 0, width: 420, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        for (string, y) in [("tender summary", 250.0), ("QXZJK 4820000", 150.0)] {
            let font = CTFontCreateWithName(fontName as CFString, 18, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 70, y: y)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
    }

    /// A Type 1 charstring: numbers and operators, encrypted with lenIV 4.
    static func type1Charstring(_ items: [Int], operators: Set<Int> = []) -> [UInt8] {
        var plain: [UInt8] = [0, 0, 0, 0]
        for (index, item) in items.enumerated() {
            if operators.contains(index) { plain.append(UInt8(item)); continue }
            switch item {
            case -107...107: plain.append(UInt8(item + 139))
            case 108...1131: plain += [UInt8((item - 108) / 256 + 247), UInt8((item - 108) % 256)]
            case -1131 ... -108: plain += [UInt8((-item - 108) / 256 + 251), UInt8((-item - 108) % 256)]
            default:
                let bits = UInt32(bitPattern: Int32(item))
                plain += [255, UInt8(bits >> 24), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
            }
        }
        return RedactionType1.encrypt(plain, key: RedactionType1.charstringKey)
    }

    /// Glyph outlines of the hand-built Type 1 font: /A (with subroutine 5), /Q (with
    /// subroutine 4, used by nothing else), /space and /.notdef.
    static let type1Glyphs: [(name: String, items: [Int], operators: Set<Int>)] = [
        (".notdef", [0, 500, 13, 14], [2, 3]),
        ("space", [0, 250, 13, 14], [2, 3]),
        ("A", [0, 600, 13, 100, 0, 21, 400, 0, 5, 0, 700, 5, -400, 0, 5, 9, 5, 10, 14], [2, 5, 8, 11, 14, 15, 17, 18]),
        ("Q", [0, 700, 13, 100, 100, 21, 4, 10, 9, 14], [2, 5, 7, 8, 9])
    ]
    /// Subroutines 0–3 are bare returns; 4 draws part of Q, 5 a bar inside A.
    static let type1Subrs: [(items: [Int], operators: Set<Int>)] = [
        ([11], [0]), ([11], [0]), ([11], [0]), ([11], [0]),
        ([500, 0, 5, 0, 500, 5, -500, 0, 5, 11], [2, 5, 8, 9]),
        ([100, 200, 21, 200, 0, 5, 11], [2, 5, 6])
    ]

    /// A Type 1 program built by hand: clear part, eexec-encrypted private part, trailer.
    static func type1Program() -> (bytes: [UInt8], length1: Int, length2: Int, length3: Int) {
        let clear = Array("""
        %!PS-AdobeFont-1.0: ZenitTest 001.000
        12 dict begin
        /FontInfo 2 dict dup begin /FullName (Zenit Test) readonly def end readonly def
        /FontName /ZenitTest def
        /PaintType 0 def
        /FontType 1 def
        /FontMatrix [0.001 0 0 0.001 0 0] readonly def
        /Encoding StandardEncoding def
        /FontBBox {0 0 1000 1000} readonly def
        currentdict end
        currentfile eexec

        """.utf8)
        var plain: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        plain += Array("""
        dup /Private 9 dict dup begin
        /RD {string currentfile exch readstring pop} executeonly def
        /ND {noaccess def} executeonly def
        /NP {noaccess put} executeonly def
        /lenIV 4 def
        /BlueValues [] def
        /MinFeature {16 16} def
        /password 5839 def
        /Subrs \(type1Subrs.count) array

        """.utf8)
        for (index, subr) in type1Subrs.enumerated() {
            let data = type1Charstring(subr.items, operators: subr.operators)
            plain += Array("dup \(index) \(data.count) RD ".utf8) + data + Array(" NP\n".utf8)
        }
        plain += Array("ND\n2 index /CharStrings \(type1Glyphs.count) dict dup begin\n".utf8)
        for glyph in type1Glyphs {
            let data = type1Charstring(glyph.items, operators: glyph.operators)
            plain += Array("/\(glyph.name) \(data.count) RD ".utf8) + data + Array(" ND\n".utf8)
        }
        plain += Array("end\nend\nreadonly put\nnoaccess put\ndup /FontName get exch definefont pop\nmark currentfile closefile\n".utf8)
        let encrypted = RedactionType1.encrypt(plain, key: RedactionType1.eexecKey)
        let trailer = Array((String(repeating: String(repeating: "0", count: 64) + "\n", count: 8) + "cleartomark\n").utf8)
        return (clear + encrypted + trailer, clear.count, encrypted.count, trailer.count)
    }

    /// A sheet in the hand-built Type 1 font: “A Q” with Q under the box, and another “A”.
    static func type1Sheet() -> Data {
        RedactionFixturePDF.assemble(pageCount: 1, mediaBox: "[0 0 420 300]") { pdf, _ in
            let program = type1Program()
            let file = pdf.addStream("/Length1 \(program.length1) /Length2 \(program.length2) /Length3 \(program.length3)", Data(program.bytes))
            let widths = (32...81).map { code -> String in
                switch code {
                case 32: return "250"
                case 65: return "600"
                case 81: return "700"
                default: return "0"
                }
            }.joined(separator: " ")
            let descriptor = pdf.add("<< /Type /FontDescriptor /FontName /ZenitTest /Flags 32 /FontBBox [0 0 1000 1000] /ItalicAngle 0 /Ascent 1000 /Descent 0 /CapHeight 700 /StemV 80 /FontFile \(file) 0 R >>")
            let font = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /ZenitTest /FirstChar 32 /LastChar 81 /Widths [\(widths)] /Encoding /WinAnsiEncoding /FontDescriptor \(descriptor) 0 R >>")
            let content = "BT /F1 60 Tf 40 180 Td (A Q) Tj ET BT /F1 60 Tf 40 60 Td (A) Tj ET"
            return ([HardeningPage(content, resources: "<< /Font << /F1 \(font) 0 R >> >>")], "")
        }
    }
}

extension HardeningFixtures {

    /// A sheet whose simple font embeds a whole OpenType program with CFF outlines
    /// (`/FontFile3 /OpenType`), assembled from a system font's tables; widths from Core Text.
    static func openTypeCFFSheet(fontName: String = "KohinoorBangla-Regular") throws -> Data {
        let font = CTFontCreateWithName(fontName as CFString, 1000, nil)
        // The array holds the tags themselves, unboxed.
        var tags: [Int] = []
        if let available = CTFontCopyAvailableTables(font, []) {
            for index in 0..<CFArrayGetCount(available) {
                tags.append(Int(bitPattern: CFArrayGetValueAtIndex(available, index)))
            }
        }
        var tables: [String: [UInt8]] = [:]
        for tag in tags {
            guard let data = CTFontCopyTable(font, CTFontTableTag(tag), []) as Data? else { continue }
            let name = String(bytes: [UInt8(tag >> 24 & 0xFF), UInt8(tag >> 16 & 0xFF), UInt8(tag >> 8 & 0xFF), UInt8(tag & 0xFF)], encoding: .ascii) ?? ""
            tables[name] = [UInt8](data)
        }
        #expect(tables["CFF "] != nil, "\(fontName) has CFF outlines")
        let program = RedactionTrueType.serialize(RedactionTrueType.Font(version: 0x4F54_544F, tables: tables))
        var widths: [String] = []
        for code in 32...126 {
            var character = UniChar(code)
            var glyph = CGGlyph(0)
            CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
            var glyphs = [glyph]
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
            widths.append(String(Int(advance.width.rounded())))
        }
        return RedactionFixturePDF.assemble(pageCount: 1, mediaBox: "[0 0 420 300]") { pdf, _ in
            let file = pdf.addStream("/Subtype /OpenType", Data(program))
            let descriptor = pdf.add("<< /Type /FontDescriptor /FontName /\(fontName) /Flags 32 /FontBBox [-200 -300 1200 1000] /ItalicAngle 0 /Ascent 900 /Descent -250 /CapHeight 700 /StemV 80 /FontFile3 \(file) 0 R >>")
            let pdfFont = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /\(fontName) /FirstChar 32 /LastChar 126 /Widths [\(widths.joined(separator: " "))] /Encoding /WinAnsiEncoding /FontDescriptor \(descriptor) 0 R >>")
            let content = "BT /F1 18 Tf 70 250 Td (tender summary) Tj ET BT /F1 18 Tf 70 150 Td (QXZJK 4820000) Tj ET"
            return ([HardeningPage(content, resources: "<< /Font << /F1 \(pdfFont) 0 R >> >>")], "")
        }
    }
}
