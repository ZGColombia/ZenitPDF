import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import ZPDFPDFKitBridge

/// Layer membership carried on **annotations**, which is the half the product did not read.
///
/// Measured on a real elevation set, 2026-08-26: two layers, no page content in either, and
/// seven `/OC` line annotations. `VectorLayerVisibilityFilter` filters marked content, so hiding
/// a layer on that drawing did nothing at all.
///
/// The fixture here is that drawing's shape in miniature: two OCGs, no marked content, and three
/// line annotations — one bound directly to each layer, and one bound through an `/OCMD`,
/// because both spellings exist in the wild.
@Suite
struct AnnotationLayerBindingTests {

    /// A raw two-layer PDF with `/OC` on its annotations. Hand-assembled so every byte is known.
    private func writeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-annot-oc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("annot-layers.pdf")

        let content = Data("0 0 m 100 100 l S\n".utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /Order [5 0 R 6 0 R] >> >> >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Annots [7 0 R 8 0 R 9 0 R] >>".utf8),
        ]
        var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        stream.append(content)
        stream.append(Data("\nendstream".utf8))
        objects.append(stream)
        objects.append(Data("<< /Type /OCG /Name (Innerväggar) >>".utf8))
        objects.append(Data("<< /Type /OCG /Name (Måttkontroll) >>".utf8))
        // Annotation 0 → layer 0, directly.
        objects.append(Data("<< /Type /Annot /Subtype /Line /Rect [10 10 200 20] /L [10 15 200 15] /OC 5 0 R /F 4 >>".utf8))
        // Annotation 1 → layer 1, directly.
        objects.append(Data("<< /Type /Annot /Subtype /Line /Rect [10 30 200 40] /L [10 35 200 35] /OC 6 0 R /F 4 >>".utf8))
        // Annotation 2 → layer 1, through an /OCMD.
        objects.append(Data("<< /Type /Annot /Subtype /Line /Rect [10 50 200 60] /L [10 55 200 55] /OC << /Type /OCMD /OCGs 6 0 R >> /F 4 >>".utf8))

        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try pdf.write(to: url)
        return url
    }

    @Test("Every /OC annotation is bound to its layer, direct and via /OCMD alike")
    func bindingsAreRead() throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(CGPDFDocument(url as CFURL))

        let bindings = AnnotationLayerBindingReader.read(from: document)
        #expect(bindings.count == 3, "expected 3 bindings, got \(bindings.count)")
        #expect(bindings.filter { $0.layerID.rawValue == "ocg:0" }.map(\.annotationIndex) == [0])
        #expect(
            bindings.filter { $0.layerID.rawValue == "ocg:1" }.map(\.annotationIndex).sorted() == [1, 2],
            "the /OCMD-bound annotation was not resolved to its layer"
        )
        #expect(bindings.allSatisfy { $0.pageIndex == 0 })
    }

    @Test("Hiding a layer switches exactly its annotations off, and showing switches them back")
    func visibilityIsApplied() async throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let bindings = try await provider.annotationLayerBindings(of: opened.handle)
        #expect(bindings.count == 3)

        // Hide layer 1 — "Måttkontroll".
        let changed = try await provider.applyAnnotationLayerVisibility(
            of: opened.handle,
            bindings: bindings,
            hiddenLayerIDs: [PDFLayerID(rawValue: "ocg:1")]
        )
        #expect(changed == 2, "hiding the layer changed \(changed) annotations, not its 2")

        // Show it again: everything returns, and the count says both moved back.
        let restored = try await provider.applyAnnotationLayerVisibility(
            of: opened.handle,
            bindings: bindings,
            hiddenLayerIDs: []
        )
        #expect(restored == 2)

        // Idempotent: applying the same state again touches nothing.
        let again = try await provider.applyAnnotationLayerVisibility(
            of: opened.handle,
            bindings: bindings,
            hiddenLayerIDs: []
        )
        #expect(again == 0)
    }

    @Test("A document with no /OCProperties yields no bindings and no work")
    func plainDocumentYieldsNothing() throws {
        // The calibration fixture: geometry, no layers at all.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-annot-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("plain.pdf")
        let content = Data("2 w 0 0 0 RG\n72 72 m 372 72 l S\n".utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>".utf8)
        ]
        var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        stream.append(content)
        stream.append(Data("\nendstream".utf8))
        objects.append(stream)
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try pdf.write(to: url)

        let document = try #require(CGPDFDocument(url as CFURL))
        #expect(AnnotationLayerBindingReader.read(from: document).isEmpty)
    }

    // MARK: - CR-84: the walk is bounded

    /// A one-page PDF with `count` line annotations, each bound to a single OCG through `/OC`.
    private func writeManyAnnotationsFixture(count: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-annot-many-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("many.pdf")

        // Object 5 is the OCG; annotations are objects 6…(5+count).
        let annotRefs = (0..<count).map { "\(6 + $0) 0 R" }.joined(separator: " ")
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R] /D << /Order [5 0 R] >> >> >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Annots [\(annotRefs)] >>".utf8),
            Data("<< /Length 0 >>\nstream\n\nendstream".utf8),
            Data("<< /Type /OCG /Name (Layer) >>".utf8)
        ]
        for index in 0..<count {
            let y = 10 + (index % 80) * 10
            objects.append(Data(
                "<< /Type /Annot /Subtype /Line /Rect [10 \(y) 200 \(y + 8)] /L [10 \(y + 4) 200 \(y + 4)] /OC 5 0 R /F 4 >>".utf8
            ))
        }

        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try pdf.write(to: url)
        return url
    }

    @Test("The per-page annotation cap bounds the binding walk (CR-84)")
    func bindingWalkIsBounded() throws {
        let url = try writeManyAnnotationsFixture(count: 40)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(CGPDFDocument(url as CFURL))

        // Unbounded, this walked all 40. With the cap it reads at most 8.
        var limits = DocumentLimits.standard
        limits.maximumAnnotationsPerPage = 8
        let bindings = AnnotationLayerBindingReader.read(from: document, limits: limits)
        #expect(bindings.count == 8, "cap not honoured: \(bindings.count) bindings")
    }

    @Test("The total node budget bounds the binding walk (CR-84)")
    func bindingBudgetIsBounded() throws {
        let url = try writeManyAnnotationsFixture(count: 40)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(CGPDFDocument(url as CFURL))

        var limits = DocumentLimits.standard
        limits.maximumHazardScanNodes = 5
        let bindings = AnnotationLayerBindingReader.read(from: document, limits: limits)
        #expect(bindings.count <= 5, "budget not honoured: \(bindings.count) bindings")
    }

    // MARK: - CR-88: annotation identity, not array index

    @Test("A binding resolves to its annotation by /NM even when the index points elsewhere")
    func matchByName() throws {
        let alpha = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), forType: .line, withProperties: nil)
        alpha.setValue("alpha", forAnnotationKey: PDFAnnotationKeys.name)
        let beta = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), forType: .line, withProperties: nil)
        beta.setValue("beta", forAnnotationKey: PDFAnnotationKeys.name)

        // The stale index says 0 (alpha), but the binding names beta.
        let binding = AnnotationLayerBindingReader.Binding(
            pageIndex: 0, annotationIndex: 0, layerID: PDFLayerID(rawValue: "ocg:0"), annotationName: "beta"
        )
        let matched = PDFKitDocumentProvider.matchAnnotation(binding, in: [alpha, beta])
        #expect(matched === beta, "identity match should pick beta, not the index-0 alpha")
    }

    @Test("A binding resolves by rect + subtype when there is no /NM")
    func matchByRectAndSubtype() throws {
        let first = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), forType: .line, withProperties: nil)
        let second = PDFAnnotation(bounds: CGRect(x: 50, y: 60, width: 20, height: 5), forType: .line, withProperties: nil)
        let binding = AnnotationLayerBindingReader.Binding(
            pageIndex: 0, annotationIndex: 0, layerID: PDFLayerID(rawValue: "ocg:0"),
            subtype: "Line", rect: CGRect(x: 50, y: 60, width: 20, height: 5)
        )
        let matched = PDFKitDocumentProvider.matchAnnotation(binding, in: [first, second])
        #expect(matched === second)
    }

    @Test("A binding falls back to the array index only when identity cannot decide")
    func matchFallsBackToIndex() throws {
        // Identical rect and subtype, no names: identity is ambiguous, so the index decides.
        let first = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), forType: .square, withProperties: nil)
        let second = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), forType: .square, withProperties: nil)
        let binding = AnnotationLayerBindingReader.Binding(
            pageIndex: 0, annotationIndex: 1, layerID: PDFLayerID(rawValue: "ocg:0")
        )
        let matched = PDFKitDocumentProvider.matchAnnotation(binding, in: [first, second])
        #expect(matched === second)
    }
}
