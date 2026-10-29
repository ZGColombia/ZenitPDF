import Foundation
import Testing
import ZPDFQPDF

/// The consequence of building qpdf without libjpeg, verified rather than
/// assumed.
///
/// The decision and its reasoning are in `VENDORED.md`. The claim under test is
/// narrow and falsifiable: **a PDF containing a DCT-encoded image still opens
/// and still repairs; only its image data is passed through unmodified instead
/// of being re-encoded.** If that claim were false, building without libjpeg
/// would be unacceptable and the bridge would have to vendor libjpeg-turbo.
@Suite("DCT passthrough")
struct DCTPassthroughTests {

    @Test("a DCT image makes a stream unfilterable, not undecodable")
    func dctStreamIsUnfilterableNotDamaged() throws {
        let box = try Sandbox("dctInspect")
        let built = try DCTFixture.make(in: box.url, named: "dct.pdf")

        // The fixture is a real, valid PDF: CoreGraphics opens it and can
        // decode the JPEG, which this build cannot.
        #expect(IndependentReader.pageCount(of: built.url) == 1)

        let inventory = try timed("inspect DCT document") { try QPDF.inspect(built.url) }

        #expect(inventory.streamCount == 2, "one content stream and one image stream")
        #expect(
            inventory.damage.unfilterableStreamCount == 1,
            "the DCT stream has no decoder in this build")
        #expect(
            inventory.damage.undecodableStreamCount == 0,
            "'no decoder' must not be reported as 'decode failed'")
        #expect(inventory.damage.needsRepair == false, "a DCT image is not damage")
    }

    @Test("repairing a DCT document copies the JPEG through byte for byte")
    func repairPreservesJPEGBytes() throws {
        let box = try Sandbox("dctRepair")
        let built = try DCTFixture.make(in: box.url, named: "dct.pdf")
        let output = box.file("repaired.pdf")

        try timed("repair DCT document") {
            try QPDF.repair(input: built.url, output: output)
        }

        #expect(IndependentReader.pageCount(of: output) == 1)
        let bytes = try Data(contentsOf: output, options: .mappedIfSafe)
        #expect(
            bytes.range(of: built.jpegBytes) != nil,
            "the \(built.jpegBytes.count)-byte JPEG must survive unchanged")
    }

    @Test("a damaged DCT document repairs into an openable file with the JPEG intact")
    func damagedDCTDocumentRepairs() throws {
        let box = try Sandbox("dctDamaged")
        let built = try DCTFixture.make(
            in: box.url, named: "dct-damaged.pdf", breakCrossReferences: true)
        let output = box.file("repaired.pdf")

        // Premise: the damaged file does not open.
        #expect(IndependentReader.opens(built.url) == false)
        #expect(try QPDF.inspect(built.url).damage.crossReferenceWasReconstructed)

        try timed("repair damaged DCT document") {
            try QPDF.repair(input: built.url, output: output)
        }

        #expect(IndependentReader.pageCount(of: output) == 1)
        let bytes = try Data(contentsOf: output, options: .mappedIfSafe)
        #expect(bytes.range(of: built.jpegBytes) != nil, "repair must not touch the JPEG")

        let after = try QPDF.inspect(output)
        #expect(after.damage.needsRepair == false)
        #expect(after.damage.unfilterableStreamCount == 1)
    }

    @Test("every other filter still decodes, so the gap really is DCT alone")
    func otherFiltersStillWork() throws {
        let box = try Sandbox("otherFilters")
        // The fixture corpus compresses its content streams with Flate, which
        // this build decodes: undecodable and unfilterable are both zero.
        let inventory = try QPDF.inspect(try box.fixture(.titleBlockSheet))
        #expect(inventory.streamCount > 0)
        #expect(inventory.damage.unfilterableStreamCount == 0)
        #expect(inventory.damage.undecodableStreamCount == 0)
    }
}
