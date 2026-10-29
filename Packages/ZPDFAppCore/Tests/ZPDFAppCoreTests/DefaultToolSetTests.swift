import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// The set a fresh installation opens with — a default set worth shipping, so the feature is
/// useful on first launch rather than empty.
///
/// **Why this file exists.** A verification pass on 2026-08-25 went looking for the named test
/// behind that clause and found none: `DefaultToolSet.seeding(_:)` and `isSeeded(in:)` had no
/// caller in any test in the repository, and the only assertion about the shipped set anywhere
/// was an incidental `presets.count == DefaultToolSet.presets.count` inside a *persistence*
/// test. The set therefore existed, was seeded by the shipping document, and was proved by
/// nothing. "Exists" and "is usable" are two claims and both are made here.
///
/// | Rule | Test |
/// |---|---|
/// | The set exists, six presets, stable identity | ``theShippedSetIsSixPresetsWithStableDistinctIdentities()`` |
/// | Each carries the parameter that justifies it | ``everyShippedPresetCarriesTheMathsThatJustifiesIt()`` |
/// | Seeding an empty library produces them in panel order | ``seedingAnEmptyLibraryProducesTheSixInPanelOrder()`` |
/// | Seeding is safe on every open | ``seedingIsIdempotent()`` |
/// | A deleted built-in stays deleted | ``aDeletedBuiltInIsNotPutBackWhileAnotherRemains()`` |
/// | **Usable**: a shipped preset arms the canvas with its maths | ``aShippedPresetArmsTheCanvasWithItsStoredMaths()`` |
/// | The one case the rule does not hold | ``deletingAllSixBringsThemBack()`` |
@Suite("The shipped tool set")
struct DefaultToolSetTests {

    // MARK: - It exists

    @Test("The shipped set is six presets with stable, distinct, non-degenerate identities")
    func theShippedSetIsSixPresetsWithStableDistinctIdentities() {
        let presets = DefaultToolSet.presets
        #expect(presets.count == 6)

        // Distinct, so no two rows in the panel are the same tool.
        #expect(Set(presets.map(\.id)).count == 6)

        // Stable across launches: reading the property twice must not mint new identities, or
        // a project that recorded which preset measured a wall points at a preset that has
        // ceased to exist.
        #expect(DefaultToolSet.presets.map(\.id) == presets.map(\.id))

        // `preset(id:…)` falls back to the all-zero UUID when a constant will not parse — the
        // no-`fatalError` rule. A zero here would mean a typo shipped as a tool.
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        #expect(presets.allSatisfy { $0.id != zero }, "a built-in identity failed to parse")

        // Where they came from is visible: every preset records its provenance.
        #expect(presets.allSatisfy { $0.provenance.origin == .builtIn })
        #expect(presets.allSatisfy { $0.category == DefaultToolSet.category })
        #expect(presets.allSatisfy { $0.panel == .myTools })
        // Nothing marks them read-only: the estimator's first act is to change the wall height.
        #expect(presets.allSatisfy { !$0.isReadOnly })
    }

    @Test("Every shipped preset carries the maths that justifies it, not only the ink")
    func everyShippedPresetCarriesTheMathsThatJustifiesIt() throws {
        func preset(_ name: String) throws -> ToolPresetSummary {
            try #require(DefaultToolSet.presets.first { $0.name == name }, "no preset named \(name)")
        }

        let exterior = try preset("Exterior Wall")
        #expect(exterior.measurementKind == .wallArea)
        #expect(exterior.measurementDefaults.wallHeight?.value == Decimal(string: "2.7"))

        let interior = try preset("Interior Wall")
        #expect(interior.measurementKind == .wallArea)
        #expect(interior.measurementDefaults.wallHeight?.value == Decimal(string: "2.4"))
        // The pair is the point: a preset is a decision, not a tool.
        #expect(exterior.measurementDefaults.wallHeight != interior.measurementDefaults.wallHeight)

        let slab = try preset("Slab 200 mm")
        #expect(slab.measurementKind == .volume)
        #expect(slab.measurementDefaults.depth?.value == Decimal(string: "0.2"))
        // ADR-0004 §2 refuses to default the reference, so the preset must carry it.
        #expect(slab.measurementDefaults.volumeDepthReference == .verticalDepth)

        let roof = try preset("Roof 6:12")
        #expect(roof.measurementKind == .trueSlopedArea)
        #expect(roof.measurementDefaults.slopePercent == 50)
        // ADR-0004 §1: a magnitude with no fall line is a slope the engine will refuse.
        #expect(roof.measurementDefaults.slopeAzimuthDegrees == 0)
        #expect(roof.measurementDefaults.slopeIsMissingAzimuth == false)

        for name in ["Door Count", "Column Count"] {
            let count = try preset(name)
            #expect(count.measurementKind == .count)
            #expect(count.markupKind == .count)
            #expect(count.countSymbolName?.isEmpty == false, "\(name) has no symbol")
        }
        // Two members in one category, so the panel opens with a group rather than a list.
        #expect(DefaultToolSet.presets.filter { $0.measurementKind == .count }.count == 2)
    }

    // MARK: - Seeding

    @Test("Seeding an empty library produces the six, in panel order, indexed from zero")
    func seedingAnEmptyLibraryProducesTheSixInPanelOrder() {
        #expect(DefaultToolSet.isSeeded(in: []) == false)
        let seeded = DefaultToolSet.seeding([])
        #expect(seeded.map(\.name) == DefaultToolSet.presets.map(\.name))
        #expect(seeded.map(\.sortIndex) == [0, 1, 2, 3, 4, 5])
        #expect(DefaultToolSet.isSeeded(in: seeded))
    }

    @Test("Seeding is safe on every open: the second call changes nothing")
    func seedingIsIdempotent() {
        let once = DefaultToolSet.seeding([])
        let twice = DefaultToolSet.seeding(once)
        #expect(twice.count == once.count)
        #expect(twice.map(\.id) == once.map(\.id))
        #expect(twice.map(\.sortIndex) == once.map(\.sortIndex))
    }

    @Test("A built-in the estimator deleted is not put back while another one remains")
    func aDeletedBuiltInIsNotPutBackWhileAnotherRemains() throws {
        var library = DefaultToolSet.seeding([])
        let slab = try #require(library.first { $0.name == "Slab 200 mm" })
        library.removeAll { $0.id == slab.id }
        #expect(library.count == 5)

        // Renaming one must not look like a missing one either — identity, not name.
        if let index = library.firstIndex(where: { $0.name == "Exterior Wall" }) {
            library[index].name = "Ytterväggar"
        }

        let after = DefaultToolSet.seeding(library)
        #expect(after.count == 5, "seeding put a deleted preset back")
        #expect(after.contains { $0.id == slab.id } == false)
    }

    /// The honest edge, recorded as a test rather than left for someone to discover.
    ///
    /// `isSeeded(in:)` asks whether *any* built-in identity is present, so a library the
    /// estimator emptied completely reads as one that has never been seeded, and the six come
    /// back on the next open — every open, for ever. `DefaultToolSet.seeding`'s own doc comment
    /// claims the opposite ("*an estimator who deleted all six … they said no*"). The comment is
    /// the intent and the code is the behaviour; this test pins the behaviour so the
    /// contradiction cannot be lost.
    @Test("Emptying the shipped set entirely brings it back on the next open")
    func deletingAllSixBringsThemBack() {
        let mine = ToolPresetSummary(
            id: UUID(),
            name: "My own",
            category: "Concrete",
            panel: .myTools,
            markupKind: .measurement,
            measurementKind: .area,
            colorRGBA: ColorRGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 1),
            defaultSubject: "Mine"
        )
        #expect(DefaultToolSet.isSeeded(in: [mine]) == false)
        let after = DefaultToolSet.seeding([mine])
        #expect(after.count == 7, "the six returned to a library that had deliberately none")
    }

    // MARK: - It is usable

    @Test("A shipped preset arms the canvas with its tool and its stored maths")
    @MainActor
    func aShippedPresetArmsTheCanvasWithItsStoredMaths() async throws {
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

        // The library exactly as a fresh installation has it — nothing hand-made.
        environment.toolLibrary.setPresets(DefaultToolSet.seeding([]))
        #expect(environment.toolLibrary.presets.count == 6)

        let slab = try #require(environment.toolLibrary.presets.first { $0.name == "Slab 200 mm" })
        environment.toolLibrary.activatePreset(id: slab.id)
        #expect(environment.toolLibrary.armedSetMode == .draw)
        #expect(environment.measurement.activeKind == .volume)
        let slabParameters = environment.measurement.parametersInEffect
        #expect(slabParameters.depth == .length(Decimal(string: "0.2") ?? 0))
        #expect(slabParameters.volumeDepthReference == .verticalDepth)

        // The roof is the one that proves the point: the pitch *and* the fall line arm too.
        let roof = try #require(environment.toolLibrary.presets.first { $0.name == "Roof 6:12" })
        environment.toolLibrary.activatePreset(id: roof.id)
        #expect(environment.measurement.activeKind == .trueSlopedArea)
        let roofParameters = environment.measurement.parametersInEffect
        #expect(roofParameters.slope.mode == .uniformPlane)
        #expect(roofParameters.slope.azimuth?.degrees == 0)
        let magnitude = try #require(roofParameters.slope.magnitude)
        #expect(try magnitude.percentValue() == 50)

        // And a Count preset arms the Count tool, which is what Place mode drops.
        let door = try #require(environment.toolLibrary.presets.first { $0.name == "Door Count" })
        environment.toolLibrary.activatePreset(id: door.id)
        #expect(environment.measurement.activeKind == .count)
    }
}

/// NL-PDF-22: the stock review stamps.
@Suite("The shipped review stamps")
struct ReviewStampSetTests {

    @Test("Six review stamps with stable identities, each a stamp with date, reviewer and sheet fields")
    func sixStampsWithFields() {
        let stamps = DefaultToolSet.reviewStamps
        #expect(stamps.count == 6)
        #expect(Set(stamps.map(\.id)).count == 6)
        #expect(DefaultToolSet.reviewStamps.map(\.id) == stamps.map(\.id), "identities are constants")
        #expect(Set(stamps.map(\.id)).isDisjoint(with: Set(DefaultToolSet.presets.map(\.id))))
        for stamp in stamps {
            #expect(stamp.markupKind == .stamp)
            #expect(stamp.provenance.origin == .builtIn)
            let template = try? #require(stamp.stamp)
            #expect(template?.fields.map(\.kind) == [.date, .author, .pageLabel])
            #expect(template?.placementPrompts.isEmpty == true, "a review stamp asks nothing when placed")
        }
        #expect(stamps.map(\.name) == ["Reviewed", "Approved", "Approved as Noted", "Revise and Resubmit", "Rejected", "For Information"])
    }

    @Test("Review stamps seed once by their own identity, also into a library that already has the tools")
    func seedingIsIndependentAndOnce() {
        let tools = DefaultToolSet.seeding([])
        let both = DefaultToolSet.seedingReviewStamps(tools)
        #expect(both.count == 12)
        #expect(DefaultToolSet.seedingReviewStamps(both).count == 12, "seeding twice adds nothing")
        // A person who deleted five of the six keeps it that way.
        let kept = both.filter { $0.name != "Approved" || $0.category != DefaultToolSet.reviewCategory }
            .filter { !DefaultToolSet.reviewStamps.dropFirst().map(\.id).contains($0.id) }
        #expect(DefaultToolSet.seedingReviewStamps(kept).count == kept.count)
    }

    @Test("A placed review stamp freezes its wording, date, reviewer and sheet")
    @MainActor
    func placedStampResolves() async throws {
        let (environment, _, _) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 2)
        let approved = try #require(DefaultToolSet.reviewStamps.first { $0.name == "Approved" })
        let producer = try #require(environment.stampBatchProducer(
            for: approved, now: StampAndBatchApplyTests.placementInstant, author: "Reviewer"
        ))
        _ = await environment.runBatchApply(producer, plan: environment.planBatchApply(
            producer, request: BatchApplyRequest(scope: .allPages, anchor: .corner(.bottomRight, insetX: 36, insetY: 36))
        ))
        await environment.refresh()
        let first = try #require(await environment.session.orderedMarkups.first)
        let lines = first.stamp?.fields.map(\.resolvedText) ?? []
        #expect(lines.contains("APPROVED · 2026-08-25"))
        #expect(lines.contains("By Reviewer"))
        #expect(lines.contains { $0.hasPrefix("Sheet A-00") })
    }
}
