import Foundation
import Testing
@testable import ZPDFContracts

/// ADR-0011: a markup names artwork, never owns it — and the naming has to be additive,
/// bounded, and decodable from every project version that came before it.
@Suite("Imported artwork and markup symbols")
struct ArtworkContractTests {

    private static let epoch = Date(timeIntervalSince1970: 0)

    private static func record(
        symbol: MarkupSymbol? = nil,
        stamp: StampInstance? = nil
    ) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()),
            documentID: DocumentID(UUID(uuidString: "11111111-2222-3333-4444-555555555556") ?? UUID()),
            pageID: PageID(UUID(uuidString: "11111111-2222-3333-4444-555555555557") ?? UUID()),
            kind: .count,
            stamp: stamp,
            symbol: symbol,
            createdAt: epoch,
            modifiedAt: epoch
        )
    }

    // MARK: - The contract stayed additive

    @Test("The markup contract is at version 6 (ADR-0032)")
    func versionIsFive() {
        // 4 is ADR-0012 (provenance and derivation), 5 ADR-0029, 6 ADR-0032 (markup layers).
        // The additive-decode claim for version 4 lives in QuantityProvenanceTests.
        #expect(ContractVersion.markup == 6)  // ADR-0032
    }

    @Test("A record written before this build — no symbol key at all — decodes with a nil symbol")
    func versionTwoRecordDecodesUnchanged() throws {
        // Encode a record, then delete the key a version-2 writer would never have written.
        // This is the actual compatibility claim: an absent key, not a null one.
        let original = Self.record()
        let data = try JSONEncoder().encode(original)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "symbol")
        #expect(object["symbol"] == nil)
        let trimmed = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MarkupRecord.self, from: trimmed)
        #expect(decoded.symbol == nil)
        #expect(decoded == original)
    }

    @Test("A symbol round-trips through Codable unchanged")
    func symbolRoundTrips() throws {
        let symbol = MarkupSymbol(
            artworkDigest: String(repeating: "a", count: 64),
            kind: .vector,
            builtInGlyph: nil,
            sizePoints: 18,
            rotationDegrees: 45,
            sourceName: "seal.pdf"
        )
        let record = Self.record(symbol: symbol)
        let decoded = try JSONDecoder().decode(
            MarkupRecord.self, from: JSONEncoder().encode(record)
        )
        #expect(decoded.symbol == symbol)
        #expect(decoded.symbol?.usesImportedArtwork == true)
        #expect(decoded.symbol?.staysSharpWhenMagnified == true)
    }

    @Test("A raster symbol says it will not stay sharp")
    func rasterSymbolIsMarked() {
        let raster = MarkupSymbol(
            artworkDigest: String(repeating: "b", count: 64), kind: .raster, sizePoints: 24
        )
        #expect(raster.staysSharpWhenMagnified == false)
        #expect(MarkupSymbol.builtIn("filledCircle").staysSharpWhenMagnified)
        #expect(MarkupSymbol.builtIn("filledCircle").usesImportedArtwork == false)
    }

    @Test("Both a stamp and a count mark name artwork in the same store")
    func oneReachabilityQuestion() {
        let stamp = StampInstance(
            templateID: UUID(),
            templateName: "Approved",
            artworkDigest: "stampdigest",
            artworkKind: .vector,
            widthPoints: 160,
            heightPoints: 80,
            resolvedAt: Self.epoch
        )
        // Both digests, read the way every artwork consumer reads them (U-096 deleted the
        // one-digest `referencedArtworkDigest`, which no consumer used).
        func digests(_ record: MarkupRecord) -> [String] {
            [record.symbol?.artworkDigest, record.stamp?.artworkDigest].compactMap { $0 }
        }
        #expect(digests(Self.record(stamp: stamp)) == ["stampdigest"])
        #expect(digests(Self.record(symbol: MarkupSymbol(artworkDigest: "symboldigest", kind: .raster))) == ["symboldigest"])
        #expect(digests(Self.record()).isEmpty)
    }

    @Test("A size that cannot be placed is refused rather than drawn")
    func sizesAreBounded() {
        #expect(MarkupSymbol(sizePoints: 12).hasUsableSize)
        #expect(MarkupSymbol(sizePoints: 0).hasUsableSize == false)
        #expect(MarkupSymbol(sizePoints: .nan).hasUsableSize == false)
        #expect(MarkupSymbol(sizePoints: .infinity).hasUsableSize == false)
        #expect(MarkupSymbol(sizePoints: 1_000_000).hasUsableSize == false)
        #expect(MarkupSymbol(sizePoints: 12, rotationDegrees: .nan).hasUsableSize == false)
    }

    // MARK: - Imported artwork is bounded, and every refusal names its limit

    @Test("Well-formed artwork passes, and reports its own cost")
    func wellFormedArtworkPasses() {
        let artwork = ArtworkGeometry(
            kind: .vector,
            strokes: [ArtworkContour(points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 1)])],
            regions: [ArtworkRegion(outer: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 1, y: 1)
            ])]
        )
        #expect(artwork.limitViolation() == nil)
        #expect(artwork.primitiveCount == 2)
        #expect(artwork.pointCount == 5)
        #expect(artwork.isWellFormed)
        #expect(ArtworkGeometry.empty.isEmpty)
    }

    @Test("A contour bomb is refused, and the refusal carries the count and the limit")
    func tooManyContoursIsRefused() {
        let one = ArtworkContour(points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 1)])
        let artwork = ArtworkGeometry(
            kind: .vector,
            strokes: Array(repeating: one, count: ArtworkLimits.maximumContours + 1)
        )
        let refusal = artwork.limitViolation()
        #expect(refusal == .tooManyContours(
            found: ArtworkLimits.maximumContours + 1, limit: ArtworkLimits.maximumContours
        ))
        #expect(refusal?.reason.contains("\(ArtworkLimits.maximumContours)") == true)
    }

    @Test("One path with too many vertices is the same attack in one object, and is refused")
    func oneEnormousContourIsRefused() {
        let points = (0...ArtworkLimits.maximumPointsPerContour).map {
            PDFPoint(x: Double($0 % 2), y: 0.5)
        }
        let artwork = ArtworkGeometry(kind: .vector, strokes: [ArtworkContour(points: points)])
        #expect(artwork.limitViolation() == .contourTooLong(
            found: points.count, limit: ArtworkLimits.maximumPointsPerContour
        ))
    }

    @Test("Contours and vertices are bounded jointly, not only one at a time")
    func totalPointsAreBounded() {
        // Every contour is legal and every count is legal; the product is not. This is the
        // case a per-contour limit alone lets through.
        let contour = ArtworkContour(
            points: (0..<100).map { PDFPoint(x: Double($0 % 2), y: 0.25) }
        )
        let count = ArtworkLimits.maximumTotalPoints / 100 + 1
        let artwork = ArtworkGeometry(
            kind: .vector, strokes: Array(repeating: contour, count: count)
        )
        #expect(artwork.strokes.count <= ArtworkLimits.maximumContours)
        guard case .tooManyPoints? = artwork.limitViolation() else {
            Issue.record("expected a total-point refusal, got \(String(describing: artwork.limitViolation()))")
            return
        }
    }

    @Test("A coordinate outside the unit box, or not finite at all, is refused — each by name")
    func nonFiniteGeometryIsRefused() {
        // BH-479: a finite 4 is outside the unit box, not "not a finite number". The old
        // output for `escaped` was `.nonFiniteGeometry`, whose sentence told the estimator
        // about a non-finite number that did not exist.
        let escaped = ArtworkGeometry(
            kind: .vector,
            regions: [ArtworkRegion(outer: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 4, y: 0), PDFPoint(x: 0, y: 1)
            ])]
        )
        #expect(escaped.limitViolation() == .coordinateOutsideUnitBox)

        let notANumber = ArtworkGeometry(
            kind: .vector,
            strokes: [ArtworkContour(points: [PDFPoint(x: .nan, y: 0), PDFPoint(x: 1, y: 1)])]
        )
        #expect(notANumber.limitViolation() == .nonFiniteGeometry)

        // A zero-area source box has no unit space; old output: `.nonFiniteGeometry` again.
        let badAspect = ArtworkGeometry(kind: .vector, sourceAspectRatio: 0)
        #expect(badAspect.isWellFormed == false)
        #expect(badAspect.limitViolation() == .degenerateBounds)
    }

    @Test("Compiled artwork survives storage: what is read back is checked, not trusted")
    func storedArtworkIsCheckedOnTheWayOut() throws {
        let artwork = ArtworkGeometry(
            kind: .raster,
            regions: [ArtworkRegion(
                outer: [PDFPoint(x: 0, y: 0), PDFPoint(x: 0.5, y: 0), PDFPoint(x: 0.5, y: 0.5)],
                color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
            )],
            sourceAspectRatio: 2
        )
        let decoded = try JSONDecoder().decode(
            ArtworkGeometry.self, from: JSONEncoder().encode(artwork)
        )
        #expect(decoded == artwork)
        #expect(decoded.limitViolation() == nil)
        #expect(decoded.kind.staysSharpWhenMagnified == false)

        // A file edited by hand between two opens is input again, and the same one function
        // answers for it.
        var tampered = decoded
        tampered.regions[0].outer[1] = PDFPoint(x: 12, y: 0)
        // BH-479: old output `.nonFiniteGeometry` for a finite, out-of-box 12.
        #expect(tampered.limitViolation() == .coordinateOutsideUnitBox)
    }

    @Test("Every refusal reason names a number the person can act on")
    func refusalsAreSentences() {
        let refusals: [ArtworkImportRefusal] = [
            .sourceTooLarge(bytes: 99, limit: 10),
            .unreadableSource,
            .encryptedSource,
            .pageOutOfRange(requested: 4, pageCount: 2),
            .empty,
            .tooManyContours(found: 41_208, limit: 20_000),
            .contourTooLong(found: 9_000, limit: 8_000),
            .tooManyPoints(found: 300_000, limit: 200_000),
            .rasterTooLarge(pixels: 50_000_000, limit: 40_000_000),
            .nestingTooDeep(depth: 40, limit: 12),
            .nonFiniteGeometry,
            .degenerateBounds
        ]
        for refusal in refusals {
            #expect(!refusal.reason.isEmpty)
            #expect(refusal.reason.hasSuffix("."))
        }
        #expect(
            ArtworkImportRefusal.tooManyContours(found: 41_208, limit: 20_000).reason
                == "This artwork has 41208 contours; the limit is 20000."
        )
    }
}
