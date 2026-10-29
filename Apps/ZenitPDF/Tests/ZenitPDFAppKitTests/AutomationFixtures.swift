import AppKit
import Foundation
@testable import ZenitPDFAppKit

/// Hand-written PDFs for the automation app-tier tests. Every coordinate is chosen in
/// the test that uses it, so the expected quantities are derived from the fixture by hand.
@MainActor
enum AutomationFixtures {

    /// Writes raw PDF objects (numbered from 1; object 1 must be the catalogue) into a fresh
    /// scratch directory and returns the file.
    static func writePDF(named name: String, objects: [String], streams: [Int: String] = [:]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            if let stream = streams[index + 1] {
                let content = Data(stream.utf8)
                bytes.append(Data("<< /Length \(content.count) >>\nstream\n".utf8))
                bytes.append(content)
                bytes.append(Data("\nendstream".utf8))
            } else {
                bytes.append(Data(object.utf8))
            }
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
        return url
    }

    /// A one-page drawing whose content streams are given, with the Helvetica font as `/F1`.
    static func writeSinglePage(
        named name: String,
        mediaBox: String = "0 0 595 842",
        content: String
    ) throws -> URL {
        try writePDF(
            named: name,
            objects: [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [\(mediaBox)] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
                "",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
            ],
            streams: [4: content]
        )
    }

    /// A multi-page drawing: one content stream per page, all pages sharing `/F1`.
    static func writePages(named name: String, mediaBox: String = "0 0 595 842", contents: [String]) throws -> URL {
        // 1 catalogue, 2 pages, 3 font, then page n = 4 + 2n, its stream = 5 + 2n.
        let kids = contents.indices.map { "\(4 + 2 * $0) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(kids)] /Count \(contents.count) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        var streams: [Int: String] = [:]
        for (index, content) in contents.enumerated() {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [\(mediaBox)] /Contents \(5 + 2 * index) 0 R /Resources << /Font << /F1 3 0 R >> >> >>")
            objects.append("")
            streams[5 + 2 * index] = content
        }
        return try writePDF(named: name, objects: objects, streams: streams)
    }

    /// A room 72…372 × 72…272 (300 × 200 pt) on layer "Walls", split at x = 222 by a line on
    /// layer "Furniture". Both layers visible by default.
    static func writeLayeredRoom() throws -> URL {
        let content = """
        1 w 0 0 0 RG
        /OC /W BDC 72 72 m 372 72 l 372 272 l 72 272 l h S EMC
        /OC /F BDC 222 72 m 222 272 l S EMC
        """
        return try writePDF(
            named: "Layered Room.pdf",
            objects: [
                "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /Order [5 0 R 6 0 R] /ON [5 0 R 6 0 R] >> >> >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Properties << /W 5 0 R /F 6 0 R >> >> >>",
                "",
                "<< /Type /OCG /Name (Walls) >>",
                "<< /Type /OCG /Name (Furniture) >>"
            ],
            streams: [4: content]
        )
    }

    /// A scanned set: every page is one raster image with no text layer, showing a sheet number
    /// and title at the given page positions (A3 landscape, drawn at 3 px per point).
    static func writeScannedSheets(named name: String, sheets: [(number: String, title: String)]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-scanned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 1191, height: 842)
        guard let pdf = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw AppTestSupport.FixtureError(reason: "no PDF context")
        }
        let scale: CGFloat = 3
        for sheet in sheets {
            let width = Int(mediaBox.width * scale), height = Int(mediaBox.height * scale)
            guard let bitmap = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { throw AppTestSupport.FixtureError(reason: "no bitmap") }
            bitmap.setFillColor(gray: 1, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let graphics = NSGraphicsContext(cgContext: bitmap, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            func draw(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont(name: "Helvetica", size: size * scale) ?? NSFont.systemFont(ofSize: size * scale),
                    .foregroundColor: NSColor.black
                ]
                (text as NSString).draw(at: CGPoint(x: x * scale, y: y * scale), withAttributes: attributes)
            }
            draw(sheet.number, 1000, 50, 14)
            draw(sheet.title, 1000, 100, 12)
            NSGraphicsContext.restoreGraphicsState()
            guard let image = bitmap.makeImage() else { throw AppTestSupport.FixtureError(reason: "no image") }
            pdf.beginPDFPage(nil)
            pdf.draw(image, in: mediaBox)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return url
    }
}
