import Foundation
import Testing
import ZPDFContracts
import ZPDFPersistence
@testable import ZPDFAppCore

/// Feature 16 — the resolution behind a traceable row.
///
/// The exporters print what this type decides. The decision that matters is the refusal: when the
/// transform a measurement was taken under is not in the session, the answer is `unknown`, and no
/// path through this code can substitute the scale that is in force now.
@Suite("Measurement trace resolution")
struct MeasurementTraceTests {

    // MARK: - Fixture

    static let epoch = Date(timeIntervalSince1970: 1_780_000_000)
    static let documentID = DocumentID(UUID(uuidString: "00000000-0000-4000-8000-0000000000D0")!)
    static let pageID = PageID(UUID(uuidString: "00000000-0000-4000-8000-0000000000E0")!)
    static let scaleID = ScaleID(UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!)
    static let markupID = MarkupID(UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!)
    static let regionID = ScaleRegionID(UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!)

    /// `1:50` at version 1, `1:100` after a recalibration bumps it to version 2.
    static func scale(version: Int, metresPerPoint: Decimal) throws -> ScaleTransform {
        try ScaleTransform.uniform(
            id: scaleID,
            pageID: pageID,
            version: version,
            metresPerPoint: metresPerPoint,
            units: ScaleUnitPolicy(length: .metre, area: .squareMetre, volume: .cubicMetre),
            source: .preset
        )
    }

    /// 1 pt = 1/72 in = 0.0254/72 m at 1:1, so 1:50 is fifty times that.
    static func metresPerPoint(denominator: Int) -> Decimal {
        Decimal(denominator) * Decimal(string: "0.000352777777777778")!
    }

    static func markup(
        scaleVersion: Int?,
        provenanceVersion: Int? = nil,
        region: ScaleRegionID? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        computedAt: Date? = nil
    ) -> ZPDFContracts.MarkupRecord {
        var measurement = MeasurementResult(values: [.planArea: .area(12)])
        if let provenanceVersion {
            measurement = measurement.attaching(MeasurementProvenance(
                geometryDigest: String(repeating: "0", count: 64),
                scaleID: scaleID,
                scalePageID: pageID,
                scaleVersion: provenanceVersion,
                scaleSource: .preset,
                slope: .none,
                parameters: MeasurementParameters(),
                formulaVersion: 1,
                engineVersion: "test",
                computedAt: computedAt ?? epoch
            ))
        }
        return ZPDFContracts.MarkupRecord(
            id: markupID,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Concrete",
            label: "L1",
            author: "Ada",
            scaleRegionID: region,
            scaleID: scaleVersion == nil ? nil : scaleID,
            scaleVersion: scaleVersion,
            measurement: measurement,
            createdAt: createdAt ?? epoch,
            modifiedAt: modifiedAt ?? epoch
        )
    }

    static func sources(scales: [ScaleTransform]) -> MeasurementTraceResolver.Sources {
        MeasurementTraceResolver.Sources(
            pageLabels: [pageID: "A-40"],
            scales: MeasurementTraceResolver.Sources.index(scales),
            scaleRegionNames: [regionID: "Basement"]
        )
    }

    // MARK: - The ordinary case

    @Test("A markup measured under a scale this session still holds names that scale")
    func resolvesTheScaleItWasMeasuredAt() throws {
        let atFifty = try Self.scale(version: 1, metresPerPoint: Self.metresPerPoint(denominator: 50))
        let facts = MeasurementTraceResolver().facts(
            for: Self.markup(scaleVersion: 1),
            sources: Self.sources(scales: [atFifty])
        )
        #expect(facts.sheetLabel == "A-40")
        #expect(facts.scaleAtMeasureTime == "1:50")
        #expect(facts.scaleText == "1:50")
        #expect(facts.scaleAtMeasureTime != nil)
        #expect(facts.author == "Ada")
        #expect(facts.createdAt == Self.epoch)
    }

    @Test("A measurement taken inside a Scale Region names the region")
    func namesTheScaleRegion() throws {
        let atFifty = try Self.scale(version: 1, metresPerPoint: Self.metresPerPoint(denominator: 50))
        let facts = MeasurementTraceResolver().facts(
            for: Self.markup(scaleVersion: 1, region: Self.regionID),
            sources: Self.sources(scales: [atFifty])
        )
        #expect(facts.scaleRegionLabel == "Basement")
    }

    // MARK: - The invariant

    @Test("A markup measured before a recalibration never reports the current scale")
    func recalibrationDoesNotRewriteHistory() throws {
        // The page is now at 1:100, version 2. The markup was measured at version 1, whose
        // transform this session no longer holds.
        let current = try Self.scale(version: 2, metresPerPoint: Self.metresPerPoint(denominator: 100))
        let stale = Self.markup(scaleVersion: 1)

        let facts = MeasurementTraceResolver().facts(
            for: stale,
            sources: Self.sources(scales: [current])
        )
        #expect(facts.scaleAtMeasureTime == nil)
        #expect(facts.scaleText == "unknown")
        #expect(facts.scaleAtMeasureTime == nil)
        // Specifically: not the scale in force now, and not the scale in force then guessed at.
        #expect(facts.scaleText != "1:100")
        #expect(facts.scaleText != "1:50")
        // The contract agrees the measurement is stale, which is the condition this covers.
        #expect(stale.isMeasurementStale(against: current))
    }

    @Test("The same markup names its scale again once the old version is available")
    func theOldVersionIsUsedWhenItIsThere() throws {
        let old = try Self.scale(version: 1, metresPerPoint: Self.metresPerPoint(denominator: 50))
        let current = try Self.scale(version: 2, metresPerPoint: Self.metresPerPoint(denominator: 100))
        let facts = MeasurementTraceResolver().facts(
            for: Self.markup(scaleVersion: 1),
            sources: Self.sources(scales: [old, current])
        )
        // Both versions in the session; the *measured* one wins, not the newest.
        #expect(facts.scaleAtMeasureTime == "1:50")
    }

    @Test("Provenance outranks the markup's own stored version")
    func provenanceIsTheBestEvidence() throws {
        let one = try Self.scale(version: 1, metresPerPoint: Self.metresPerPoint(denominator: 50))
        let two = try Self.scale(version: 2, metresPerPoint: Self.metresPerPoint(denominator: 100))
        // The record says version 2; the provenance recorded at calculation time says version 1.
        let record = Self.markup(scaleVersion: 2, provenanceVersion: 1)
        let resolver = MeasurementTraceResolver()

        #expect(resolver.candidateVersions(for: record, sources: Self.sources(scales: []))
            .map(\.version) == [1, 2])
        #expect(resolver.resolveScale(for: record, sources: Self.sources(scales: [one, two])) == "1:50")
    }

    @Test("A markup with no scale at all is unknown, not blank and not borrowed")
    func noScaleAtAll() throws {
        let current = try Self.scale(version: 1, metresPerPoint: Self.metresPerPoint(denominator: 50))
        let facts = MeasurementTraceResolver().facts(
            for: Self.markup(scaleVersion: nil),
            sources: Self.sources(scales: [current])
        )
        #expect(facts.scaleAtMeasureTime == nil)
        #expect(facts.scaleText == "unknown")
        // The word is the one the export layer prints. The two packages do not depend on each
        // other, so the spelling is pinned here rather than shared.
        #expect(MeasurementTraceResolver.unknownText == "unknown")
    }

    // MARK: - The audit trail

    @Test("The audit trail supplies the scale version when the record has lost it")
    func auditTrailSuppliesTheVersion() throws {
        let old = try Self.scale(version: 1, metresPerPoint: Self.metresPerPoint(denominator: 50))
        let current = try Self.scale(version: 2, metresPerPoint: Self.metresPerPoint(denominator: 100))

        var sources = Self.sources(scales: [old, current])
        sources.absorb(auditTrail: [
            Self.auditEntry(sequence: 1, action: .markupCreated, version: 1, at: Self.epoch)
        ])

        // The record carries nothing; ADR-0007's trail does.
        let facts = MeasurementTraceResolver().facts(
            for: Self.markup(scaleVersion: nil),
            sources: sources
        )
        #expect(facts.scaleAtMeasureTime == "1:50")
    }

    @Test("A re-measured markup shows the later date")
    func reMeasuredShowsTheLaterDate() throws {
        let old = try Self.scale(version: 1, metresPerPoint: Self.metresPerPoint(denominator: 50))
        let later = Self.epoch.addingTimeInterval(86_400 * 7)

        var before = Self.sources(scales: [old])
        before.absorb(auditTrail: [
            Self.auditEntry(sequence: 1, action: .markupCreated, version: 1, at: Self.epoch)
        ])
        var after = Self.sources(scales: [old])
        after.absorb(auditTrail: [
            Self.auditEntry(sequence: 1, action: .markupCreated, version: 1, at: Self.epoch),
            Self.auditEntry(sequence: 2, action: .markupModified, version: 1, at: later)
        ])

        let record = Self.markup(scaleVersion: 1)
        let resolver = MeasurementTraceResolver()
        let first = resolver.facts(for: record, sources: before)
        let second = resolver.facts(for: record, sources: after)

        #expect(first.measuredAt == Self.epoch)
        #expect(second.measuredAt == later)
        #expect(second.measuredAt > first.measuredAt)
        // The creation date does not move when a markup is measured again.
        #expect(second.createdAt == first.createdAt)
        #expect(second.createdAt == Self.epoch)
    }

    @Test("An undone measurement does not become the measurement date")
    func undoIsNotAMeasurement() throws {
        let old = try Self.scale(version: 1, metresPerPoint: Self.metresPerPoint(denominator: 50))
        let undoneAt = Self.epoch.addingTimeInterval(86_400 * 30)

        var sources = Self.sources(scales: [old])
        sources.absorb(auditTrail: [
            Self.auditEntry(sequence: 1, action: .markupCreated, version: 1, at: Self.epoch),
            // A compensating entry records that something was taken back, not that a measurement
            // was taken. Reading it as the measurement date would date the row to the undo.
            Self.auditEntry(sequence: 2, action: .compensated, version: 1, at: undoneAt)
        ])

        let facts = MeasurementTraceResolver().facts(
            for: Self.markup(scaleVersion: 1),
            sources: sources
        )
        #expect(facts.measuredAt == Self.epoch)
    }

    @Test("Provenance's own timestamp is the measurement date when it exists")
    func provenanceTimestampWins() throws {
        let old = try Self.scale(version: 1, metresPerPoint: Self.metresPerPoint(denominator: 50))
        let computed = Self.epoch.addingTimeInterval(3_600)
        let facts = MeasurementTraceResolver().facts(
            for: Self.markup(
                scaleVersion: 1,
                provenanceVersion: 1,
                modifiedAt: Self.epoch.addingTimeInterval(999_999),
                computedAt: computed
            ),
            sources: Self.sources(scales: [old])
        )
        #expect(facts.measuredAt == computed)
    }

    // MARK: - Helpers

    static func auditEntry(
        sequence: Int,
        action: MeasurementAuditAction,
        version: Int,
        at date: Date
    ) -> MeasurementAuditRecord {
        MeasurementAuditRecord(
            id: "audit-\(sequence)",
            projectId: "project",
            markupId: markupID.rawValue.uuidString,
            sequence: sequence,
            occurredAt: PersistenceTimestamp.string(from: date),
            action: action.rawValue,
            actor: "Ada",
            beforeValuesJson: nil,
            afterValuesJson: nil,
            scaleId: scaleID.rawValue.uuidString,
            scaleVersion: version,
            formulaVersion: 1,
            commandName: nil,
            undoGroup: nil,
            note: nil
        )
    }
}
