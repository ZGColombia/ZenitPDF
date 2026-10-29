import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Reuse Tool and tool parameters, driven through the shipping controllers.
///
/// Two defects with one shape: an engine that was built and a UI that never called it.
/// `AppToolLibraryPresenter.markupCommitted()` — the documented single place the Reuse Tool
/// decision is made — had no caller, so the measurement family stayed armed with the switch
/// showing **Off**. `AppMeasurementToolPresenter.setParameters(_:)` had no caller either, so
/// Volume, Wall Area, Rise/Drop and the two true-sloped tools collected points, previewed,
/// and vanished on commit with nothing said.
@MainActor
@Suite(.appTierSerialised)
struct ReuseToolAndParameterTests {

    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let toolbar: ZenitToolbarModel
        let canvas: PDFCanvasViewController
        let directory: URL
    }

    private func makeHarness() async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: "TrackB.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let canvas = PDFCanvasViewController(
            core: core,
            rasterSource: document.drawing?.rasterSource,
            toolbar: shell.toolbar
        )
        _ = canvas.view
        canvas.onShellCommand = { [shell] command in shell.perform(command) }
        return Harness(
            document: document,
            core: core,
            shell: shell,
            toolbar: shell.toolbar,
            canvas: canvas,
            directory: url.deletingLastPathComponent()
        )
    }

    private func calibrate(_ harness: Harness) async throws {
        _ = try await harness.core.commands.calibrate(
            page: try #require(await harness.core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        await harness.core.refresh()
    }

    /// Finishes the measurement in progress and waits for the row to reach the ledger.
    ///
    /// The commit is asynchronous — it goes out through the command bus so it lands on the
    /// undo stack — so a synchronous assertion after `.finishGeometry` reads the ledger one
    /// turn too early.
    @discardableResult
    private func finish(_ harness: Harness, expectingRows rows: Int) async -> Bool {
        await harness.core.measurement.settlePlacements()
        harness.shell.perform(.finishGeometry)
        return await AppTestSupport.wait { harness.core.ledger.rowCount == rows }
    }

    // MARK: - 15.6 Reuse Tool

    /// Seen live on 2026-08-24: commit a Length, and the chip stayed lit
    /// with Reuse Tool showing Off.
    @Test("Reuse Tool off: a committed measurement returns the toolbar and the canvas to Select")
    func measurementDisarmsWhenReuseIsOff() async throws {
        let harness = try await makeHarness()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        try await calibrate(harness)
        harness.core.toolLibrary.setReuseToolEnabled(false)
        #expect(!harness.core.status.snapshot.reuseToolEnabled,
                "the status bar is where the estimator reads this, so it must agree")

        harness.shell.perform(.measureLength)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 300, y: 100), additive: false)
        #expect(await finish(harness, expectingRows: 1), "the measurement itself must still land")

        #expect(harness.core.measurement.activeKind == nil,
                "Reuse Tool is off, so the measurement family disarms like the markup family")
        #expect(harness.toolbar.activeTool == .select,
                "and the lit chip follows — a chip that stays lit over an unarmed canvas is 15.6")
        #expect(harness.core.status.snapshot.activeToolName == ZenitToolMode.select.displayName)
    }

    @Test("Reuse Tool on: the same commit leaves the tool armed for the next one")
    func measurementStaysArmedWhenReuseIsOn() async throws {
        let harness = try await makeHarness()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        try await calibrate(harness)
        harness.core.toolLibrary.setReuseToolEnabled(true)

        harness.shell.perform(.measureLength)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 300, y: 100), additive: false)
        #expect(await finish(harness, expectingRows: 1))
        #expect(harness.core.measurement.activeKind == .length,
                "an estimator taking twenty lengths must not re-arm between each")
        #expect(harness.toolbar.activeTool == .length)
        #expect(harness.core.measurement.placedPoints.isEmpty,
                "reused means armed and empty, never armed and still holding the last points")
    }

    /// A Finish with nothing to finish must not disarm the tool the estimator is holding.
    @Test("A Finish that commits nothing leaves the tool alone")
    func aRefusedFinishDoesNotDisarm() async throws {
        let harness = try await makeHarness()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        try await calibrate(harness)
        harness.core.toolLibrary.setReuseToolEnabled(false)

        harness.shell.perform(.measureLength)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(!harness.core.measurement.canCommit, "one point is not a length")
        harness.shell.perform(.finishGeometry)

        #expect(harness.core.measurement.activeKind == .length,
                "nothing was committed, so nothing may be disarmed")
        #expect(harness.core.ledger.rowCount == 0)
    }

    /// Both families ask the same question. The markup family already disarmed itself
    /// inline; the point of 15.6 is that the decision is now made in one place.
    @Test("Both tool families route their commit through markupCommitted()")
    func bothFamiliesHonourTheOneDecision() async throws {
        let harness = try await makeHarness()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        harness.core.toolLibrary.setReuseToolEnabled(false)

        harness.shell.perform(.shapesTool)
        harness.canvas.refresh()
        #expect(harness.canvas.armedMode == .markup(.rectangle))
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 200, y: 200), additive: false)
        harness.canvas.finishMarkup()
        #expect(harness.toolbar.activeTool == .select,
                "the markup family disarms through the same single decision")

        harness.core.toolLibrary.setReuseToolEnabled(true)
        harness.shell.perform(.shapesTool)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 200, y: 200), additive: false)
        harness.canvas.finishMarkup()
        #expect(harness.toolbar.activeTool == .shapes,
                "and stays armed when the switch says so, exactly as the measurement family does")
    }

    // MARK: - 15.3 The five parameter-hungry tools

    @Test("Every parameter-hungry tool names the value it wants, and only those six do")
    func theFiveToolsAreExactlyTheOnesTheEngineNames() {
        // Slope asks for its steepness since BH-052.
        let hungry: Set<MeasurementKind> = [.volume, .wallArea, .riseDrop, .trueSlopedLength, .trueSlopedArea, .slope]
        for kind in MeasurementKind.allCases {
            if hungry.contains(kind) {
                let requirement = kind.requiredParameter
                #expect(requirement != nil, "\(kind.rawValue) needs a value the drawing does not contain")
                #expect(requirement?.missingValueNote.isEmpty == false)
            } else {
                #expect(kind.requiredParameter == nil,
                        "\(kind.rawValue) measures what is drawn and must not ask for anything")
            }
            // The stale "cannot be entered yet" note must be gone: the maintenance rule on
            // `limitationNote` says finishing a tool means deleting its line.
            if hungry.contains(kind) {
                #expect(ZenitToolMode.measure(kind).limitationNote == nil,
                        "\(kind.rawValue) can be given its value now, so it must stop claiming otherwise")
            }
        }
    }

    @Test("Volume without a depth cannot be finished, and the status bar says which value is missing")
    func volumeAnnouncesItsMissingDepth() async throws {
        let harness = try await makeHarness()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        try await calibrate(harness)

        harness.toolbar.activateMeasurement(.volume)
        harness.canvas.refresh()
        #expect(harness.core.measurement.requiredParameter == .depth)
        #expect(harness.core.status.snapshot.activeToolNote == MeasurementParameterRequirement.depth.missingValueNote,
                "the status bar names the depth rather than apologising for the tool")

        for point in [
            PDFPointValue(x: 100, y: 100),
            PDFPointValue(x: 300, y: 100),
            PDFPointValue(x: 300, y: 250),
            PDFPointValue(x: 100, y: 250)
        ] {
            harness.canvas.handleClick(at: point, additive: false)
        }
        await harness.core.measurement.settlePlacements()
        #expect(!harness.core.measurement.canCommit,
                "Finish must be refused while the depth is missing, not accepted and dropped")

        harness.shell.perform(.finishGeometry)
        await harness.core.refresh()
        #expect(harness.core.ledger.rowCount == 0)
        #expect(harness.core.measurement.placedPoints.count == 4,
                "the refusal keeps the work: the estimator types a depth and finishes")
    }

    @Test("Volume with a depth is recorded, and the depth reaches the stored quantity")
    func volumeWithADepthIsRecorded() async throws {
        let harness = try await makeHarness()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        try await calibrate(harness)

        harness.toolbar.activateMeasurement(.volume)
        harness.canvas.refresh()
        // 300 × 150 page points at 30 m over 300 points = 30 m × 15 m = 450 m², × 0.2 m.
        for point in [
            PDFPointValue(x: 100, y: 100),
            PDFPointValue(x: 400, y: 100),
            PDFPointValue(x: 400, y: 250),
            PDFPointValue(x: 100, y: 250)
        ] {
            harness.canvas.handleClick(at: point, additive: false)
        }
        harness.shell.setMeasurementParameterText("0.2")
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.parameterValue == Decimal(string: "0.2"))
        #expect(harness.core.status.snapshot.activeToolNote == nil,
                "the value has been given, so the status bar stops asking for it")
        #expect(harness.core.measurement.canCommit,
                "with a depth the tool is complete and Finish must be offered")

        #expect(await finish(harness, expectingRows: 1),
                "the whole of 15.3: the tool used to collect points, preview, and vanish")
        let row = try #require(harness.core.ledger.row(at: 0))
        #expect(row.measurementKind == .volume)
        guard case .quantity(let volume) = try #require(row.values[.volume]),
              case .quantity(let planArea) = try #require(row.values[.planArea]) else {
            Issue.record("a volume row must carry a volume and the area it came from")
            return
        }
        // The number itself depends on where the snap engine put the corners, so the
        // assertion is the *relationship*: the stored volume is the stored area times the
        // depth that was typed. That is what proves the parameter reached the calculator
        // rather than being dropped on the way.
        #expect(volume.dimension.lengthPower == 3)
        #expect(planArea.value > 0)
        #expect(volume.value == planArea.value * Decimal(string: "0.2")!,
                "\(volume.value) must be \(planArea.value) × 0.2")
    }

    @Test("Wall Area takes a height, and a slope tool takes a percentage")
    func theOtherParameterHungryToolsAreRecordedToo() async throws {
        let harness = try await makeHarness()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        try await calibrate(harness)

        harness.toolbar.activateMeasurement(.wallArea)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 400, y: 100), additive: false)
        harness.shell.setMeasurementParameterText("2.4")
        #expect(await finish(harness, expectingRows: 1), "a wall area with a height is a real row")

        // A slope is a percentage, not a length, and True Sloped Length takes its fall line
        // from the run the estimator drew (ADR-0004 refuses a plane on a length without one).
        harness.toolbar.activateMeasurement(.trueSlopedLength)
        harness.canvas.refresh()
        #expect(harness.core.measurement.requiredParameter == .slopePercent)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 300), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 400, y: 300), additive: false)
        harness.shell.setMeasurementParameterText("30")
        #expect(await finish(harness, expectingRows: 2),
                "a true sloped length with a pitch is a real row, not a silent disappearance")
    }

    @Test("Switching tools remembers each tool's own value and never lends it to another")
    func eachToolKeepsItsOwnValue() async throws {
        let harness = try await makeHarness()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        harness.toolbar.activateMeasurement(.volume)
        harness.shell.setMeasurementParameterText("0.25")
        harness.toolbar.activateMeasurement(.wallArea)
        #expect(harness.core.measurement.parameterText.isEmpty,
                "a wall height must not inherit a slab depth")
        harness.shell.setMeasurementParameterText("2.7")
        harness.toolbar.activateMeasurement(.volume)
        #expect(harness.core.measurement.parameterText == "0.25",
                "re-arming a tool restores the value it was given")
        harness.toolbar.activateMeasurement(.length)
        #expect(harness.core.measurement.parameterText.isEmpty,
                "a tool that needs nothing shows nothing")
        #expect(harness.core.measurement.requiredParameter == nil)
    }

    // MARK: - 15.3 The swallowed error

    /// The second half of 15.3, and the more dangerous half: a calculator that throws must
    /// reach the user. It used to reach `try?` in `AppCoreEnvironment` and stop there.
    @Test("A commit the engine refuses is reported to the user, not swallowed")
    func aRefusedCommitReachesTheUser() async throws {
        let harness = try await makeHarness()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        try await calibrate(harness)
        #expect(harness.core.status.warnings.isEmpty)

        // A volume record with no depth: exactly what the product used to build, and what
        // `VolumeCalculator` refuses with `missingParameter(.depth)`. It is pushed through
        // the shipping commit closure, so the test exercises the wiring rather than a copy
        // of it.
        let square = [
            PDFPoint(x: 100, y: 100),
            PDFPoint(x: 400, y: 100),
            PDFPoint(x: 400, y: 250),
            PDFPoint(x: 100, y: 250)
        ]
        let pageID = try #require(harness.core.snapshot.pages.first?.id)
        let record = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: DocumentID(harness.core.snapshot.documentID),
            pageID: PageID(pageID),
            kind: .measurement,
            tool: .volume,
            subject: "Slab",
            label: "Volume Z",
            author: "",
            style: MarkupStyle(),
            geometry: MeasurementGeometry(
                pageID: PageID(pageID),
                polygons: [PolygonGeometry(outer: PolygonRing(points: square, isClosed: true))]
            ),
            parameters: .default,
            createdAt: Date(),
            modifiedAt: Date()
        )
        harness.core.measurement.onCommit?(record)

        #expect(await AppTestSupport.wait { !harness.core.status.warnings.isEmpty },
                "a calculator that throws must produce a warning, not a silent disappearance")
        let warning = try #require(harness.core.status.warnings.first)
        #expect(warning.severity == .danger)
        #expect(!warning.title.isEmpty)
        #expect(warning.message.contains("depth") || warning.message.contains("Parameter")
                || warning.message.contains("missingParameter"),
                "the reason must name what the engine objected to: \(warning.message)")
        #expect(harness.core.ledger.rowCount == 0, "and nothing may have been recorded")

        // A second identical refusal replaces the first rather than stacking repeats.
        harness.core.measurement.onCommit?(record)
        _ = await AppTestSupport.wait(upTo: 1) { harness.core.status.warnings.count > 1 }
        #expect(harness.core.status.warnings.count == 1)
    }
}
