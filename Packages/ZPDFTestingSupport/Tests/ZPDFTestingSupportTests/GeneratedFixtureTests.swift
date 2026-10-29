import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport

/// Generates each fixture, re-opens it with CoreGraphics, and checks that what came
/// back is what the manifest promised.
struct GeneratedFixtureTests {

    /// One directory per test run, shared by every test in this suite through the
    /// filesystem cache in `ZPDFFixtures.make(_:in:)`.
    static let corpusDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZPDFTestingSupportCorpus", isDirectory: true)

    /// Boxes agree to within a hundredth of a point; CoreGraphics returns `CGFloat`,
    /// which is `Double` on every platform Zenit supports, so this is generous.
    static let boxTolerance = 1e-9

    // MARK: - Structurally valid fixtures

    static let validKinds: [FixtureKind] = FixtureKind.allCases.filter(\.isStructurallyValid)

    @Test("Every valid fixture opens and reports the manifest's page count",
          arguments: validKinds)
    func opensWithExpectedPageCount(kind: FixtureKind) throws {
        let handle = try ZPDFFixtures.make(kind, in: Self.corpusDirectory)
        #expect(FileManager.default.fileExists(atPath: handle.url.path))
        #expect(handle.byteCount > 0)

        let document = try openDocument(handle)
        #expect(
            document.numberOfPages == handle.manifest.pageCount,
            "\(kind.rawValue): CGPDFDocument reports \(document.numberOfPages) pages, manifest says \(handle.manifest.pageCount)"
        )
    }

    @Test("Every valid fixture's page boxes and rotation match the manifest",
          arguments: validKinds)
    func pageGeometryMatchesManifest(kind: FixtureKind) throws {
        let handle = try ZPDFFixtures.make(kind, in: Self.corpusDirectory)
        let document = try openDocument(handle)

        for expected in handle.manifest.pages {
            // CGPDFDocument page numbers are 1-based.
            let page = try #require(
                document.page(at: expected.index + 1),
                "\(kind.rawValue): page \(expected.index + 1) missing"
            )

            let media = page.getBoxRect(.mediaBox)
            expectBox(media, equals: expected.mediaBox, label: "\(kind.rawValue) p\(expected.index) media")

            let crop = page.getBoxRect(.cropBox)
            expectBox(crop, equals: expected.cropBox, label: "\(kind.rawValue) p\(expected.index) crop")

            #expect(
                page.rotationAngle == Int32(expected.rotation),
                "\(kind.rawValue) p\(expected.index): rotation \(page.rotationAngle), expected \(expected.rotation)"
            )
        }
    }

    @Test("Rotation fixtures carry exactly the rotation their name claims",
          arguments: [
            (FixtureKind.rotation0, 0),
            (FixtureKind.rotation90, 90),
            (FixtureKind.rotation180, 180),
            (FixtureKind.rotation270, 270)
          ])
    func rotationIsWrittenToTheFile(entry: (kind: FixtureKind, degrees: Int)) throws {
        let handle = try ZPDFFixtures.make(entry.kind, in: Self.corpusDirectory)
        let document = try openDocument(handle)
        let page = try #require(document.page(at: 1))
        #expect(page.rotationAngle == Int32(entry.degrees))
        #expect(handle.manifest.pages[0].rotation == entry.degrees)
    }

    @Test("Crop box fixtures really differ from their media box")
    func cropBoxesDifferFromMediaBoxes() throws {
        for kind in [FixtureKind.cropBoxSmallerThanMediaBox, .cropBoxNegativeOrigin] {
            let handle = try ZPDFFixtures.make(kind, in: Self.corpusDirectory)
            let page = handle.manifest.pages[0]
            #expect(page.declaresCropBox)
            #expect(page.cropBox != page.mediaBox)

            let document = try openDocument(handle)
            let cgPage = try #require(document.page(at: 1))
            expectBox(cgPage.getBoxRect(.cropBox), equals: page.cropBox, label: "\(kind.rawValue) crop")
            expectBox(cgPage.getBoxRect(.mediaBox), equals: page.mediaBox, label: "\(kind.rawValue) media")
        }
    }

    @Test("The negative-origin fixture really has a negative lower-left corner")
    func negativeOriginIsNegative() throws {
        let handle = try ZPDFFixtures.make(.cropBoxNegativeOrigin, in: Self.corpusDirectory)
        let page = handle.manifest.pages[0]
        #expect(page.mediaBox.llx < 0)
        #expect(page.mediaBox.lly < 0)
        #expect(page.cropBox.llx < 0)
        #expect(page.cropBox.lly < 0)
        #expect(page.mediaBox.width == 612)
        #expect(page.mediaBox.height == 792)
    }

    @Test("Mixed-page-size fixture has four different page sizes")
    func mixedPageSizesAreDifferent() throws {
        let handle = try ZPDFFixtures.make(.mixedPageSizes, in: Self.corpusDirectory)
        let document = try openDocument(handle)
        #expect(document.numberOfPages == 4)

        var seen: [String] = []
        for index in 1...4 {
            let page = try #require(document.page(at: index))
            let box = page.getBoxRect(.mediaBox)
            seen.append("\(box.width)x\(box.height)")
        }
        #expect(Set(seen).count == 4, "expected four distinct page sizes, saw \(seen)")
    }

    @Test("Sheet-size fixtures match their nominal dimensions")
    func sheetSizesAreCorrect() throws {
        let a1 = try ZPDFFixtures.make(.sizeA1, in: Self.corpusDirectory)
        let a1Page = try #require(try openDocument(a1).page(at: 1))
        let a1Box = a1Page.getBoxRect(.mediaBox)
        // 594 mm and 841 mm at exactly 72/25.4 points per mm.
        #expect(abs(Double(a1Box.width) - 594 * 72 / 25.4) <= 1e-6)
        #expect(abs(Double(a1Box.height) - 841 * 72 / 25.4) <= 1e-6)

        let arch = try ZPDFFixtures.make(.sizeArchD, in: Self.corpusDirectory)
        let archPage = try #require(try openDocument(arch).page(at: 1))
        let archBox = archPage.getBoxRect(.mediaBox)
        #expect(Double(archBox.width) == 1728)
        #expect(Double(archBox.height) == 2592)
    }

    @Test("The large-page-count fixtures really contain 300 and 1 000 pages")
    func largePageCounts() throws {
        for (kind, count) in [(FixtureKind.threeHundredPages, 300), (.oneThousandPages, 1_000)] {
            let handle = try ZPDFFixtures.make(kind, in: Self.corpusDirectory)
            let document = try openDocument(handle)
            #expect(document.numberOfPages == count)
            #expect(handle.manifest.pageCount == count)
            #expect(handle.manifest.pages.count == count)

            // Spot-check the first, a middle and the last page.
            for index in [1, count / 2, count] {
                let page = try #require(document.page(at: index))
                let box = page.getBoxRect(.mediaBox)
                #expect(Double(box.width) == 612)
                #expect(Double(box.height) == 792)
            }
        }
    }

    @Test("Fixture bytes are deterministic", arguments: FixtureKind.allCases)
    func generationIsDeterministic(kind: FixtureKind) throws {
        // The encrypted fixture is written by CoreGraphics, whose encryption dictionary
        // embeds fresh random material; every other fixture is byte-stable.
        guard kind != .encryptedUserPassword else { return }
        let first = try ZPDFFixtures.data(kind)
        let second = try ZPDFFixtures.data(kind)
        #expect(first.data == second.data, "\(kind.rawValue) is not byte-deterministic")
    }

    @Test("In-memory bytes equal the bytes written to disk", arguments: validKinds)
    func inMemoryMatchesOnDisk(kind: FixtureKind) throws {
        guard kind != .encryptedUserPassword else { return }
        let handle = try ZPDFFixtures.make(kind, in: Self.corpusDirectory)
        let inMemory = try ZPDFFixtures.data(kind)
        let onDisk = try Data(contentsOf: handle.url)
        #expect(inMemory.data == onDisk, "\(kind.rawValue): data(_:) and make(_:in:) disagree")
        #expect(handle.byteCount == onDisk.count)
    }

    // MARK: - Helpers

    private func openDocument(_ handle: FixtureHandle) throws -> CGPDFDocument {
        let document = try #require(
            CGPDFDocument(handle.url as CFURL),
            "\(handle.kind.rawValue): CGPDFDocument could not open \(handle.url.lastPathComponent)"
        )
        if let password = handle.manifest.userPassword, !document.isUnlocked {
            #expect(
                document.unlockWithPassword(password),
                "\(handle.kind.rawValue): the recorded user password did not unlock the document"
            )
        }
        return document
    }

    private func expectBox(_ actual: CGRect, equals expected: FixtureRect, label: String) {
        #expect(abs(Double(actual.minX) - expected.llx) <= Self.boxTolerance, "\(label) llx: \(actual.minX)")
        #expect(abs(Double(actual.minY) - expected.lly) <= Self.boxTolerance, "\(label) lly: \(actual.minY)")
        #expect(abs(Double(actual.maxX) - expected.urx) <= Self.boxTolerance, "\(label) urx: \(actual.maxX)")
        #expect(abs(Double(actual.maxY) - expected.ury) <= Self.boxTolerance, "\(label) ury: \(actual.maxY)")
    }
}
