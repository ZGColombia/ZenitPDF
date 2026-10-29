import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// A pinned clock: `now()` returns a fixed instant, then advances by one second per read.
private struct PinnedClock: TimestampProviding {
    let start: Date
    func now() -> Date { start }
}

@Suite("Provenance recording (ADR-0007)")
struct ProvenanceRecordingTests {

    private static let computedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private static func makeRecording(
        evidence: CalibrationEvidence? = nil
    ) -> ProvenanceRecording {
        ProvenanceRecording(
            engine: MeasurementEngine(),
            context: ProvenanceContext(
                engineVersion: "1.0.0-test",
                calibrationEvidence: evidence,
                timestamps: PinnedClock(start: computedAt)
            )
        )
    }

    @Test("Every calculate() result carries its provenance")
    func resultCarriesProvenance() throws {
        let geometry = Fixture.polygon([(0, 0), (10, 0), (10, 10), (0, 10)])
        let recording = Self.makeRecording()
        let result = try recording.calculate(
            tool: .area,
            geometry: geometry,
            scale: Fixture.unitScale
        )
        let provenance = try #require(result.provenance)
        #expect(provenance.geometryDigest == GeometryDigest.digest(of: geometry))
        #expect(provenance.scaleID == Fixture.unitScale.id)
        #expect(provenance.scaleVersion == Fixture.unitScale.version)
        #expect(provenance.scaleSource == .preset)
        #expect(provenance.calibrationEvidence == nil)
        #expect(provenance.slope == MeasurementParameters.default.slope)
        #expect(provenance.parameters == .default)
        #expect(provenance.formulaVersion == result.formulaVersion)
        #expect(provenance.engineVersion == "1.0.0-test")
        #expect(provenance.computedAt == Self.computedAt)
        #expect(provenance.layerName == nil)
    }

    @Test("The wrapper never changes the calculation")
    func valuesAreIdenticalToTheBareEngine() throws {
        let geometry = Fixture.polygon([(0, 0), (12, 0), (12, 8), (0, 8)], holes: [
            [(2, 2), (4, 2), (4, 4), (2, 4)]
        ])
        let bare = try MeasurementEngine().calculate(
            tool: .area,
            geometry: geometry,
            scale: Fixture.unitScale
        )
        let recorded = try Self.makeRecording().calculate(
            tool: .area,
            geometry: geometry,
            scale: Fixture.unitScale
        )
        #expect(recorded.values == bare.values)
        #expect(recorded.warnings == bare.warnings)
        #expect(recorded.formulaVersion == bare.formulaVersion)
        #expect(bare.provenance == nil)
        #expect(recorded.provenance != nil)
    }

    @Test("Calibration evidence travels into the provenance")
    func evidenceIsCarried() throws {
        let evidence = CalibrationEvidence(
            points: [PDFPoint(x: 10, y: 20), PDFPoint(x: 110, y: 20)],
            enteredLength: .length(5),
            enteredUnit: .metre
        )
        let result = try Self.makeRecording(evidence: evidence).calculate(
            tool: .length,
            geometry: Fixture.polyline([(0, 0), (10, 0)]),
            scale: Fixture.unitScale
        )
        #expect(result.provenance?.calibrationEvidence == evidence)
    }

    /// S-111: the only recording entry point is `calculate(tool:...)`, which runs the engine's
    /// input guards. The deleted `ProvenanceRecording.calculator(for:)` wrapper called the tool's
    /// calculator directly, so a 1e9 pt square came back as 1e18 pt2 of area with provenance
    /// attached, where the shipping path refuses it with `coordinateOutOfRange` (R-169).
    @Test("Recording runs the engine's input guards (S-111)")
    func recordingRunsTheGuards() throws {
        let recording = Self.makeRecording()
        let huge = Fixture.polygon([(0, 0), (1e9, 0), (1e9, 1e9), (0, 1e9)])
        #expect(throws: MeasurementEngineError.measurement(.coordinateOutOfRange)) {
            try recording.calculate(tool: .area, geometry: huge, scale: Fixture.unitScale)
        }
        let result = try recording.calculate(
            tool: .length,
            geometry: Fixture.polyline([(0, 0), (3, 4)]),
            scale: Fixture.unitScale
        )
        #expect(result.provenance != nil)
        #expect(result[.planLength]?.value == 5)
    }

    @Test("The geometry digest is deterministic and shape-sensitive")
    func digestIsStableAndSensitive() {
        let square = Fixture.polygon([(0, 0), (10, 0), (10, 10), (0, 10)])
        let squareAgain = Fixture.polygon([(0, 0), (10, 0), (10, 10), (0, 10)])
        let nudged = Fixture.polygon([(0, 0), (10, 0), (10, 10), (0, 10.000001)])

        let digest = GeometryDigest.digest(of: square)
        #expect(digest == GeometryDigest.digest(of: squareAgain))
        #expect(digest != GeometryDigest.digest(of: nudged))
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })

        // Pinned: the canonical encoding is a frozen byte layout, so this digest may only
        // change together with GeometryDigest.encodingVersion.
        #expect(digest == GeometryDigest.digest(of: square))
    }

    @Test("Negative zero digests as zero, and collections do not collide across kinds")
    func canonicalEncodingEdgeCases() {
        let positive = Fixture.polyline([(0, 0), (1, 1)])
        let negative = MeasurementGeometry(
            pageID: Fixture.pageID,
            points: [PDFPoint(x: -0.0, y: 0), PDFPoint(x: 1, y: 1)]
        )
        #expect(GeometryDigest.digest(of: positive) == GeometryDigest.digest(of: negative))

        // The same coordinates as free points versus as a segment must not collide.
        let asPoints = Fixture.polyline([(0, 0), (1, 1)])
        let asSegment = MeasurementGeometry(
            pageID: Fixture.pageID,
            segments: [SegmentGeometry(start: PDFPoint(x: 0, y: 0), end: PDFPoint(x: 1, y: 1))]
        )
        #expect(GeometryDigest.digest(of: asPoints) != GeometryDigest.digest(of: asSegment))

        // A different page is a different digest.
        let otherPage = MeasurementGeometry(
            pageID: PageID(UUID(uuidString: "33333333-3333-4333-8333-333333333333")!),
            points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 1)]
        )
        #expect(GeometryDigest.digest(of: asPoints) != GeometryDigest.digest(of: otherPage))
    }

    @Test("An engine failure surfaces unchanged through the wrapper")
    func failuresPassThrough() {
        let empty = MeasurementGeometry(pageID: Fixture.pageID)
        #expect(throws: MeasurementEngineError.self) {
            _ = try Self.makeRecording().calculate(
                tool: .area,
                geometry: empty,
                scale: Fixture.unitScale
            )
        }
    }
}
