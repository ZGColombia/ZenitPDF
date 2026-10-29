import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZPDFContracts
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// ADR-0011: a stamp becomes a picture.
///
/// Two claims are load-bearing and are asserted here rather than described: **vector artwork
/// is compiled to geometry** — so nothing in the pipeline can resample — and **imported
/// artwork is data**, bounded by numbers this suite pushes past on purpose.
@Suite("Stamp artwork import")
struct ArtworkImportTests {

    private let importer = StampArtworkImporter()

    // MARK: - A PDF page becomes geometry

    @Test("A PDF page compiles into unit-space geometry, and nothing in it is an image")
    func pdfPageCompilesToGeometry() async throws {
        let artwork = try await importer.importArtwork(
            from: .pdfPage(url: Corpus.url(.lShape), pageIndex: 0)
        )
        #expect(artwork.geometry.kind == .vector)
        #expect(artwork.staysSharpWhenMagnified)
        #expect(artwork.sharpUntilMagnification(inBoxWidthPoints: 96) == nil)
        #expect(artwork.geometry.isEmpty == false)
        #expect(artwork.geometry.limitViolation() == nil)
        #expect(artwork.sourcePageIndex == 0)
        #expect(artwork.pixelWidth == nil)
        #expect(artwork.digest.count == 64)

        // Every region carries no colour of its own: an extracted PDF page records paint role
        // and stroke width, not ink, so the artwork takes the stamp's style colour. ADR-0011
        // §2.4 states this as a limit; this is the assertion that it is the actual behaviour.
        #expect(artwork.geometry.regions.allSatisfy { $0.color == nil })
    }

    @Test("The compiled artwork fills its unit box exactly, in both axes")
    func compiledArtworkIsNormalized() async throws {
        let artwork = try await importer.importArtwork(
            from: .pdfPage(url: Corpus.url(.polygonOneHole), pageIndex: 0)
        )
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        func note(_ points: [PDFPoint]) {
            for point in points {
                minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
                minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
            }
        }
        for stroke in artwork.geometry.strokes { note(stroke.points) }
        for region in artwork.geometry.regions { note(region.outer) }

        #expect(abs(minX) < 1e-9)
        #expect(abs(minY) < 1e-9)
        #expect(abs(maxX - 1) < 1e-9)
        #expect(abs(maxY - 1) < 1e-9)
        #expect(artwork.geometry.sourceAspectRatio > 0)
        #expect(artwork.geometry.isWellFormed)
    }

    @Test("A curve survives as many points, not as one straight line")
    func curvesAreFlattenedNotDropped() async throws {
        let artwork = try await importer.importArtwork(
            from: .pdfPage(url: Corpus.url(.bezierCircle), pageIndex: 0)
        )
        #expect(artwork.geometry.primitiveCount > 0)
        // A circle reduced to its four on-curve points would be a diamond. The compiled form
        // has to carry enough vertices that it is round.
        #expect(artwork.geometry.pointCount >= 16)
    }

    @Test("Compiling the same page twice gives the same bytes, so a digest can address a picture")
    func compilationIsDeterministic() async throws {
        let first = try await importer.importArtwork(
            from: .pdfPage(url: Corpus.url(.rectangle), pageIndex: 0)
        )
        let second = try await StampArtworkImporter().importArtwork(
            from: .pdfPage(url: Corpus.url(.rectangle), pageIndex: 0)
        )
        #expect(first.geometry == second.geometry)
        #expect(first.digest == second.digest)
    }

    // MARK: - An image is accepted, marked, and bounded

    @Test("An image compiles to a mosaic, is marked raster, and says when it stops being sharp")
    func imageIsAcceptedAndMarked() async throws {
        let url = try ArtworkFixtures.checkerboardPNG(edge: 32, label: "checker")
        let artwork = try await importer.importArtwork(from: .image(url: url))

        #expect(artwork.geometry.kind == .raster)
        #expect(artwork.staysSharpWhenMagnified == false)
        #expect(artwork.pixelWidth == 32)
        #expect(artwork.pixelHeight == 32)
        // 32 pixels across a 16-point box is sharp to 200 % and no further. This is the number
        // the preset editor's warning shows, and it is derived from the artwork, not typed in.
        let magnification = try #require(artwork.sharpUntilMagnification(inBoxWidthPoints: 16))
        #expect(abs(magnification - 2.0) < 1e-9)
        #expect(artwork.geometry.strokes.isEmpty)
        #expect(artwork.geometry.regions.isEmpty == false)
        #expect(artwork.geometry.limitViolation() == nil)
        #expect(artwork.geometry.regions.allSatisfy { $0.color != nil })
    }

    @Test("The mosaic keeps its orientation: what was at the top of the image is at the top")
    func rasterMosaicKeepsItsOrientation() async throws {
        // A CGBitmapContext's memory row 0 is the top of the picture and PDF unit space has
        // its origin at the bottom. Getting that backwards flips every imported stamp, and a
        // flipped seal is the kind of defect that ships because nobody looked at the second
        // one. This is the assertion, not the comment.
        let url = try ArtworkFixtures.halvesPNG(
            top: (255, 0, 0), bottom: (0, 0, 255), edge: 16, label: "halves"
        )
        let artwork = try await importer.importArtwork(from: .image(url: url))

        func dominantColor(above: Bool) throws -> RGBAColor {
            let regions = artwork.geometry.regions.filter { region in
                let midY = region.outer.reduce(0.0) { $0 + $1.y } / Double(region.outer.count)
                return above ? midY > 0.6 : midY < 0.4
            }
            let color = try #require(regions.first?.color)
            #expect(regions.allSatisfy { $0.color == color })
            return color
        }

        let top = try dominantColor(above: true)
        #expect(top.red > 0.9 && top.green < 0.1 && top.blue < 0.1)
        let bottom = try dominantColor(above: false)
        #expect(bottom.blue > 0.9 && bottom.red < 0.1 && bottom.green < 0.1)
    }

    @Test("Run merging keeps a flat image cheap: one row of one colour is one primitive")
    func flatRowsMergeIntoRuns() async throws {
        let url = try ArtworkFixtures.halvesPNG(
            top: (12, 200, 90), bottom: (12, 200, 90), edge: 64, label: "flat"
        )
        let artwork = try await importer.importArtwork(from: .image(url: url))
        // 64 x 64 cells is 4 096 of them; merged into rows it is at most 64 primitives. The
        // point of the bound is that a stamp's cost is a property of the mosaic and not of
        // the file that was imported.
        #expect(artwork.geometry.primitiveCount <= 64)
        #expect(artwork.geometry.primitiveCount >= 1)
    }

    @Test("A raster's cost is bounded by the mosaic, not by the imported file's pixel count")
    func mosaicCostIsBounded() async throws {
        let small = try await importer.importArtwork(
            from: .image(url: ArtworkFixtures.checkerboardPNG(edge: 32, label: "small"))
        )
        let large = try await importer.importArtwork(
            from: .image(url: ArtworkFixtures.checkerboardPNG(edge: 512, label: "large"))
        )
        let ceiling = ArtworkLimits.maximumRasterSampleEdge * ArtworkLimits.maximumRasterSampleEdge
        #expect(small.geometry.primitiveCount <= ceiling)
        #expect(large.geometry.primitiveCount <= ceiling)
        #expect(large.pixelWidth == 512)
    }

    // MARK: - Imported artwork is data: the refusals

    @Test("A hostile page that draws 60 000 rectangles is refused, by number")
    func aContourBombIsRefused() async throws {
        // Hand-written rather than produced by our own well-behaved PDF writer, because a
        // fixture generated by the code under test is not adversarial input.
        let url = try ArtworkFixtures.contourBombPDF(rectangleCount: 60_000, label: "bomb")
        await #expect(throws: ArtworkImportRefusal.self) {
            _ = try await importer.importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        }
        do {
            _ = try await importer.importArtwork(from: .pdfPage(url: url, pageIndex: 0))
            Issue.record("the contour bomb was accepted")
        } catch let refusal as ArtworkImportRefusal {
            guard case let .tooManyContours(found, limit) = refusal else {
                Issue.record("expected a contour refusal, got \(refusal)")
                return
            }
            #expect(limit == ArtworkLimits.maximumContours)
            #expect(found >= 0)
            #expect(refusal.reason.contains("\(ArtworkLimits.maximumContours)"))
        }
    }

    @Test("A valid 900-megapixel PNG that fits in 110 KB is refused before it is decoded")
    func aDecodeBombIsRefusedBeforeDecoding() async throws {
        // Nothing about this file is malformed: a 30 000 x 30 000 one-bit raster of zeros,
        // fully valid, about a hundred kilobytes on disk, and several gigabytes decoded. The
        // refusal has to come from the declared size — a size measured after the decode is a
        // size measured after the damage.
        let url = try ArtworkFixtures.hugeValidPNG(width: 30_000, height: 30_000, label: "bomb")
        #expect(try Data(contentsOf: url).count < 1_000_000)
        do {
            _ = try await importer.importArtwork(from: .image(url: url))
            Issue.record("the declared decode bomb was accepted")
        } catch let refusal as ArtworkImportRefusal {
            guard case let .rasterTooLarge(pixels, limit) = refusal else {
                Issue.record("expected a raster-size refusal, got \(refusal)")
                return
            }
            #expect(pixels == 900_000_000)
            #expect(limit == ArtworkLimits.maximumRasterPixels)
        }
    }

    @Test("An image whose header lies about its size is refused, not decoded anyway")
    func aLyingHeaderIsRefused() async throws {
        // A four-pixel PNG whose IHDR was rewritten to claim 30 000 x 30 000, with the chunk
        // CRC recomputed so it is not merely corrupt. Header and payload disagree; the import
        // ends in a named refusal rather than in whatever the decoder felt like producing.
        let url = try ArtworkFixtures.declaredDecodeBombPNG(
            width: 30_000, height: 30_000, label: "liar"
        )
        do {
            _ = try await importer.importArtwork(from: .image(url: url))
            Issue.record("a PNG whose header contradicts its payload was accepted")
        } catch let refusal as ArtworkImportRefusal {
            #expect(refusal == .unreadableSource || refusal == .rasterTooLarge(
                pixels: 900_000_000, limit: ArtworkLimits.maximumRasterPixels
            ))
        }
    }

    @Test("A file larger than the limit is refused without being read")
    func anOversizedSourceIsRefused() throws {
        let url = try ArtworkFixtures.sparseFile(
            byteCount: ArtworkLimits.maximumSourceBytes + 1, label: "oversize"
        )
        #expect(throws: ArtworkImportRefusal.sourceTooLarge(
            bytes: ArtworkLimits.maximumSourceBytes + 1,
            limit: ArtworkLimits.maximumSourceBytes
        )) {
            _ = try StampArtworkImporter.readBoundedSource(at: url)
        }
    }

    @Test("An encrypted PDF is refused rather than prompted for")
    func anEncryptedPDFIsRefused() async throws {
        do {
            _ = try await importer.importArtwork(
                from: .pdfPage(url: Corpus.url(.encryptedUserPassword), pageIndex: 0)
            )
            Issue.record("an encrypted file was imported")
        } catch let refusal as ArtworkImportRefusal {
            #expect(refusal == .encryptedSource || refusal == .unreadableSource)
        }
    }

    @Test("A page that does not exist is refused with the page count in the sentence")
    func aPageOutOfRangeIsRefused() async throws {
        do {
            _ = try await importer.importArtwork(
                from: .pdfPage(url: Corpus.url(.rectangle), pageIndex: 99)
            )
            Issue.record("page 100 of a one-page file was imported")
        } catch let refusal as ArtworkImportRefusal {
            guard case let .pageOutOfRange(requested, pageCount) = refusal else {
                Issue.record("expected a page refusal, got \(refusal)")
                return
            }
            #expect(requested == 99)
            #expect(pageCount >= 1)
            #expect(refusal.reason.contains("100"))
        }
    }

    @Test("A file that is not a PDF and not an image is refused, not guessed at")
    func garbageIsRefused() async throws {
        let url = try ArtworkFixtures.write(
            Data("this is not a PDF and not an image".utf8), name: "garbage.bin"
        )
        await #expect(throws: ArtworkImportRefusal.self) {
            _ = try await importer.importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        }
        await #expect(throws: ArtworkImportRefusal.self) {
            _ = try await importer.importArtwork(from: .image(url: url))
        }
    }

    @Test("Deeply nested drawing forms terminate rather than recursing")
    func deeplyNestedFormsTerminate() async throws {
        // The outcome that matters is that the call returns at all, with either artwork or a
        // named refusal — never a hang and never a crash.
        do {
            let artwork = try await importer.importArtwork(
                from: .pdfPage(url: Corpus.url(.deeplyNestedForms), pageIndex: 0)
            )
            #expect(artwork.geometry.limitViolation() == nil)
        } catch let refusal as ArtworkImportRefusal {
            #expect(!refusal.reason.isEmpty)
        }
    }

    @Test("Nothing in an imported file is executed")
    func nothingIsExecuted() async throws {
        // The JavaScript fixture carries a document-level action. Importing artwork from it
        // reads path operators and nothing else; the package's security policy states the
        // guarantee and this is the import path standing behind it.
        let policy = PDFBridgeSecurityPolicy.current
        #expect(policy.executesDocumentJavaScript == false)
        #expect(policy.followsLaunchActions == false)
        #expect(policy.performsOpenAction == false)
        #expect(policy.resolvesExternalReferences == false)

        for kind in [FixtureKind.javaScriptAction, .embeddedFileWithLaunchAction] {
            do {
                let artwork = try await importer.importArtwork(
                    from: .pdfPage(url: Corpus.url(kind), pageIndex: 0)
                )
                // Whatever came back is geometry in a unit box and nothing else.
                #expect(artwork.geometry.isWellFormed)
                #expect(artwork.geometry.limitViolation() == nil)
            } catch let refusal as ArtworkImportRefusal {
                #expect(!refusal.reason.isEmpty)
            }
        }
    }

    @Test("A truncated or structurally broken file is refused, not half-imported")
    func brokenFilesAreRefused() async throws {
        for kind in [FixtureKind.truncatedFile, .brokenXref, .missingObject] {
            do {
                let artwork = try await importer.importArtwork(
                    from: .pdfPage(url: Corpus.url(kind), pageIndex: 0)
                )
                // If a broken file is readable enough to yield artwork, the artwork still has
                // to be whole and inside its bounds.
                #expect(artwork.geometry.isWellFormed)
                #expect(artwork.geometry.limitViolation() == nil)
            } catch let refusal as ArtworkImportRefusal {
                #expect(!refusal.reason.isEmpty)
            }
        }
    }

    // MARK: - CR-72: the digest addresses a page, not just a file

    @Test("Two pages of one PDF get different digests, so neither is dropped on INSERT OR IGNORE")
    func twoPagesOfOnePDFGetDifferentDigests() async throws {
        // Old behaviour: the digest was `SHA-256(file bytes)` regardless of the page, so page 0
        // and page 1 of one PDF produced the SAME digest and the store's `INSERT OR IGNORE` on
        // the digest dropped the second — every sheet then drew page 0's picture.
        let url = Corpus.url(.mixedPageSizes)
        let page0 = try await importer.importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        let page1 = try await importer.importArtwork(from: .pdfPage(url: url, pageIndex: 1))
        #expect(page0.digest != page1.digest, "two pages of one PDF collided on one digest")
        #expect(page0.digest.count == 64)
        #expect(page1.digest.count == 64)

        // The same page of the same file still addresses the same picture.
        let page0Again = try await importer.importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        #expect(page0.digest == page0Again.digest)
    }

    // MARK: - CR-78: premultiplied samples are un-premultiplied

    @Test("A 50%-alpha sample is read as its straight colour, not a premultiplied quarter")
    func premultipliedSamplesAreUnpremultiplied() throws {
        // CoreGraphics stores the mosaic sample buffer premultiplied-last: a straight red at 50%
        // alpha is stored (128, 0, 0, 128). Reading it straight renders red ≈ 0.5 — a dark halo
        // on every antialiased seal edge. Old output: red ≈ 0.518.
        let samples: [UInt8] = [128, 0, 0, 128]
        let regions = StampArtworkImporter.mosaic(samples: samples, columns: 1, rows: 1)
        let color = try #require(regions.first?.color)
        #expect(color.red > 0.9, "premultiplied red was \(color.red), not un-premultiplied to ~1.0")
        #expect(color.green < 0.1)
        #expect(color.blue < 0.1)
        #expect(abs(color.alpha - 0.5) < 0.06, "alpha was \(color.alpha)")
    }

    @Test("A fully opaque sample is unchanged by un-premultiplication")
    func opaqueSamplesAreUnchanged() throws {
        let samples: [UInt8] = [64, 128, 200, 255]
        let regions = StampArtworkImporter.mosaic(samples: samples, columns: 1, rows: 1)
        let color = try #require(regions.first?.color)
        #expect(abs(color.red - 64.0 / 255.0) < 0.05)
        #expect(abs(color.green - 128.0 / 255.0) < 0.05)
        #expect(abs(color.blue - 200.0 / 255.0) < 0.05)
        #expect(color.alpha > 0.95)
    }
}

