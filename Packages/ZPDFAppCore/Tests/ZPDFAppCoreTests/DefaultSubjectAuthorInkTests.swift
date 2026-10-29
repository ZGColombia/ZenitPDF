import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// The default subject, the author identity and the committed measurement ink at the commit
/// boundary: what a new measurement is called, who signs it, and what ink it carries into
/// the stored style.
@Suite("Default subject, author and ink")
struct DefaultSubjectAndInkTests {

    @MainActor
    private func makeEnvironment() async throws -> (AppCoreEnvironment, TakeoffSession, ZPDFContracts.PageDescriptor) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        // A scale must exist: a missing scale blocks committing (spec 12).
        _ = try await session.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        return (environment, session, page)
    }

    @MainActor
    private func commit(
        _ kind: ZPDFUIPresentation.MeasurementKind,
        points: [PDFPointValue],
        configure: (AppMeasurementToolPresenter) -> Void = { _ in }
    ) async throws -> ZPDFContracts.MarkupRecord {
        let (environment, _, _) = try await makeEnvironment()
        var committed: ZPDFContracts.MarkupRecord?
        environment.measurement.onCommit = { committed = $0 }
        environment.measurement.activate(kind: kind)
        configure(environment.measurement)
        for point in points { environment.measurement.placePoint(point) }
        await environment.measurement.settlePlacements()
        environment.measurement.commitActiveMeasurement()
        return try #require(committed, "the measurement did not commit")
    }

    private static let lengthPoints = [PDFPointValue(x: 10, y: 10), PDFPointValue(x: 110, y: 10)]
    private static let areaPoints = [
        PDFPointValue(x: 10, y: 10), PDFPointValue(x: 110, y: 10), PDFPointValue(x: 110, y: 90)
    ]

    // MARK: Default subject = tool name

    @Test("A new measurement's subject defaults to the tool name")
    @MainActor
    func subjectDefaultsToTheToolName() async throws {
        let length = try await commit(.length, points: Self.lengthPoints)
        #expect(length.subject == ZPDFUIPresentation.MeasurementKind.length.displayName)

        let area = try await commit(.area, points: Self.areaPoints)
        #expect(area.subject == ZPDFUIPresentation.MeasurementKind.area.displayName)
    }

    @Test("A subject from the user or a tool preset always wins over the tool name")
    @MainActor
    func explicitSubjectWins() async throws {
        let record = try await commit(.length, points: Self.lengthPoints) { measurement in
            measurement.defaultSubject = "Yttervägg"
        }
        #expect(record.subject == "Yttervägg")
    }

    // MARK: Committed measurement ink

    @Test("Committed measurement ink is the binding measurement ink, not MarkupStyle.default's black")
    @MainActor
    func committedInkIsTheMeasurementCyan() async throws {
        let record = try await commit(.length, points: Self.lengthPoints)
        #expect(record.style.color == AppMeasurementToolPresenter.measurementInk)
        #expect(record.style.color != MarkupStyle.default.color,
                "the near-black default is exactly the defect this guards against")
        #expect(record.style.fill == nil, "an open length has no fill")
    }

    @Test("A closed area commits with a 20 % alpha fill of its stroke colour")
    @MainActor
    func closedAreasCarryTheLowAlphaFill() async throws {
        let record = try await commit(.area, points: Self.areaPoints)
        let fill = try #require(record.style.fill)
        let stroke = record.style.color
        #expect(fill.red == stroke.red && fill.green == stroke.green && fill.blue == stroke.blue)
        // 20 %: the default since 2026-09-23 (was 18 %).
        #expect(abs(fill.alpha - 0.20) < 0.001)
        #expect(stroke == AppMeasurementToolPresenter.measurementInk)
    }

    @Test("A preset colour overrides the ink, and the fill follows the preset")
    @MainActor
    func presetColourWinsAndFillFollows() async throws {
        let orange = RGBAColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1)
        let record = try await commit(.area, points: Self.areaPoints) { measurement in
            measurement.color = orange
        }
        #expect(record.style.color == orange)
        let fill = try #require(record.style.fill)
        #expect(fill.red == orange.red && abs(fill.alpha - 0.20) < 0.001)
    }
}

/// The author identity — machine default, user choice, and the append-only consequence
/// that a change signs only what comes after it.
@Suite("Author identity", .serialized)
struct AuthorIdentityTests {

    /// Runs `body` with AuthorIdentity pointed at a scratch defaults suite, and always
    /// restores the standard one.
    ///
    /// **The suite name is fixed, not a UUID.** `cfprefsd` owns a named
    /// domain the moment it is asked for one and writes its plist into
    /// `~/Library/Preferences` whether or not a key is ever stored; `removePersistentDomain`
    /// empties the domain and leaves the file, and deleting the file loses a race the daemon
    /// always wins. A UUID per call therefore left one plist per test per run behind, and on
    /// a development machine they had accumulated into the thousands. This suite is
    /// `.serialized`, so
    /// one test holds the name at a time and the isolation the UUID was buying is already
    /// there. The domain is emptied on entry as well as on exit, because a run that died
    /// before its `defer` must not be inherited: state left by one run must never leak into
    /// the next.
    @MainActor
    private func withScratchDefaults(_ body: @MainActor () async throws -> Void) async throws {
        let suiteName = "zenit-author-tests.scratch"
        let scratch = try #require(
            UserDefaults(suiteName: suiteName),
            "a scratch suite must never fall back to UserDefaults.standard"
        )
        scratch.removePersistentDomain(forName: suiteName)
        let previous = AuthorIdentity.defaults
        AuthorIdentity.defaults = scratch
        defer {
            AuthorIdentity.defaults = previous
            scratch.removePersistentDomain(forName: suiteName)
            scratch.synchronize()
        }
        try await body()
    }

    @Test("The default is the account's full name — never a literal in source")
    @MainActor
    func defaultComesFromTheMachine() async throws {
        try await withScratchDefaults {
            #expect(AuthorIdentity.current() == AuthorIdentity.machineDefault)
            #expect(!AuthorIdentity.current().isEmpty, "the short-name fallback guarantees non-empty")
        }
    }

    @Test("A chosen name wins; clearing or re-entering the machine name restores the default")
    @MainActor
    func chosenNameRoundTrips() async throws {
        try await withScratchDefaults {
            AuthorIdentity.set("  Alex Mätare  ")
            #expect(AuthorIdentity.current() == "Alex Mätare", "stored trimmed")
            AuthorIdentity.set("")
            #expect(AuthorIdentity.current() == AuthorIdentity.machineDefault)
            AuthorIdentity.set(AuthorIdentity.machineDefault)
            #expect(AuthorIdentity.defaults.string(forKey: AuthorIdentity.defaultsKey) == nil,
                    "choosing the machine name keeps tracking the account, not a frozen copy")
        }
    }

    @Test("The first-run prompt is owed exactly once, and skipping counts as answered")
    @MainActor
    func firstRunPromptIsAskedOnce() async throws {
        try await withScratchDefaults {
            #expect(AuthorIdentity.needsFirstRunPrompt)
            AuthorIdentity.markPrompted()
            #expect(!AuthorIdentity.needsFirstRunPrompt)
        }
    }

    @Test("Changing the name signs the next entry, not the previous ones")
    @MainActor
    func changeAffectsNewEntriesOnly() async throws {
        try await withScratchDefaults {
            let documentID = DocumentID(UUID())
            let page = ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: 0,
                label: "A-101",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
            )
            let session = try TakeoffSession(documentID: documentID, pages: [page])
            let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zenit-author-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try await ProjectDatabaseActor.open(
                at: directory.appendingPathComponent("history.sqlite")
            )
            environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)

            AuthorIdentity.set("First Author")
            try await environment.commands.calibrate(
                page: page.id,
                first: PDFPoint(x: 0, y: 0),
                second: PDFPoint(x: 100, y: 0),
                knownLength: 10,
                knownLengthUnit: .metre
            )
            await environment.history.settle()

            AuthorIdentity.set("Second Author")
            try await environment.commands.calibrate(
                page: page.id,
                first: PDFPoint(x: 0, y: 0),
                second: PDFPoint(x: 200, y: 0),
                knownLength: 10,
                knownLengthUnit: .metre
            )
            await environment.history.settle()

            let actors = environment.history.events.map(\.actor)
            #expect(actors == ["First Author", "Second Author"],
                    "append-only: past rows keep the name that made them — got \(actors)")
            await database.closeForTesting()
        }
    }
}

/// History rows read like sentences — localized field names and
/// display-precision values with units come from the same formatting layer as the
/// ledger, while the raw canonical values stay untouched for the derivation disclosure.
@Suite("History display formatting")
struct HistoryDisplayFormattingTests {

    @Test("A recorded change carries 'Plan Area' and '… m²', never camelCase or 14 decimals")
    @MainActor
    func changesCarryLedgerFormattedDisplayStrings() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-display-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("history.sqlite")
        )
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)

        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let record = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: page.id,
            kind: .measurement,
            tool: .area,
            subject: "Slab",
            author: "test",
            geometry: MeasurementGeometry(
                pageID: page.id,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0),
                    PDFPoint(x: 100, y: 0),
                    PDFPoint(x: 100, y: 80),
                    PDFPoint(x: 0, y: 80)
                ], isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
        try await environment.commands.perform(.addMarkup(record))
        await environment.history.settle()

        let created = try #require(environment.history.events.last)
        #expect(created.action == "markup_created")
        #expect(!created.changes.isEmpty)

        // ADR-0021: a creation also records the review fields (status, subject…),
        // which are words, not measured values; this test is about the measured ones.
        for change in created.changes where !change.field.hasPrefix("review.") {
            let name = try #require(change.fieldDisplayName,
                                    "\(change.field) has no display name")
            #expect(name == ZPDFUIPresentation.MeasurementField(rawValue: change.field)?.displayName)
            #expect(!name.contains("planArea") && !name.contains("netArea"),
                    "camelCase leaked into the display name: \(name)")
            #expect(change.beforeDisplay == nil, "created from nothing")
            let display = try #require(change.afterDisplay,
                                       "\(change.field) has no display value")
            // Display precision, not the canonical value's full precision: the raw text
            // stays in `after`, the sentence shows the ledger's rendering.
            #expect(change.after != nil)
            let digits = display.filter(\.isNumber)
            #expect(digits.count < 10, "display value looks unrounded: \(display)")
        }
        // The area fields render in the ledger's area unit.
        let area = try #require(created.changes.first { $0.field == "planArea" })
        #expect(area.afterDisplay?.hasSuffix("m²") == true,
                "expected a unit-carrying display value, got \(area.afterDisplay ?? "nil")")

        await database.closeForTesting()
    }
}

private extension ProjectDatabaseActor {
    /// Closes without making the test care about the throwing signature.
    func closeForTesting() async {
        try? await close()
    }
}
