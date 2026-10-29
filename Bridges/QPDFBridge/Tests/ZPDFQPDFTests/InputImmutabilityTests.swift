import Foundation
import Testing
import ZPDFQPDF
import ZPDFTestingSupport

/// The central safety property of this bridge: the input file is never touched.
///
/// A malformed PDF is opened read-only or repaired into a copy, and an original is
/// never repaired in place, so this is asserted here by hashing, not assumed from the
/// code's shape.
@Suite("Input immutability")
struct InputImmutabilityTests {

    @Test("every operation leaves the input's bytes and timestamps untouched")
    func inputHashSurvivesEveryOperation() throws {
        let box = try Sandbox("immutability")
        let valid = try box.fixture(.mixedPageSizes)
        let damaged = try box.fixture(.brokenXref)
        let encrypted = try box.fixture(.encryptedUserPassword)
        let password = ZPDFFixtures.encryptedUserPassword

        let watched = [valid, damaged, encrypted]
        let hashesBefore = try watched.map { try Hashing.sha256(of: $0) }
        let datesBefore = try watched.map { try modificationDate(of: $0) }

        _ = try QPDF.inspect(valid)
        _ = try QPDF.inspect(damaged)
        _ = try QPDF.inspect(encrypted, password: password)
        try QPDF.repair(input: damaged, output: box.file("a.pdf"))
        try QPDF.linearize(input: valid, output: box.file("b.pdf"))
        try QPDF.decrypt(input: encrypted, output: box.file("c.pdf"), password: password)
        try QPDF.extractPages(input: valid, output: box.file("e.pdf"), pageIndices: [0, 2])
        _ = try QPDF.split(
            input: valid, outputDirectory: box.url, basename: "split", pagesPerFile: 2)
        try QPDF.merge(
            sources: [QPDF.Source(valid), QPDF.Source(encrypted, password: password)],
            output: box.file("f.pdf"))

        // And a batch of failures, which is where a careless implementation
        // would truncate or clobber something.
        expectQPDFError("passwordIncorrect") {
            _ = try QPDF.decrypt(input: encrypted, output: box.file("g.pdf"), password: "no")
        }
        expectQPDFError("pageRangeInvalid") {
            _ = try QPDF.extractPages(input: valid, output: box.file("h.pdf"), pageIndices: [99])
        }

        let hashesAfter = try watched.map { try Hashing.sha256(of: $0) }
        let datesAfter = try watched.map { try modificationDate(of: $0) }
        #expect(hashesBefore == hashesAfter, "an input's bytes changed")
        #expect(datesBefore == datesAfter, "an input's modification date changed")
    }

    @Test("writing an output over its own input is refused")
    func refusesToWriteOverTheInput() throws {
        let box = try Sandbox("selfOverwrite")
        let input = try box.fixture(.rectangle)
        let hashBefore = try Hashing.sha256(of: input)

        expectQPDFError("outputConflict") {
            _ = try QPDF.repair(input: input, output: input)
        }
        // The same file reached through a redundant path component.
        let indirect = box.url
            .appendingPathComponent(".")
            .appendingPathComponent(input.lastPathComponent)
        expectQPDFError("outputConflict") {
            _ = try QPDF.repair(input: input, output: indirect)
        }
        expectQPDFError("outputConflict") {
            _ = try QPDF.merge(sources: [QPDF.Source(input)], output: input)
        }

        #expect(try Hashing.sha256(of: input) == hashBefore)
    }

    @Test("an existing output file is never overwritten")
    func refusesToOverwriteAnExistingFile() throws {
        let box = try Sandbox("existingOutput")
        let input = try box.fixture(.rectangle)
        let output = box.file("occupied.pdf")
        let sentinel = Data("not a PDF, and it must survive".utf8)
        try sentinel.write(to: output)

        expectQPDFError("outputConflict") {
            _ = try QPDF.repair(input: input, output: output)
        }
        #expect(try Data(contentsOf: output) == sentinel)
    }

    @Test("a cancelled operation writes nothing")
    func cancellationLeavesNoOutput() async throws {
        let box = try Sandbox("cancellation")
        let input = try box.fixture(.threeHundredPages)
        let output = box.file("cancelled.pdf")

        // The gate removes the race: the task cannot reach qpdf until after
        // `cancel()` has run, so `Task.isCancelled` is already true when the
        // shim asks.
        let gate = Gate()
        let task = Task { () -> QPDFError? in
            await gate.wait()
            do {
                try QPDF.linearize(input: input, output: output)
                return nil
            } catch let error as QPDFError {
                return error
            } catch {
                return nil
            }
        }
        task.cancel()
        await gate.open()

        #expect(await task.value == .cancelled)
        #expect(FileManager.default.fileExists(atPath: output.path) == false)
        #expect(FileManager.default.fileExists(atPath: output.path + ".zpdf-partial") == false)
    }

    @Test("an oversized input is refused before it is parsed")
    func refusesOversizedInput() throws {
        let box = try Sandbox("oversize")
        let input = try box.fixture(.rectangle)
        var options = QPDFOptions.default
        options.maximumInputBytes = 16

        expectQPDFError("limitExceeded") {
            _ = try QPDF.inspect(input, options: options)
        }
    }

    @Test("a document with too many pages is refused")
    func refusesTooManyPages() throws {
        let box = try Sandbox("pageCeiling")
        let input = try box.fixture(.threeHundredPages)
        var options = QPDFOptions.default
        options.maximumPageCount = 10

        expectQPDFError("limitExceeded") {
            _ = try QPDF.inspect(input, options: options)
        }
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.modificationDate] as? Date) ?? .distantPast
    }
}
