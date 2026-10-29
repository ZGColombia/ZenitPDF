import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The shell's half of two fixes: Reuse Tool honoured by the measurement family, and the tool
/// options strip that asks for a value the drawing does not contain.
///
/// The app package proves the behaviour end to end against the real presenters; these
/// pin the shell's own contract against the mocks, which is where a future change to the
/// command routing would break it first.
@MainActor
@Suite("Tool options and reuse tool", .shellTierSerialised)
struct ToolOptionsAndReuseTests {

    private func makeEnvironment() -> (ProjectShellEnvironment, MockToolLibraryPresenter) {
        let mocks = MockPresenters.makeEnvironment()
        let environment = ProjectShellEnvironment(
            document: mocks.document,
            canvas: mocks.canvas,
            ledger: mocks.ledger,
            toolLibrary: mocks.toolLibrary,
            search: mocks.search,
            compare: mocks.compare,
            measurement: mocks.measurement,
            status: mocks.status
        )
        return (environment, mocks.toolLibrary)
    }

    // MARK: - Reuse Tool

    @Test("Finishing a measurement asks the Tool Library whether the tool stays armed")
    func finishGeometryConsultsTheSingleDecision() {
        let (environment, library) = makeEnvironment()
        library.setReuseToolEnabled(false)
        environment.perform(.measureLength)
        environment.measurement.placePoint(PDFPointValue(x: 0, y: 0))
        environment.measurement.placePoint(PDFPointValue(x: 100, y: 0))
        #expect(environment.measurement.canCommit)

        let before = library.markupCommittedCount
        environment.perform(.finishGeometry)
        #expect(library.markupCommittedCount == before + 1,
                "the measurement family must ask, not decide for itself")
        #expect(environment.toolbar.activeSelection.mode == .select,
                "Reuse Tool is off, so the toolbar returns to Select")
        #expect(environment.measurement.activeKind == nil)
    }

    @Test("With Reuse Tool on the same finish leaves the tool armed")
    func finishGeometryKeepsTheToolWhenReuseIsOn() {
        let (environment, library) = makeEnvironment()
        library.setReuseToolEnabled(true)
        environment.perform(.measureLength)
        environment.measurement.placePoint(PDFPointValue(x: 0, y: 0))
        environment.measurement.placePoint(PDFPointValue(x: 100, y: 0))

        environment.perform(.finishGeometry)
        #expect(environment.toolbar.activeSelection.mode == .measure(.length))
        #expect(environment.measurement.activeKind == .length)
    }

    @Test("A finish with nothing to finish asks nothing and disarms nothing")
    func finishGeometryWithoutACommitChangesNothing() {
        let (environment, library) = makeEnvironment()
        library.setReuseToolEnabled(false)
        environment.perform(.measureLength)
        environment.measurement.placePoint(PDFPointValue(x: 0, y: 0))
        #expect(!environment.measurement.canCommit)

        let before = library.markupCommittedCount
        environment.perform(.finishGeometry)
        #expect(library.markupCommittedCount == before,
                "an empty Finish is not a commit and must not consume the reuse decision")
        #expect(environment.toolbar.activeSelection.mode == .measure(.length))
    }

    // MARK: - The tool options strip

    @Test("The tool options strip appears for exactly the tools that need a value")
    func theOptionsStripFollowsTheArmedTool() {
        let (environment, _) = makeEnvironment()
        let layout = ProjectWindowLayoutController(
            environment: environment,
            store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: "test.layout")
        )
        _ = layout.view
        #expect(!layout.isToolOptionsBarVisible, "a window opens in Select and asks nothing")

        environment.toolbar.activateMeasurement(.length)
        #expect(!layout.isToolOptionsBarVisible, "Length measures what is drawn")

        environment.toolbar.activateMeasurement(.volume)
        #expect(layout.isToolOptionsBarVisible,
                "Volume needs a depth, and the strip is where it is asked for")

        environment.toolbar.selectTool(.select)
        #expect(!layout.isToolOptionsBarVisible, "and it gets out of the way again")
    }

    @Test("Typing a value clears the status bar's request for it")
    func typingTheValueClearsTheRequest() {
        let (environment, _) = makeEnvironment()
        environment.toolbar.activateMeasurement(.wallArea)
        #expect(environment.measurement.requiredParameter == .wallHeight)
        #expect(environment.status.snapshot.activeToolNote
                == MeasurementParameterRequirement.wallHeight.missingValueNote)

        environment.setMeasurementParameterText("2.4")
        #expect(environment.measurement.parameterValue != nil)
        #expect(environment.status.snapshot.activeToolNote == nil,
                "the bar must stop asking for a value it has been given")

        environment.setMeasurementParameterText("")
        #expect(environment.status.snapshot.activeToolNote != nil,
                "and start asking again if it is cleared")
    }

    // MARK: - CR-104

    /// CR-104 — a refusal outlived the measurement that succeeded after it.
    ///
    /// With Reuse Tool ON the tool stays armed, so nothing calls `arm` and nothing fires
    /// `onSelectionChange`, which is the only thing that used to rewrite the status line. The
    /// note left by the last refused Finish — "Area needs 3 more points…" — sat under a
    /// measurement that had just been committed, for as long as the estimator kept measuring.
    /// Old output, against the code before the fix:
    ///
    /// ```
    /// ✘ Test "A successful finish clears the last refusal, with Reuse Tool on" recorded an
    ///   issue at ToolOptionsAndReuseTests.swift:156:9: Expectation failed:
    ///   (environment.status.snapshot.activeToolNote
    ///   → "Area needs 2 more points before it can be finished.") == nil
    /// ```
    @Test("A successful finish clears the last refusal, with Reuse Tool on")
    func aSuccessfulFinishClearsTheRefusalNote() throws {
        let (environment, library) = makeEnvironment()
        library.setReuseToolEnabled(true)
        environment.perform(.measureArea)

        // A Finish with too few points: refused, out loud.
        environment.measurement.placePoint(PDFPointValue(x: 0, y: 0))
        #expect(!environment.measurement.canCommit)
        environment.perform(.finishGeometry)
        let refusal = try #require(environment.status.snapshot.activeToolNote)
        #expect(!refusal.isEmpty)

        // The same tool, enough points this time.
        environment.measurement.placePoint(PDFPointValue(x: 100, y: 0))
        environment.measurement.placePoint(PDFPointValue(x: 100, y: 100))
        #expect(environment.measurement.canCommit)
        environment.perform(.finishGeometry)

        #expect(environment.toolbar.activeSelection.mode == .measure(.area), "Reuse Tool is on")
        #expect(
            environment.status.snapshot.activeToolNote == nil,
            "a refusal from the previous attempt is still on the bar after a successful Finish"
        )
        #expect(environment.status.snapshot.activeToolName == ZenitToolMode.measure(.area).displayName)
    }

    @Test("A successful finish with Reuse Tool off also leaves no refusal behind")
    func disarmingAlsoClearsTheRefusalNote() throws {
        let (environment, library) = makeEnvironment()
        library.setReuseToolEnabled(false)
        environment.perform(.measureArea)

        environment.measurement.placePoint(PDFPointValue(x: 0, y: 0))
        environment.perform(.finishGeometry)
        #expect(environment.status.snapshot.activeToolNote != nil)

        environment.measurement.placePoint(PDFPointValue(x: 100, y: 0))
        environment.measurement.placePoint(PDFPointValue(x: 100, y: 100))
        environment.perform(.finishGeometry)

        #expect(environment.toolbar.activeSelection.mode == .select)
        #expect(environment.status.snapshot.activeToolNote == nil)
    }

    @Test("A refused finish still says why, and the note survives until the next outcome")
    func aRefusedFinishStillSpeaks() throws {
        let (environment, library) = makeEnvironment()
        library.setReuseToolEnabled(true)
        environment.perform(.measureArea)
        environment.measurement.placePoint(PDFPointValue(x: 0, y: 0))

        environment.perform(.finishGeometry)
        let note = try #require(environment.status.snapshot.activeToolNote)
        #expect(note == environment.measurement.commitRefusalReason
                || environment.measurement.commitRefusalReason == nil)
        #expect(!note.isEmpty, "Return doing nothing with nothing said is the silent-commit defect")
    }

    @Test("No measurement tool still claims it cannot be given its parameters")
    func noToolClaimsTheOldLimitation() {
        for kind in MeasurementKind.allCases where kind.requiredParameter != nil {
            #expect(ZenitToolMode.measure(kind).limitationNote == nil,
                    "\(kind.rawValue) can be given its value now; a stale note is a lie")
        }
    }
}
