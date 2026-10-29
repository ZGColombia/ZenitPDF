import Foundation
import Testing
import ZPDFQPDF
import ZPDFTestingSupport

/// Repair, linearization and inspection against the hostile corpus.
///
/// "Openable" is decided by PDFKit, which sits on CoreGraphics' PDF parser and
/// shares no code with qpdf, so a passing test is evidence rather than qpdf
/// agreeing with itself.
@Suite("Repair")
struct RepairTests {

    @Test("a truncated file is repaired into a file CoreGraphics can open")
    func truncatedFileIsRepaired() throws {
        let box = try Sandbox("truncated")
        let input = try box.fixture(.truncatedFile)
        let output = box.file("repaired.pdf")

        // The premise: CoreGraphics cannot open the damaged original.
        #expect(IndependentReader.opens(input) == false)

        let before = try QPDF.inspect(input)
        #expect(before.damage.crossReferenceWasReconstructed)
        #expect(before.damage.needsRepair)

        let report = try timed("repair truncated") {
            try QPDF.repair(input: input, output: output)
        }
        #expect(report.warningCount > 0, "qpdf should say what it had to reconstruct")

        #expect(IndependentReader.pageCount(of: output) == 2)

        // And the repaired file is clean when re-read: the repair is not just a
        // copy of the damage.
        let after = try QPDF.inspect(output)
        #expect(after.damage.crossReferenceWasReconstructed == false)
        #expect(after.damage.needsRepair == false)
        #expect(after.report.warningCount == 0)
        #expect(after.pageCount == 2)
    }

    @Test("a file with a broken cross-reference table is repaired into an openable file")
    func brokenXrefIsRepaired() throws {
        let box = try Sandbox("brokenXref")
        let input = try box.fixture(.brokenXref)
        let output = box.file("repaired.pdf")

        #expect(IndependentReader.opens(input) == false)

        let before = try QPDF.inspect(input)
        #expect(before.damage.crossReferenceWasReconstructed)

        try timed("repair broken xref") { try QPDF.repair(input: input, output: output) }

        #expect(IndependentReader.pageCount(of: output) == 1)
        let after = try QPDF.inspect(output)
        #expect(after.damage.needsRepair == false)
        #expect(after.report.warningCount == 0)
    }

    @Test("repairing an already-valid file changes nothing that matters")
    func repairOfValidFileIsANoOp() throws {
        let box = try Sandbox("validRepair")
        let input = try box.fixture(.mixedPageSizes)
        let output = box.file("repaired.pdf")

        let before = try QPDF.inspect(input)
        #expect(before.damage.needsRepair == false)
        #expect(before.report.warningCount == 0)

        let report = try timed("repair valid") { try QPDF.repair(input: input, output: output) }
        #expect(report.warningCount == 0, "a clean file must produce no warnings")

        let after = try QPDF.inspect(output)
        #expect(after.pageCount == before.pageCount)
        #expect(after.damage.needsRepair == false)
        #expect(IndependentReader.pageCount(of: output) == Int(before.pageCount))

        // Page geometry survives, checked through PDFKit rather than qpdf.
        #expect(IndependentReader.mediaBoxes(of: input) == IndependentReader.mediaBoxes(of: output))
    }

    @Test("a repaired copy is deterministic when asked to be")
    func deterministicRepairIsReproducible() throws {
        let box = try Sandbox("deterministic")
        let input = try box.fixture(.rectangle)
        let first = box.file("first.pdf")
        let second = box.file("second.pdf")
        let options = QPDFWriteOptions(deterministicID: true)

        try QPDF.repair(input: input, output: first, writeOptions: options)
        try QPDF.repair(input: input, output: second, writeOptions: options)

        #expect(try Hashing.sha256(of: first) == (try Hashing.sha256(of: second)))
    }

    @Test("linearization produces a valid linearized file")
    func linearizeProducesLinearizedOutput() throws {
        let box = try Sandbox("linearize")
        let input = try box.fixture(.threeHundredPages)
        let output = box.file("linear.pdf")

        #expect(try QPDF.inspect(input).isLinearized == false)

        try timed("linearize 300 pages") { try QPDF.linearize(input: input, output: output) }

        let after = try QPDF.inspect(output)
        #expect(after.isLinearized)
        #expect(after.linearizationIsValid)
        #expect(after.pageCount == 300)
        #expect(IndependentReader.pageCount(of: output) == 300)
    }

    @Test("inspection reports a structural inventory, not just a verdict")
    func inspectionReportsInventory() throws {
        let box = try Sandbox("inventory")
        let input = try box.fixture(.titleBlockSheet)

        let found = try timed("inspect title block sheet") { try QPDF.inspect(input) }

        #expect(found.pageCount >= 1)
        #expect(found.objectCount > 0)
        #expect(found.streamCount > 0)
        #expect(found.fileSize > 0)
        #expect(found.isEncrypted == false)
        #expect(found.pdfVersion.hasPrefix("1."))
        print(
            "[inventory] \(input.lastPathComponent): \(found.objectCount) objects, "
                + "\(found.streamCount) streams, \(found.pageCount) pages, "
                + "PDF \(found.pdfVersion), \(found.fileSize) bytes")
    }

    @Test("a cyclic page tree is refused with a typed error, not a hang")
    func cyclicPageTreeIsRefused() throws {
        let box = try Sandbox("cyclic")
        let input = try box.fixture(.cyclicPageTree)

        // qpdf detects the loop while flattening the page tree and raises a
        // pages error. The important part is that it is typed and bounded.
        let start = Date()
        #expect(throws: QPDFError.self) { try QPDF.inspect(input) }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("a decompression bomb stays inside its memory bound")
    func decompressionBombIsBounded() throws {
        let box = try Sandbox("bomb")
        let input = try box.fixture(.decompressionBomb)
        let output = box.file("bomb-repaired.pdf")

        // 1 MiB ceiling on any single decoded stream: far below the fixture's
        // 64 MiB inflation. qpdf must refuse to decode rather than allocate.
        var options = QPDFOptions.default
        options.maximumDecodedStreamBytes = 1024 * 1024

        let found = try timed("inspect bomb with 1 MiB stream ceiling") {
            try QPDF.inspect(input, options: options)
        }
        #expect(found.damage.undecodableStreamCount >= 1, "the bomb must fail to decode")

        // Writing still works: the compressed bytes are copied, never inflated.
        try timed("repair bomb") { try QPDF.repair(input: input, output: output, options: options) }
        #expect(IndependentReader.opens(output))
    }
}
