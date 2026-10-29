import Foundation
import Testing
import ZPDFQPDF
import ZPDFTestingSupport

/// Bug hunt 2 — the qpdf bridge.
@Suite("qpdf bridge — bug hunt 2", .serialized)
struct QPDFBugHunt2Tests {

    /// A one-page-tree document whose /Pages node lists itself as a kid: a loop.
    private func pageTreeLoop(in box: Sandbox) throws -> URL {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Pages /Parent 2 0 R /Kids [2 0 R] /Count 1 >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let url = box.file("loop.pdf")
        try Data(pdf.utf8).write(to: url)
        return url
    }

    /// Old output: `QPDFError.pageRangeInvalid("… Loop detected in /Pages structure")` from an
    /// inspect that takes no page index.
    @Test("BH-083: a looping page tree is damage, not a bad page index")
    func pageTreeLoopIsDamage() throws {
        let box = try Sandbox()
        let input = try pageTreeLoop(in: box)
        expectQPDFError("damaged") { _ = try QPDF.inspect(input) }
        // The refusal really comes from qpdf's page-tree walk (qpdf_e_pages).
        do {
            _ = try QPDF.inspect(input)
        } catch {
            #expect(String(describing: error).contains("/Pages"), "\(error)")
        }
    }

    /// Old output: `.passwordIncorrect` for the unencrypted-password source b because
    /// source a carried a password.
    @Test("BH-406: merge asks for a password for the source that needs one")
    func mergeReportsPasswordRequiredPerSource() throws {
        let box = try Sandbox()
        let plain = try box.fixture(.rectangle)
        let encrypted = try box.fixture(.encryptedUserPassword)
        expectQPDFError("passwordRequired") {
            _ = try QPDF.merge(
                sources: [QPDF.Source(plain, password: "unused"), QPDF.Source(encrypted)],
                output: box.file("merged.pdf"))
        }
        expectQPDFError("passwordIncorrect") {
            _ = try QPDF.merge(
                sources: [QPDF.Source(plain), QPDF.Source(encrypted, password: "wrong")],
                output: box.file("merged2.pdf"))
        }
    }

    /// Old output: the repaired / linearized copy of a password-protected drawing opened
    /// without a password.
    @Test("BH-407: repair and linearize keep the input's encryption by default")
    func defaultRewriteKeepsEncryption() throws {
        let box = try Sandbox()
        let input = try box.fixture(.encryptedUserPassword)
        let password = ZPDFFixtures.encryptedUserPassword
        let repaired = box.file("repaired.pdf")
        let linearized = box.file("linearized.pdf")
        try QPDF.repair(input: input, output: repaired, password: password)
        try QPDF.linearize(input: input, output: linearized, password: password)
        for url in [repaired, linearized] {
            expectQPDFError("passwordRequired") { _ = try QPDF.inspect(url) }
            #expect(try QPDF.inspect(url, password: password).isEncrypted)
        }
        // An unencrypted input stays unencrypted.
        let plainOut = box.file("plain.pdf")
        try QPDF.repair(input: try box.fixture(.rectangle), output: plainOut)
        #expect(try QPDF.inspect(plainOut).isEncrypted == false)
    }

    /// Old output: extractPages with preservesEncryption wrote a plaintext file and said nothing.
    @Test("BH-408: page assembly refuses preservesEncryption it cannot honour")
    func assemblyRefusesPreserveEncryption() throws {
        let box = try Sandbox()
        let input = try box.fixture(.rectangle)
        let write = QPDFWriteOptions(preservesEncryption: true)
        expectQPDFError("invalidArgument") {
            _ = try QPDF.extractPages(input: input, output: box.file("x.pdf"), pageIndices: [0], writeOptions: write)
        }
        expectQPDFError("invalidArgument") {
            _ = try QPDF.split(input: input, outputDirectory: box.url, basename: "s", writeOptions: write)
        }
        expectQPDFError("invalidArgument") {
            _ = try QPDF.merge(sources: [QPDF.Source(input)], output: box.file("m.pdf"), writeOptions: write)
        }
    }

    /// Old output: `.damaged` ("unable to generated a deterministic ID…") for an argument
    /// error, and qdf/linearize silently not honoured.
    @Test("BH-409: contradictory write options are refused up front")
    func contradictoryOptionsRefused() throws {
        let box = try Sandbox()
        let input = try box.fixture(.encryptedUserPassword)
        let password = ZPDFFixtures.encryptedUserPassword
        for options in [
            QPDFWriteOptions(preservesEncryption: true, deterministicID: true),
            QPDFWriteOptions(preservesEncryption: true, qdf: true),
            QPDFWriteOptions(linearize: true, qdf: true),
        ] {
            expectQPDFError("invalidArgument") {
                _ = try QPDF.repair(input: input, output: box.file(UUID().uuidString + ".pdf"),
                                    password: password, writeOptions: options)
            }
        }
    }

    /// Old output: with maximumWarnings 1 the second parse warning aborted the repair as
    /// `.damaged` ("Too many warnings - file is too badly damaged").
    @Test("BH-410: maximumWarnings caps collection instead of aborting the parse")
    func warningCapDoesNotAbort() throws {
        let box = try Sandbox()
        let input = try box.fixture(.brokenXref)
        let uncapped = try QPDF.inspect(input)
        #expect(uncapped.report.warningCount >= 2, "the fixture must produce several warnings")
        let capped = try QPDF.inspect(input, options: QPDFOptions(maximumWarnings: 1))
        #expect(capped.report.warningCount == uncapped.report.warningCount)
        #expect(capped.report.warnings.count <= 1)
        #expect(capped.report.warningsTruncated)
        try QPDF.repair(input: input, output: box.file("r.pdf"), options: QPDFOptions(maximumWarnings: 1))
    }

    /// Old output: `maximumPageCount: 0` silently became 20 000.
    @Test("BH-411: zero or negative bounds are refused, not replaced by defaults")
    func zeroBoundsRefused() throws {
        let box = try Sandbox()
        let input = try box.fixture(.rectangle)
        for options in [
            QPDFOptions(maximumPageCount: 0),
            QPDFOptions(maximumInputBytes: 0),
            QPDFOptions(maximumInputBytes: -5),
            QPDFOptions(maximumStreamFilters: 0),
        ] {
            expectQPDFError("invalidArgument") { _ = try QPDF.inspect(input, options: options) }
        }
    }
}
