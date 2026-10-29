import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// Reading annotations as values, writing them into a copy, and never touching the
/// original.
@Suite("Annotation IO")
struct AnnotationIOTests {

    struct Fixture {
        let provider: PDFKitDocumentProvider
        let handle: DocumentHandle
        let source: URL
        let scratch: URL
        let sha256Before: String
    }

    func makeFixture(_ label: String, kind: FixtureKind = .titleBlockSheet) async throws -> Fixture {
        let scratch = try Corpus.scratchDirectory(label)
        let source = scratch.appendingPathComponent(kind.fileName)
        try FileManager.default.copyItem(at: Corpus.url(kind), to: source)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: source)
        return Fixture(
            provider: provider,
            handle: opened.handle,
            source: source,
            scratch: scratch,
            sha256Before: try FileDigestProbe.hex(of: source)
        )
    }

    @Test("A corpus fixture starts with no annotations at all")
    func noAnnotations() async throws {
        let fixture = try await makeFixture("annot-none")
        #expect(try await fixture.provider.annotations(of: fixture.handle, pageIndex: 0).isEmpty)
        #expect(try await fixture.provider.allAnnotations(of: fixture.handle).isEmpty)
    }

    @Test("Annotations written into a copy round-trip as values, and the original is byte-identical")
    func writeRoundTripLeavesOriginalUntouched() async throws {
        let fixture = try await makeFixture("annot-write")
        let destination = DocumentDestination(
            url: fixture.scratch.appendingPathComponent("with-annotations.pdf")
        )

        let square = NeutralAnnotation(
            pageIndex: 0,
            kind: .square,
            bounds: CGRect(x: 100, y: 200, width: 300, height: 150),
            contents: "Wall type A — 12 m",
            subject: "Takeoff note",
            author: "Estimator",
            color: AnnotationColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
            borderWidth: 2
        )
        let note = NeutralAnnotation(
            pageIndex: 0,
            kind: .text,
            bounds: CGRect(x: 500, y: 600, width: 20, height: 20),
            contents: "Check dimension"
        )

        let receipt = try await fixture.provider.writeAnnotations(
            AnnotationWriteRequest(annotations: [square, note]),
            of: fixture.handle,
            to: destination
        )

        // The guarantee, asserted with an independent hash of the file on disk.
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)
        #expect(receipt.sourceIsUnchanged)
        #expect(receipt.sourceDigestBefore?.sha256 == fixture.sha256Before)
        #expect(receipt.sourceDigestAfter?.sha256 == fixture.sha256Before)
        #expect(receipt.digest.sha256 != fixture.sha256Before)
        #expect(receipt.pageCount == 1)
        #expect(receipt.destination == destination.url)

        // The in-memory document the caller still has open is untouched too.
        #expect(try await fixture.provider.annotations(of: fixture.handle, pageIndex: 0).isEmpty)

        let reader = PDFKitDocumentProvider()
        let reopened = try await reader.open(fileAt: destination.url)
        let all = try await reader.annotations(of: reopened.handle, pageIndex: 0)
        // PDFKit writes a `/Popup` companion for a `/Text` note, which is what a PDF
        // reader expects to find; it is read back as data like anything else.
        let read = all.filter { $0.kind != .popup }
        #expect(read.count == 2)
        #expect(all.count >= 2)

        let readSquare = try #require(read.first { $0.kind == .square })
        #expect(readSquare.bounds == square.bounds)
        #expect(readSquare.contents == square.contents)
        #expect(readSquare.author == square.author)
        #expect(readSquare.pageIndex == 0)
        let color = try #require(readSquare.color)
        #expect(abs(color.red - 0.2) < 0.01)
        #expect(abs(color.green - 0.4) < 0.01)
        #expect(abs(color.blue - 0.8) < 0.01)
        #expect(readSquare.borderWidth == 2)

        let readNote = try #require(read.first { $0.kind == .text })
        #expect(readNote.contents == "Check dimension")
    }

    @Test("Text-markup quadrilaterals and line endpoints survive the round trip")
    func geometryRoundTrip() async throws {
        let fixture = try await makeFixture("annot-geometry")
        let destination = DocumentDestination(
            url: fixture.scratch.appendingPathComponent("geometry.pdf")
        )
        let line = NeutralAnnotation(
            pageIndex: 0,
            kind: .line,
            bounds: CGRect(x: 100, y: 100, width: 200, height: 50),
            color: AnnotationColor(red: 1, green: 0, blue: 0),
            points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 150)]
        )
        let highlight = NeutralAnnotation(
            pageIndex: 0,
            kind: .highlight,
            bounds: CGRect(x: 200, y: 1990, width: 120, height: 24),
            quadPoints: [
                CGPoint(x: 200, y: 2014), CGPoint(x: 320, y: 2014),
                CGPoint(x: 200, y: 1990), CGPoint(x: 320, y: 1990)
            ]
        )
        _ = try await fixture.provider.writeAnnotations(
            AnnotationWriteRequest(annotations: [line, highlight]),
            of: fixture.handle,
            to: destination
        )

        let reader = PDFKitDocumentProvider()
        let reopened = try await reader.open(fileAt: destination.url)
        let read = try await reader.annotations(of: reopened.handle, pageIndex: 0)
        let readLine = try #require(read.first { $0.kind == .line })
        #expect(readLine.points.count == 2)
        #expect(readLine.points[0] == CGPoint(x: 100, y: 100))
        #expect(readLine.points[1] == CGPoint(x: 300, y: 150))

        let readHighlight = try #require(read.first { $0.kind == .highlight })
        #expect(readHighlight.quadPoints.count == 4)
    }

    @Test("Replace modes drop existing annotations only where they are asked to")
    func replaceModes() async throws {
        let fixture = try await makeFixture("annot-replace", kind: .mixedPageSizes)
        let first = DocumentDestination(url: fixture.scratch.appendingPathComponent("a.pdf"))
        _ = try await fixture.provider.writeAnnotations(
            AnnotationWriteRequest(annotations: [
                NeutralAnnotation(pageIndex: 0, kind: .square, bounds: CGRect(x: 0, y: 0, width: 10, height: 10)),
                NeutralAnnotation(pageIndex: 1, kind: .square, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
            ]),
            of: fixture.handle,
            to: first
        )

        let second = PDFKitDocumentProvider()
        let reopened = try await second.open(fileAt: first.url)
        #expect(try await second.allAnnotations(of: reopened.handle).count == 2)

        let replaced = DocumentDestination(url: fixture.scratch.appendingPathComponent("b.pdf"))
        _ = try await second.writeAnnotations(
            AnnotationWriteRequest(
                annotations: [
                    NeutralAnnotation(pageIndex: 0, kind: .circle, bounds: CGRect(x: 1, y: 1, width: 5, height: 5))
                ],
                mode: .replaceOnTouchedPages
            ),
            of: reopened.handle,
            to: replaced
        )
        let third = PDFKitDocumentProvider()
        let final = try await third.open(fileAt: replaced.url)
        let all = try await third.allAnnotations(of: final.handle)
        #expect(all.count == 2)
        #expect(all.filter { $0.pageIndex == 0 }.map(\.kind) == [.circle])
        #expect(all.filter { $0.pageIndex == 1 }.map(\.kind) == [.square])

        let wiped = DocumentDestination(url: fixture.scratch.appendingPathComponent("c.pdf"))
        _ = try await third.writeAnnotations(
            AnnotationWriteRequest(annotations: [], mode: .replaceAll),
            of: final.handle,
            to: wiped
        )
        let fourth = PDFKitDocumentProvider()
        let empty = try await fourth.open(fileAt: wiped.url)
        #expect(try await fourth.allAnnotations(of: empty.handle).isEmpty)
    }

    @Test("Writing over the source file is refused, and the source survives the attempt")
    func refusesToOverwriteSource() async throws {
        let fixture = try await makeFixture("annot-overwrite")
        let annotation = NeutralAnnotation(
            pageIndex: 0, kind: .square, bounds: CGRect(x: 0, y: 0, width: 10, height: 10)
        )

        await #expect(throws: PDFBridgeError.destinationIsSource(path: fixture.source.path)) {
            _ = try await fixture.provider.writeAnnotations(
                AnnotationWriteRequest(annotations: [annotation]),
                of: fixture.handle,
                to: DocumentDestination(url: fixture.source, overwritePolicy: .replace)
            )
        }
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)

        // A symlink to the source is refused too.
        let alias = fixture.scratch.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
        await #expect(throws: PDFBridgeError.self) {
            _ = try await fixture.provider.writeAnnotations(
                AnnotationWriteRequest(annotations: [annotation]),
                of: fixture.handle,
                to: DocumentDestination(url: alias, overwritePolicy: .replace)
            )
        }
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)
    }

    @Test("Writing over another open document's original is refused as well")
    func refusesToOverwriteAnotherOpenOriginal() async throws {
        let fixture = try await makeFixture("annot-other-open")
        let other = fixture.scratch.appendingPathComponent("other.pdf")
        try FileManager.default.copyItem(at: Corpus.url(.rectangle), to: other)
        _ = try await fixture.provider.open(fileAt: other)
        let otherBefore = try FileDigestProbe.hex(of: other)

        await #expect(throws: PDFBridgeError.destinationIsSource(path: other.path)) {
            _ = try await fixture.provider.writeAnnotations(
                AnnotationWriteRequest(annotations: []),
                of: fixture.handle,
                to: DocumentDestination(url: other, overwritePolicy: .replace)
            )
        }
        #expect(try FileDigestProbe.hex(of: other) == otherBefore)
    }

    @Test("An existing destination is refused unless replacement was asked for")
    func overwritePolicy() async throws {
        let fixture = try await makeFixture("annot-policy")
        let destination = fixture.scratch.appendingPathComponent("out.pdf")
        try Data("placeholder".utf8).write(to: destination)

        await #expect(throws: PDFBridgeError.destinationExists(path: destination.path)) {
            _ = try await fixture.provider.writeAnnotations(
                AnnotationWriteRequest(annotations: []),
                of: fixture.handle,
                to: DocumentDestination(url: destination, overwritePolicy: .fail)
            )
        }
        let receipt = try await fixture.provider.writeAnnotations(
            AnnotationWriteRequest(annotations: []),
            of: fixture.handle,
            to: DocumentDestination(url: destination, overwritePolicy: .replace)
        )
        #expect(receipt.digest.byteCount > 11)
    }

    @Test("A destination in a directory that does not exist is refused")
    func missingDestinationDirectory() async throws {
        let fixture = try await makeFixture("annot-nodir")
        let destination = fixture.scratch
            .appendingPathComponent("nope", isDirectory: true)
            .appendingPathComponent("out.pdf")
        await #expect(throws: PDFBridgeError.self) {
            _ = try await fixture.provider.writeAnnotations(
                AnnotationWriteRequest(annotations: []),
                of: fixture.handle,
                to: DocumentDestination(url: destination)
            )
        }
    }

    @Test("An annotation on a page the document does not have is refused")
    func annotationPageValidation() async throws {
        let fixture = try await makeFixture("annot-page")
        await #expect(throws: PDFBridgeError.pageIndexOutOfRange(index: 5, pageCount: 1)) {
            _ = try await fixture.provider.writeAnnotations(
                AnnotationWriteRequest(annotations: [
                    NeutralAnnotation(pageIndex: 5, kind: .square, bounds: .zero)
                ]),
                of: fixture.handle,
                to: DocumentDestination(url: fixture.scratch.appendingPathComponent("x.pdf"))
            )
        }
    }

    @Test("An annotation kind this bridge will not write badly is refused, not fudged")
    func unsupportedAnnotationKinds() async throws {
        let fixture = try await makeFixture("annot-unsupported")
        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("u.pdf"))
        for kind in [AnnotationKind.redact, .other("Sound")] {
            await #expect(throws: PDFBridgeError.self) {
                _ = try await fixture.provider.writeAnnotations(
                    AnnotationWriteRequest(annotations: [
                        NeutralAnnotation(pageIndex: 0, kind: kind, bounds: .zero)
                    ]),
                    of: fixture.handle,
                    to: destination
                )
            }
        }
        // Ink strokes are no longer refused: PDFKit takes them as Bézier paths on macOS
        // (`NLPDFAnnotationFixTests.inkIsWritten`).
        #expect(FileManager.default.fileExists(atPath: destination.url.path) == false)
    }

    @Test("Reading annotations is bounded per page")
    func readingIsBounded() async throws {
        let fixture = try await makeFixture("annot-bounded")
        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("many.pdf"))
        let many = (0..<20).map {
            NeutralAnnotation(
                pageIndex: 0, kind: .square,
                bounds: CGRect(x: CGFloat($0), y: 0, width: 5, height: 5)
            )
        }
        _ = try await fixture.provider.writeAnnotations(
            AnnotationWriteRequest(annotations: many), of: fixture.handle, to: destination
        )

        var limits = DocumentLimits.standard
        limits.maximumAnnotationsPerPage = 3
        let reader = PDFKitDocumentProvider()
        let opened = try await reader.open(.url(destination.url), password: nil, limits: limits)
        #expect(try await reader.annotations(of: opened.handle, pageIndex: 0).count == 3)
    }

    @Test("An annotation's creation date survives a write-through (CR-93)")
    func creationDateRoundTrips() async throws {
        let fixture = try await makeFixture("annot-creationdate")
        let destination = DocumentDestination(
            url: fixture.scratch.appendingPathComponent("with-creationdate.pdf")
        )
        // Whole-second resolution, since a PDF date string carries no sub-second component.
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let square = NeutralAnnotation(
            pageIndex: 0,
            kind: .square,
            bounds: CGRect(x: 100, y: 200, width: 40, height: 40),
            creationDate: created
        )

        _ = try await fixture.provider.writeAnnotations(
            AnnotationWriteRequest(annotations: [square]),
            of: fixture.handle,
            to: destination
        )

        let reader = PDFKitDocumentProvider()
        let reopened = try await reader.open(fileAt: destination.url)
        let read = try await reader.annotations(of: reopened.handle, pageIndex: 0)
            .first { $0.kind == .square }
        let readback = try #require(read)
        // Old output: `creationDate` was nil — the mapping read `/CreationDate` but never wrote it.
        let date = try #require(readback.creationDate, "creation date was not written back")
        #expect(abs(date.timeIntervalSince(created)) < 1.0,
                "creation date was \(date), expected \(created)")
    }

    @Test("PDF date strings round-trip through the mapping's parser (CR-93)")
    func pdfDateStringParsing() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let string = AnnotationMapping.pdfDateString(from: created)
        #expect(string.hasPrefix("D:"))
        let parsed = try #require(AnnotationMapping.pdfDate(from: string))
        #expect(abs(parsed.timeIntervalSince(created)) < 1.0)
        // A timezone-offset form parses too.
        let offset = try #require(AnnotationMapping.pdfDate(from: "D:20231114221320+02'00'"))
        #expect(abs(offset.timeIntervalSince(Date(timeIntervalSince1970: 1_700_000_000 - 7200))) < 1.0)
    }
}
