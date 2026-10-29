import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import ZPDFPDFKitBridge

/// Regression tests for the catalogue, layer and smaller provider findings of bug hunt 2:
/// BH-175, BH-176/BH-580, BH-177, BH-179, BH-573, BH-579, BH-581, BH-582/BH-583, BH-584,
/// BH-587, BH-588, BH-589.
@Suite("Fix 2 — catalogue, layers and small provider fixes")
struct Fix2CatalogAndLayerTests {

    private func cgDocument(_ url: URL) throws -> CGPDFDocument {
        try #require(CGPDFDocument(url as CFURL))
    }

    // MARK: - BH-175

    @Test("BH-175: a page PDFKit cannot materialise keeps its position in the descriptors")
    func missingPageKeepsItsPosition() {
        let labels = PageLabelTable(pageCount: 10, ranges: [], isExplicit: false)
        // Old code `continue`d past a nil page, so the array was 9 long and every later page
        // was paired with the wrong descriptor.
        let descriptor = PDFKitDocumentProvider.pageDescriptor(index: 4, page: nil, labels: labels)
        #expect(descriptor.index == 4)
        #expect(descriptor.label == "5")
        #expect(descriptor.boxes.media == .zero)
        #expect(descriptor.rotation == 0)
    }

    // MARK: - BH-176 / BH-580

    @Test("BH-176/BH-580: a group listed twice binds annotations to its first /OCGs index")
    func duplicateGroupBindsFirstIndex() throws {
        let url = try HandBuiltPDF.onePage(
            content: "",
            pageExtra: "/Annots [6 0 R]",
            catalogExtra: "/OCProperties << /OCGs [5 0 R 7 0 R 5 0 R] /D << /Order [5 0 R 7 0 R] >> >>",
            additional: [
                "<< /Type /OCG /Name (Walls) >>",
                "<< /Type /Annot /Subtype /Line /Rect [10 10 100 20] /L [10 15 100 15] /OC 5 0 R /F 4 >>",
                "<< /Type /OCG /Name (Grid) >>"
            ],
            label: "duplicate-ocgs"
        )
        let document = try cgDocument(url)
        let bindings = AnnotationLayerBindingReader.read(from: document)
        // Old code: ocg:2 (last occurrence) while the layer tree binds the group to ocg:0.
        #expect(bindings.map(\.layerID) == [PDFLayerID(rawValue: "ocg:0")])
        let tree = try #require(try LayerCatalogReader.read(document: document, limits: .standard))
        #expect(tree.outline.first?.layerID == PDFLayerID(rawValue: "ocg:0"))
    }

    // MARK: - BH-177

    @Test("BH-177: a budget cut is reported as truncated, not as a complete list")
    func truncatedWalkIsReported() throws {
        let annotations = (0..<5).map { "\(6 + $0) 0 R" }.joined(separator: " ")
        let url = try HandBuiltPDF.onePage(
            content: "",
            pageExtra: "/Annots [\(annotations)]",
            catalogExtra: "/OCProperties << /OCGs [5 0 R] /D << /Order [5 0 R] >> >>",
            additional: ["<< /Type /OCG /Name (Walls) >>"] + (0..<5).map {
                "<< /Type /Annot /Subtype /Line /Rect [10 \(10 + $0 * 20) 100 \(20 + $0 * 20)] /OC 5 0 R /F 4 >>"
            },
            label: "binding-budget"
        )
        let document = try cgDocument(url)
        var limits = DocumentLimits.standard
        limits.maximumHazardScanNodes = 3
        let cut = AnnotationLayerBindingReader.readReport(from: document, limits: limits)
        // Old code: a bare array of 3 bindings, indistinguishable from a complete walk.
        #expect(cut.bindings.count == 3)
        #expect(cut.wasTruncated)
        let complete = AnnotationLayerBindingReader.readReport(from: document)
        #expect(complete.bindings.count == 5)
        #expect(complete.wasTruncated == false)
        #expect(AnnotationLayerBindingReader.read(from: document, limits: limits).count == 3)
    }

    // MARK: - BH-581

    @Test("BH-581: an /OCMD /P /AllOff annotation is shown when its layer is hidden")
    func allOffPolicyInvertsVisibility() async throws {
        let url = try HandBuiltPDF.onePage(
            content: "",
            pageExtra: "/Annots [6 0 R 7 0 R]",
            catalogExtra: "/OCProperties << /OCGs [5 0 R] /D << /Order [5 0 R] >> >>",
            additional: [
                "<< /Type /OCG /Name (Demolition) >>",
                "<< /Type /Annot /Subtype /Line /Rect [10 10 100 20] /L [10 15 100 15] /OC << /Type /OCMD /OCGs 5 0 R /P /AllOff >> /F 4 >>",
                "<< /Type /Annot /Subtype /Line /Rect [10 40 100 50] /L [10 45 100 45] /OC 5 0 R /F 4 >>"
            ],
            label: "ocmd-alloff"
        )
        let bindings = AnnotationLayerBindingReader.read(from: try cgDocument(url))
        #expect(bindings.count == 2)
        let inverted = try #require(bindings.first { $0.annotationIndex == 0 })
        let direct = try #require(bindings.first { $0.annotationIndex == 1 })
        let hidden: Set<PDFLayerID> = [PDFLayerID(rawValue: "ocg:0")]
        // Old code bound it as /AnyOn: hidden with its layer, the opposite of the spec.
        #expect(inverted.invertsVisibility)
        #expect(inverted.shouldDisplay(hiddenLayerIDs: hidden))
        #expect(!inverted.shouldDisplay(hiddenLayerIDs: []))
        #expect(!direct.invertsVisibility)
        #expect(!direct.shouldDisplay(hiddenLayerIDs: hidden))

        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        _ = try await provider.applyAnnotationLayerVisibility(
            of: opened.handle, bindings: bindings, hiddenLayerIDs: hidden
        )
        await provider.close(opened.handle)
    }

    // MARK: - BH-582 / BH-583

    @Test("BH-582/BH-583: JavaScript or Launch chained through /Next is reported")
    func nextChainsAreFollowed() throws {
        let url = try HandBuiltPDF.onePage(
            content: "",
            pageExtra: "/Annots [5 0 R]",
            catalogExtra: "/OpenAction << /S /GoTo /D [3 0 R /Fit] /Next << /S /JavaScript /JS (app.alert(1)) >> >>",
            additional: [
                "<< /Type /Annot /Subtype /Link /Rect [0 0 50 50] /A << /S /GoTo /D [3 0 R /Fit] /Next [<< /S /URI /URI (https://example.invalid) >> << /S /Launch /F (calc) >>] >> >>"
            ],
            label: "next-chain"
        )
        let report = CatalogInspector.inspect(document: try cgDocument(url), limits: .standard)
        // Old code: .openAction only — the chained script and launch were invisible.
        #expect(report.hazards.contains(.openAction))
        #expect(report.hazards.contains(.javaScriptAction))
        #expect(report.hazards.contains(.launchAction))
        #expect(report.hazards.contains(.externalURIAction))
    }

    @Test("BH-582: a cyclic /Next chain terminates")
    func cyclicNextChainTerminates() throws {
        let url = try HandBuiltPDF.onePage(
            content: "",
            catalogExtra: "/OpenAction 5 0 R",
            additional: [
                "<< /S /GoTo /D [3 0 R /Fit] /Next 6 0 R >>",
                "<< /S /GoTo /D [3 0 R /Fit] /Next 5 0 R >>"
            ],
            label: "cyclic-next"
        )
        let report = CatalogInspector.inspect(document: try cgDocument(url), limits: .standard)
        #expect(report.hazards.contains(.openAction))
        #expect(!report.hazards.contains(.javaScriptAction))
    }

    // MARK: - BH-584

    @Test("BH-584: an embedded file's size is its declared uncompressed size")
    func embeddedFileSizeIsUncompressed() throws {
        let flate = HandBuiltPDF.stream(
            "xxxxxxxxxx",
            extra: "/Type /EmbeddedFile /Filter /FlateDecode /Params << /Size 12582912 >>"
        )
        let flateUnknown = HandBuiltPDF.stream("yyyyyyyy", extra: "/Type /EmbeddedFile /Filter /FlateDecode")
        let plain = HandBuiltPDF.stream("zzzzzz", extra: "/Type /EmbeddedFile")
        let url = try HandBuiltPDF.onePage(
            content: "",
            catalogExtra: "/Names << /EmbeddedFiles << /Names [(a.xlsx) 5 0 R (b.bin) 7 0 R (c.txt) 9 0 R] >> >>",
            additional: [
                "<< /Type /Filespec /F (a.xlsx) /EF << /F 6 0 R >> >>", flate,
                "<< /Type /Filespec /F (b.bin) /EF << /F 8 0 R >> >>", flateUnknown,
                "<< /Type /Filespec /F (c.txt) /EF << /F 10 0 R >> >>", plain
            ],
            label: "embedded-sizes"
        )
        let report = CatalogInspector.inspect(document: try cgDocument(url), limits: .standard)
        let sizes = Dictionary(uniqueKeysWithValues: report.embeddedFiles.map { ($0.name, $0.declaredByteCount) })
        // Old code: /Length — 10, 8 and 6 — the encoded byte count.
        #expect(sizes["a.xlsx"] == .some(12_582_912))
        #expect(sizes["b.bin"] == .some(nil))
        #expect(sizes["c.txt"] == .some(6))
    }

    // MARK: - BH-587

    @Test("BH-587: CRLF-separated keywords split into separate keywords")
    func crlfKeywordsSplit() throws {
        let url = try HandBuiltPDF.write(
            [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                "<< /Keywords (Alpha\\r\\nBeta; Gamma\\rDelta,Epsilon\\nZeta) >>"
            ],
            label: "crlf-keywords",
            trailerExtra: "/Info 4 0 R"
        )
        let attributes = CatalogInspector.documentInfo(document: try cgDocument(url))
        // Old code: ["Alpha\r\nBeta", "Gamma", "Delta", "Epsilon", "Zeta"].
        #expect(attributes.keywords == ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta"])
    }

    // MARK: - BH-588

    @Test("BH-588: a labelled /Order group keeps its nested child arrays and sub-groups")
    func labelledGroupKeepsNesting() throws {
        let url = try HandBuiltPDF.onePage(
            content: "",
            catalogExtra: "/OCProperties << /OCGs [5 0 R 6 0 R 7 0 R 8 0 R] /D << /Order [[(Architectural) 5 0 R [6 0 R] [(Services) 7 0 R]] 8 0 R] >> >>",
            additional: [
                "<< /Type /OCG /Name (Walls) >>",
                "<< /Type /OCG /Name (Doors) >>",
                "<< /Type /OCG /Name (Ducts) >>",
                "<< /Type /OCG /Name (Grid) >>"
            ],
            label: "labelled-order"
        )
        let tree = try #require(try LayerCatalogReader.read(document: try cgDocument(url), limits: .standard))
        // Old code: Architectural held only Walls; Doors and Ducts fell out to the root:
        // [Architectural[Walls], Grid, Doors, Ducts].
        #expect(tree.outline.count == 2)
        let architectural = try #require(tree.outline.first)
        #expect(architectural.title == "Architectural")
        #expect(architectural.layerID == nil)
        #expect(architectural.children.count == 2)
        let walls = architectural.children[0]
        #expect(walls.layerID == PDFLayerID(rawValue: "ocg:0"))
        #expect(walls.children.map(\.layerID) == [PDFLayerID(rawValue: "ocg:1")])
        let services = architectural.children[1]
        #expect(services.title == "Services")
        #expect(services.children.map(\.layerID) == [PDFLayerID(rawValue: "ocg:2")])
        #expect(tree.outline[1].layerID == PDFLayerID(rawValue: "ocg:3"))
    }

    // MARK: - BH-589

    @Test("BH-589: a /Type-less /OCMD in /Properties binds marked content like annotations")
    func typelessOCMDBindsMarkedContent() throws {
        let url = try HandBuiltPDF.write(
            [
                "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R] /D << /Order [5 0 R] >> >> >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Properties << /MC0 << /OCGs 5 0 R >> >> >> /Contents 4 0 R >>",
                HandBuiltPDF.stream("/OC /MC0 BDC 0 0 m 50 50 l S EMC"),
                "<< /Type /OCG /Name (Walls) >>"
            ],
            label: "typeless-ocmd"
        )
        let tree = try #require(try LayerCatalogReader.read(document: try cgDocument(url), limits: .standard))
        // Old code: no page binding at all — hiding Walls left its marked content visible.
        let binding = try #require(tree.pageBindings.first { $0.pageIndex == 0 })
        #expect(binding.propertyNamesByLayer[PDFLayerID(rawValue: "ocg:0")] == ["MC0"])
    }

    // MARK: - BH-179

    @Test("BH-179: a drawing opened through a symlink has the real file's size and digest")
    func symlinkUsesTargetSize() async throws {
        let target = try HandBuiltPDF.pages(3, label: "symlink-target")
        let link = target.deletingLastPathComponent().appendingPathComponent("A-101-link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let real = try FileDigestReader.fileByteCount(at: target)
        // Old code: the link's own size (its path length), so the digest covered one chunk of
        // the drawing and the probe missed %%EOF.
        #expect(try FileDigestReader.fileByteCount(at: link) == real)
        let viaLink = try FileDigestReader.digest(ofFileAt: link, maximumByteCount: .max)
        let direct = try FileDigestReader.digest(ofFileAt: target, maximumByteCount: .max)
        #expect(viaLink == direct)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: link)
        #expect(opened.descriptor.digest == direct)
        #expect(opened.descriptor.integrity == .intact)
        await provider.close(opened.handle)
    }

    // MARK: - BH-573

    @Test("BH-573: a page index listed twice is searched and counted once")
    func duplicateSearchPagesAreSearchedOnce() async throws {
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        let url = try HandBuiltPDF.write(
            [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
                HandBuiltPDF.stream("BT /F1 24 Tf 20 100 Td (WALL TYPE A) Tj ET"),
                font
            ],
            label: "searchable"
        )
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let once = try await provider.search(
            in: opened.handle, query: "WALL", options: TextSearchOptions(pageIndices: [0])
        )
        let twice = try await provider.search(
            in: opened.handle, query: "WALL", options: TextSearchOptions(pageIndices: [0, 0])
        )
        #expect(once.hits.count == 1)
        // Old code: 2 hits and pagesSearched == 2.
        #expect(twice.hits.count == once.hits.count)
        #expect(twice.pagesSearched == 1)
        await provider.close(opened.handle)
    }

    // MARK: - BH-579

    @Test("BH-579: rotating a page listed twice rotates it once")
    func duplicateRotateIndexAppliesOnce() throws {
        let document = DocumentHandle(rawValue: 1)
        let plan = try PageOperationPlanner.plan(
            operations: [.rotate(pageIndices: [0, 0], change: .relative(degrees: 90))],
            document: document,
            initialRotations: [0, 0],
            pageCounts: [document: 2],
            limits: .standard
        )
        // Old code: 180 — the relative change applied once per duplicate.
        #expect(plan.resultingPages[0].rotation == 90)
        #expect(plan.resultingPages[1].rotation == 0)
    }
}
