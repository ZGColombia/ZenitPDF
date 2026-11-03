import CoreGraphics
import CoreText
import Foundation
import Testing
import Vision
import ZPDFSearch
import ZPDFUIPresentation

@testable import ZPDFAppCore

/// 1.0.1: a region read — a scanned title block, a scale note — falls back when Vision throws.
/// On macOS 27 the default `.accurate` request threw, the callers' `try?` turned that into no
/// lines, and sheet naming, the scale offer and the dimension check silently read nothing.
///
/// Vision's call is the seam: a stand-in throws for the attempts a test chooses. Only `.fast`
/// runs Vision for real, which read on the virtual Mac where `.accurate` threw.
@Suite("Region text recognition falls back when Vision throws (1.0.1)", .serialized)
struct RegionTextRecognizerFallbackTests {

    private typealias Attempt = TextRecognitionFallback.Attempt

    private struct Thrown: Error, Equatable {
        let attempt: Attempt
    }

    /// The page rectangle the image shows.
    private static let region = PDFRectValue(x: 100, y: 200, width: 400, height: 100)

    /// Reads the fixture through the region recogniser, throwing for the attempts in `failing`
    /// and running Vision only for `.fast`. Records the attempts that ran and their requests.
    private static func read(
        failing: Set<Attempt>,
        ran: inout [Attempt],
        requests: inout [Attempt: VNRecognizeTextRequest]
    ) throws -> [RegionTextRecognizer.Line] {
        var attempts: [Attempt] = []
        var made: [Attempt: VNRecognizeTextRequest] = [:]
        defer {
            ran = attempts
            requests = made
        }
        return try RegionTextRecognizer.recognize(
            image: try image(of: "SCALE 1:50"),
            region: region,
            languages: ["en-US", "sv-SE"],
            minimumConfidence: 0.3,
            perform: { attempt, request, image in
                attempts.append(attempt)
                made[attempt] = request
                if failing.contains(attempt) { throw Thrown(attempt: attempt) }
                if attempt == .fast { try TextRecognitionFallback.performWithVision(attempt, request, image) }
            }
        )
    }

    @Test("A region read runs the accurate request alone when it does not throw")
    func firstAttemptWorks() throws {
        var ran: [Attempt] = []
        var requests: [Attempt: VNRecognizeTextRequest] = [:]
        _ = try Self.read(failing: [], ran: &ran, requests: &requests)
        #expect(ran == [.configured])
        let request = try #require(requests[.configured])
        #expect(request.recognitionLevel == .accurate)
        #expect(request.revision == VNRecognizeTextRequest.defaultRevision)
        #expect(!request.usesLanguageCorrection)
        #expect(request.recognitionLanguages.contains("en-US"))
    }

    @Test("A region read whose accurate request throws is read again at revision 2")
    func secondAttemptWorks() throws {
        guard VNRecognizeTextRequest.supportedRevisions.contains(2) else { return }
        var ran: [Attempt] = []
        var requests: [Attempt: VNRecognizeTextRequest] = [:]
        _ = try Self.read(failing: [.configured], ran: &ran, requests: &requests)
        #expect(ran == [.configured, .accurateRevision2])
        let request = try #require(requests[.accurateRevision2])
        #expect(request.revision == 2)
        #expect(request.recognitionLevel == .accurate)
        #expect(!request.usesLanguageCorrection)
        #expect(Set(request.recognitionLanguages).isSubset(of: Set(try request.supportedRecognitionLanguages())))
    }

    @Test("When both accurate attempts throw, .fast reads the region's words in page space")
    func fastReads() throws {
        var ran: [Attempt] = []
        var requests: [Attempt: VNRecognizeTextRequest] = [:]
        let lines = try Self.read(failing: [.configured, .accurateRevision2], ran: &ran, requests: &requests)
        #expect(ran.last == .fast)
        #expect(ran.first == .configured)
        let request = try #require(requests[.fast])
        #expect(request.recognitionLevel == .fast)
        #expect(Set(request.recognitionLanguages).isSubset(of: Set(try request.supportedRecognitionLanguages())))

        let line = try #require(lines.first { $0.text.contains("SCALE") }, "read: \(lines.map(\.text))")
        let bounds = line.boundsInPageSpace
        #expect(bounds.minX >= Self.region.minX && bounds.minX + bounds.size.width <= Self.region.minX + Self.region.size.width)
        #expect(bounds.minY >= Self.region.minY && bounds.minY + bounds.size.height <= Self.region.minY + Self.region.size.height)
    }

    @Test("When every attempt throws, the region read throws the accurate request's error")
    func everyAttemptThrows() {
        var ran: [Attempt] = []
        var requests: [Attempt: VNRecognizeTextRequest] = [:]
        #expect(throws: Thrown(attempt: .configured)) {
            try Self.read(failing: Set(Attempt.allCases), ran: &ran, requests: &requests)
        }
        #expect(ran.first == .configured && ran.last == .fast)
    }

    // MARK: - Fixture

    /// `text` in 96 pt Helvetica, black on white, on a 4:1 bitmap like the region it shows.
    private static func image(of text: String) throws -> CGImage {
        let width = 1_200, height = 300
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 96, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]))
        context.textPosition = CGPoint(x: 40, y: 100)
        CTLineDraw(line, context)
        return try #require(context.makeImage())
    }
}
