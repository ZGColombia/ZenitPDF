import Foundation
import Testing
import ZPDFQPDF
import ZPDFTestingSupport

/// Extract, split and merge.
///
/// `mixedPageSizes` is the workhorse here because its four pages have four
/// different media boxes, so page *identity* can be checked through PDFKit
/// rather than just page counts. A test that only counts pages cannot tell a
/// correct reordering from a wrong one.
@Suite("Page operations")
struct PageOperationTests {

    @Test("extracting pages keeps the requested pages in the requested order")
    func extractPreservesOrder() throws {
        let box = try Sandbox("extract")
        let input = try box.fixture(.mixedPageSizes)
        let output = box.file("extracted.pdf")

        let sourceBoxes = try #require(IndependentReader.mediaBoxes(of: input))
        #expect(sourceBoxes.count == 4)
        #expect(Set(sourceBoxes.map(\.size.width)).count == 4, "the fixture's pages must differ")

        try timed("extract 3 pages in reverse order") {
            try QPDF.extractPages(input: input, output: output, pageIndices: [3, 1, 0])
        }

        let resultBoxes = try #require(IndependentReader.mediaBoxes(of: output))
        #expect(resultBoxes == [sourceBoxes[3], sourceBoxes[1], sourceBoxes[0]])
    }

    @Test("a duplicated or out-of-range page index is refused")
    func rejectsBadPageIndices() throws {
        let box = try Sandbox("badIndices")
        let input = try box.fixture(.mixedPageSizes)

        expectQPDFError("pageRangeInvalid") {
            _ = try QPDF.extractPages(
                input: input, output: box.file("dup.pdf"), pageIndices: [1, 1])
        }
        expectQPDFError("pageRangeInvalid") {
            _ = try QPDF.extractPages(
                input: input, output: box.file("high.pdf"), pageIndices: [4])
        }
        expectQPDFError("pageRangeInvalid") {
            _ = try QPDF.extractPages(
                input: input, output: box.file("low.pdf"), pageIndices: [-1])
        }
        expectQPDFError("invalidArgument") {
            _ = try QPDF.extractPages(
                input: input, output: box.file("none.pdf"), pageIndices: [])
        }
        for name in ["dup.pdf", "high.pdf", "low.pdf", "none.pdf"] {
            #expect(FileManager.default.fileExists(atPath: box.file(name).path) == false)
        }
    }

    @Test("splitting one page per file produces one file per page, in order")
    func splitsOnePagePerFile() throws {
        let box = try Sandbox("split1")
        let input = try box.fixture(.mixedPageSizes)
        let sourceBoxes = try #require(IndependentReader.mediaBoxes(of: input))

        let files = try timed("split 4 pages") {
            try QPDF.split(input: input, outputDirectory: box.url, basename: "part")
        }

        #expect(files.count == 4)
        for (index, file) in files.enumerated() {
            #expect(file.lastPathComponent == String(format: "part-%04d.pdf", index + 1))
            let boxes = try #require(IndependentReader.mediaBoxes(of: file))
            #expect(boxes == [sourceBoxes[index]])
        }
    }

    @Test("splitting in groups covers every page exactly once")
    func splitsInGroups() throws {
        let box = try Sandbox("split3")
        let input = try box.fixture(.threeHundredPages)

        let files = try timed("split 300 pages into groups of 32") {
            try QPDF.split(
                input: input, outputDirectory: box.url, basename: "group", pagesPerFile: 32)
        }

        #expect(files.count == 10)
        var total = 0
        for file in files {
            total += try #require(IndependentReader.pageCount(of: file))
        }
        #expect(total == 300)
        #expect(try #require(IndependentReader.pageCount(of: files[9])) == 300 - 9 * 32)
    }

    @Test("a split that would collide writes nothing at all")
    func splitIsAllOrNothing() throws {
        let box = try Sandbox("splitCollision")
        let input = try box.fixture(.mixedPageSizes)
        // Occupy the third of the four outputs.
        let occupied = box.file("part-0003.pdf")
        try Data("occupied".utf8).write(to: occupied)

        expectQPDFError("outputConflict") {
            _ = try QPDF.split(input: input, outputDirectory: box.url, basename: "part")
        }
        #expect(try Data(contentsOf: occupied) == Data("occupied".utf8))
        for index in [1, 2, 4] {
            let name = String(format: "part-%04d.pdf", index)
            #expect(
                FileManager.default.fileExists(atPath: box.file(name).path) == false,
                "\(name) should not have been written")
        }
    }

    @Test("merging concatenates documents in order")
    func mergeConcatenates() throws {
        let box = try Sandbox("merge")
        let first = try box.fixture(.mixedPageSizes)
        let second = try box.fixture(.rectangle)
        let output = box.file("merged.pdf")

        let firstBoxes = try #require(IndependentReader.mediaBoxes(of: first))
        let secondBoxes = try #require(IndependentReader.mediaBoxes(of: second))

        try timed("merge 2 documents") {
            try QPDF.merge(
                sources: [QPDF.Source(first), QPDF.Source(second)], output: output)
        }

        #expect(IndependentReader.mediaBoxes(of: output) == firstBoxes + secondBoxes)
        #expect(try QPDF.inspect(output).pageCount == Int64(firstBoxes.count + secondBoxes.count))
    }

    @Test("merging an encrypted source needs its password and produces a plain file")
    func mergeWithPassword() throws {
        let box = try Sandbox("mergeEncrypted")
        let plain = try box.fixture(.rectangle)
        let secret = try box.fixture(.encryptedUserPassword)
        let output = box.file("merged.pdf")

        expectQPDFError("passwordRequired") {
            _ = try QPDF.merge(
                sources: [QPDF.Source(plain), QPDF.Source(secret)],
                output: box.file("no-password.pdf"))
        }

        try QPDF.merge(
            sources: [
                QPDF.Source(plain),
                QPDF.Source(secret, password: ZPDFFixtures.encryptedUserPassword)
            ],
            output: output)

        let inventory = try QPDF.inspect(output)
        #expect(inventory.pageCount == 2)
        #expect(inventory.isEncrypted == false)
        #expect(IndependentReader.pageCount(of: output) == 2)
    }

    @Test("a merge whose result would be too large is refused")
    func mergeRespectsThePageCeiling() throws {
        let box = try Sandbox("mergeCeiling")
        let input = try box.fixture(.mixedPageSizes)
        var options = QPDFOptions.default
        options.maximumPageCount = 6

        expectQPDFError("limitExceeded") {
            _ = try QPDF.merge(
                sources: [QPDF.Source(input), QPDF.Source(input)],
                output: box.file("too-big.pdf"),
                options: options)
        }
        #expect(FileManager.default.fileExists(atPath: box.file("too-big.pdf").path) == false)
    }
}
