import Foundation
import Testing
@testable import ZPDFQPDF
import ZPDFTestingSupport

/// CR-129 and CR-143: what a split leaves behind, and what it says, when it does not finish.
@Suite("Split failure")
struct SplitFailureTests {

    /// CR-129. Each group is written to `<output>.zpdf-partial` and renamed into place. Until
    /// now a group that failed after earlier groups had been promoted left those files on
    /// disk, and the thrown error carried nothing about them. The failure here is real, not
    /// injected: the shim refuses to reuse a partial file that already exists — a leftover
    /// from an earlier crashed run — and that refusal lands on the third of four groups.
    /// Cancellation takes the identical path: it is a C++ exception at a group boundary or a
    /// writer progress tick, caught by the same handler that removes the promoted files.
    // Fails on the old code with 3 issues (the count assertion was first run in the stringly
    // form `String(describing: error).contains("filesWritten: 2")`, because the typed case
    // below did not exist yet):
    //   SplitFailureTests.swift:42:13: Expectation failed: !((FileManager.default →
    //     <NSFileManager: 0x101013570>).fileExists(atPath: box.file(name).path →
    //     "/var/folders/…/zpdf-qpdf-splitMidFailure-…/part-0001.pdf") → true)
    //   ↳ part-0001.pdf survived a failed split
    //   SplitFailureTests.swift:42:13: Expectation failed: !((… "…/part-0002.pdf") → true)
    //   ↳ part-0002.pdf survived a failed split
    //   SplitFailureTests.swift:49:9: Expectation failed: (String(describing: error) →
    //     "damaged("temporary output already exists: /private/var/folders/…/part-0003.pdf.zpdf-partial")")
    //     .contains("filesWritten: 2")
    //   ↳ the error must carry the count; got .damaged("temporary output already exists: …")
    @Test("a split that fails after promoting files removes them and reports how many it wrote")
    func failedSplitLeavesNothingBehind() throws {
        let box = try Sandbox("splitMidFailure")
        let input = try box.fixture(.mixedPageSizes)   // four pages, one file each
        let leftover = box.file("part-0003.pdf.zpdf-partial")
        try Data("leftover".utf8).write(to: leftover)

        var thrown: QPDFError?
        do {
            _ = try QPDF.split(input: input, outputDirectory: box.url, basename: "part")
            Issue.record("the split must fail on the third group")
        } catch let error as QPDFError {
            thrown = error
        }
        let error = try #require(thrown)

        // (1) No promoted file survives the failure.
        for index in 1...4 {
            let name = String(format: "part-%04d.pdf", index)
            #expect(!FileManager.default.fileExists(atPath: box.file(name).path),
                    "\(name) survived a failed split")
        }
        // The leftover that caused the failure was not ours and is untouched.
        #expect(try Data(contentsOf: leftover) == Data("leftover".utf8))

        // (2) The error reports how far the split got, and that nothing was left behind.
        guard case .splitIncomplete(let underlying, let filesWritten, let survivingFiles) = error else {
            Issue.record("expected splitIncomplete, got \(error)")
            return
        }
        #expect(filesWritten == 2)
        #expect(survivingFiles.isEmpty, "the shim removed nothing: \(survivingFiles)")
        #expect(underlying.tag == "damaged", "the underlying failure is kept: \(underlying)")
        guard case .damaged(let message) = underlying else { return }
        #expect(message.contains("part-0003.pdf.zpdf-partial"))
    }

    /// A failure before the first file is written stays the plain error: there is no count
    /// to carry, and callers matching `.outputConflict` or `.cancelled` keep working.
    @Test("a split that fails before its first file throws the failure itself")
    func earlyFailureIsNotWrapped() throws {
        let box = try Sandbox("splitEarlyFailure")
        let input = try box.fixture(.mixedPageSizes)
        try Data("occupied".utf8).write(to: box.file("part-0004.pdf"))

        expectQPDFError("outputConflict") {
            _ = try QPDF.split(input: input, outputDirectory: box.url, basename: "part")
        }
        for index in 1...3 {
            #expect(!FileManager.default.fileExists(atPath: box.file(String(format: "part-%04d.pdf", index)).path))
        }
    }

    /// CR-143. The C out-parameter `out_file_count` is trusted by the Swift side; a negative
    /// value used to trap in `prefix(_:)` instead of surfacing as a typed error.
    // Fails on the old code by crashing the test process, not by a failed assertion:
    //   Swift/Collection.swift:1329: Fatal error: Can't take a prefix of negative length from
    //   a collection
    //   error: Process '…/swiftpm-testing-helper --test-bundle-path …/QPDFBridgePackageTests
    //   --filter negativeFileCountIsTyped … --testing-library swift-testing' exited with
    //   unexpected signal code 5
    @Test("a negative file count from the shim is a typed error, not a trap")
    func negativeFileCountIsTyped() throws {
        let directory = URL(fileURLWithPath: "/tmp/zpdf-split", isDirectory: true)
        expectQPDFError("internalFailure") {
            _ = try QPDF.splitOutputURLs(outputDirectory: directory, basename: "part", fileCount: -1)
        }
        expectQPDFError("internalFailure") {
            _ = try QPDF.splitOutputURLs(outputDirectory: directory, basename: "part", fileCount: .min)
        }
        // The non-negative path is unchanged: n files, numbered from 0001.
        let none = try QPDF.splitOutputURLs(outputDirectory: directory, basename: "part", fileCount: 0)
        #expect(none.isEmpty)
        let three = try QPDF.splitOutputURLs(outputDirectory: directory, basename: "part", fileCount: 3)
        #expect(three.map(\.lastPathComponent) == ["part-0001.pdf", "part-0002.pdf", "part-0003.pdf"])
    }
}
