import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// `PDFCanvasViewController.reportSkips` — the sentence and the tray line a person actually
/// reads after a mixed Apply.
///
/// ### Why this file exists
///
/// The skip report was fixed at the producer: `AppToolPresetApply` builds a per-markup
/// `MarkupSkipReport`, and `ZPDFAppCoreTests/CountSymbolAndSkipReportTests` drives that over the
/// real command bus. What no tier tested was the last twenty lines — the ones that decide
/// **where the report goes**. `reportSkips` makes a routing choice that is a product decision,
/// not a formatting detail:
///
/// * **one** distinct answer stays in the status bar and nowhere else, because "12 markups
///   skipped Depth" is a complete report and a tray entry for it is noise;
/// * **two or more** distinct answers go to the warnings tray as one line each, because the
///   status bar has room for a sentence and not for a list, and a mixed selection is exactly
///   the case a single line cannot carry.
///
/// Get that backwards and nothing crashes and no package test notices: the estimator is simply
/// told that something was skipped and never which forty markups it was. So both branches are
/// asserted here, and both are reached the way a person reaches them — a click on the shipping
/// `PDFCanvasViewController` with a preset armed in Apply mode, never a call to the presenter.
/// `.serialized` as well as `.appTierSerialised`: both tests drive a real document through the
/// shipping canvas, and run in parallel they interleave on the main actor — the first attempt
/// had one test's clicks landing while the other's document was mid-draw, and neither drawing
/// committed. Serialised, each passes in about 0.16 s.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct PresetApplySkipReportTests {

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let canvas: PDFCanvasViewController
        let directory: URL
    }

    /// A loaded drawing calibrated at 100 pt = 1 m with the shipping canvas over it — the same
    /// harness `SelectAreaCutoutTests` uses, for the same reason: these are assertions about
    /// what the shipping canvas does with a click.
    private func makeHarness(named name: String) async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        var snap = await core.session.currentSnapSettings
        snap.enabledKinds = []
        try await core.session.setSnapSettings(snap)
        await core.refresh()
        let canvas = PDFCanvasViewController(
            core: core,
            rasterSource: document.drawing?.rasterSource,
            toolbar: shell.toolbar
        )
        _ = canvas.view
        canvas.onShellCommand = { command in
            guard command == .finishGeometry else {
                shell.perform(command)
                return
            }
            Task { @MainActor in
                await core.measurement.settlePlacements()
                core.measurement.commitActiveMeasurement()
            }
        }
        return Harness(
            document: document,
            core: core,
            shell: shell,
            canvas: canvas,
            directory: url.deletingLastPathComponent()
        )
    }

    private func settle(_ harness: Harness) async {
        await harness.core.refresh()
        harness.canvas.refresh()
        await harness.canvas.settleScene()
    }

    private func square(x: Double, y: Double, side: Double) -> [PDFPointValue] {
        [
            PDFPointValue(x: x, y: y),
            PDFPointValue(x: x + side, y: y),
            PDFPointValue(x: x + side, y: y + side),
            PDFPointValue(x: x, y: y + side)
        ]
    }

    private func drawArea(
        _ vertices: [PDFPointValue],
        _ harness: Harness,
        reaching expected: Int
    ) async {
        harness.core.canvas.clearSelection()
        harness.shell.perform(.measureArea)
        harness.canvas.refresh()
        for vertex in vertices {
            harness.canvas.handleClick(at: vertex, additive: false)
            await harness.core.measurement.settlePlacements()
        }
        harness.canvas.handleClick(at: vertices[0], additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(await wait { harness.core.snapshot.markups.count == expected },
                "area \(expected) did not commit: \(harness.core.snapshot.markups.count) markups")
        await settle(harness)
    }

    private func drawLength(
        from: PDFPointValue,
        to: PDFPointValue,
        _ harness: Harness,
        reaching expected: Int
    ) async {
        harness.core.canvas.clearSelection()
        harness.shell.perform(.measureLength)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: from, additive: false)
        await harness.core.measurement.settlePlacements()
        harness.canvas.handleClick(at: to, additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(await wait { harness.core.snapshot.markups.count == expected },
                "the length did not commit: \(harness.core.snapshot.markups.count) markups")
        await settle(harness)
    }

    /// "Slab 200 mm, cutouts reported": a Volume preset carrying a **depth** and a
    /// **non-default cutout policy**.
    ///
    /// The two properties are chosen so that two ordinary markups give two *different* answers,
    /// which is the whole case `reportSkips` routes on. An Area accepts a cutout policy (it has
    /// an area for a cutout to come out of) and refuses a depth (it is not a Volume), so it
    /// skips one property. A Length refuses both, so it skips two. One preset, one click, two
    /// distinct answers — and the status bar can carry only one of them.
    private static func slabPreset() -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: "Slab 200 mm",
            category: "Concrete",
            panel: .myTools,
            markupKind: .measurement,
            measurementKind: .volume,
            colorRGBA: ColorRGBA(red: 0.9, green: 0.7, blue: 0.2, alpha: 1),
            defaultSubject: "Slab",
            measurementDefaults: ToolPresetMeasurementDefaults(
                depth: .metres(Decimal(string: "0.2") ?? 0),
                cutoutPolicy: .subtractAndReportSeparately
            )
        )
    }

    /// Arms `preset` in Apply mode on the shipping tool library.
    ///
    /// **The caller must put the set back into Draw.** A set mode is written through
    /// `ToolSetModeStore`, which is a process-wide preference store, so a set left in Apply is
    /// inherited by every document opened afterwards in this process — and, before
    /// `ZenitPDFProjectDocument.processToolSetModeDefaults` existed, by every later run on the
    /// machine. This function is where `{"myTools":"apply"}` came from.
    private func armForApply(_ preset: ToolPresetSummary, _ harness: Harness) {
        harness.core.toolLibrary.setPresets([preset])
        harness.core.toolLibrary.setMode(.apply, for: preset.panel)
        harness.core.toolLibrary.activatePreset(id: preset.id)
        harness.canvas.refresh()
        #expect(harness.core.toolLibrary.armedSetMode == .apply)
        #expect(harness.core.toolLibrary.activePreset?.id == preset.id)
    }

    // MARK: - Two answers: the tray gets one line each

    @Test("A mixed Apply puts one tray line per distinct answer, and the preset's name on it")
    func aMixedApplyReportsEveryAnswerInTheTray() async throws {
        let harness = try await makeHarness(named: "Skip Report Mixed.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        // Two areas and a length, all drawn with the shipping tools.
        await drawArea(square(x: 400, y: 400, side: 100), harness, reaching: 1)
        await drawArea(square(x: 600, y: 400, side: 100), harness, reaching: 2)
        await drawLength(
            from: PDFPointValue(x: 400, y: 700),
            to: PDFPointValue(x: 500, y: 700),
            harness,
            reaching: 3
        )

        let records = await harness.core.session.orderedMarkups
        let areas = records.filter { $0.tool == .area }.map(\.id.rawValue)
        let length = try #require(records.first { $0.tool == .length }?.id.rawValue)
        #expect(areas.count == 2, "the fixture needs exactly two areas")

        // The selection the estimator gathered, and a click on one of its members.
        harness.core.canvas.select(markupIDs: Set(areas + [length]), additive: false)
        #expect(harness.core.canvas.selectedMarkupIDs.count == 3)

        let preset = Self.slabPreset()
        defer { harness.core.toolLibrary.setMode(.draw, for: preset.panel) }
        armForApply(preset, harness)
        #expect(harness.core.document.warnings.isEmpty, "nothing has been applied yet")

        // The shipping click. Not `applyPreset`, not `reportSkips`: the thing a mouse does.
        let clickInsideTheFirstArea = PDFPointValue(x: 450, y: 450)
        #expect(harness.canvas.hitTest(clickInsideTheFirstArea) == areas.first
                || harness.canvas.hitTest(clickInsideTheFirstArea) == areas.last,
                "the click has to land on a selected area for Apply to take the whole selection")
        harness.canvas.handleClick(at: clickInsideTheFirstArea, additive: false)

        #expect(
            await wait { !harness.core.document.warnings.isEmpty },
            "two distinct answers and no tray entry: the estimator cannot see which markup refused what"
        )
        let warning = try #require(harness.core.document.warnings.last)

        // Whose report it is. A tray with four entries in it is unreadable if none of them says
        // which action produced it.
        #expect(warning.title.contains(preset.name), "the tray line does not name the preset: \(warning.title)")
        #expect(warning.source == "Tool Library")
        #expect(warning.severity == .info, "a partial apply is information, not an error")
        #expect(warning.isDismissible)

        // One line per distinct answer, and the two answers really are different.
        let lines = warning.message.components(separatedBy: "\n")
        #expect(lines.count == 2, "expected one line per distinct answer, got \(lines)")
        #expect(Set(lines).count == 2, "two identical lines is the union defect back again: \(lines)")

        // The grouped line carries a count rather than repeating itself twice, and the odd
        // markup out keeps a line of its own naming the extra property it refused.
        let grouped = try #require(lines.first { $0.contains("2 markups") }, "no counted line in \(lines)")
        #expect(grouped.contains("Depth"), "the two areas skipped the depth: \(grouped)")
        #expect(grouped.contains("Cutout policy") == false,
                "an area accepts a cutout policy; it must not be reported as skipping one: \(grouped)")
        let odd = try #require(lines.first { $0.contains("1 markup ") }, "no single-markup line in \(lines)")
        #expect(odd.contains("Depth") && odd.contains("Cutout policy"),
                "the length refused both properties and the line must say both: \(odd)")

        // The status bar still gets its sentence. The tray is the *second* surface, not a
        // replacement for the first.
        let note = try #require(harness.core.status.snapshot.activeToolNote)
        #expect(note.contains("skipped"), "the status bar lost the summary: \(note)")

        print("--- 25.3: the two surfaces after a mixed Apply ---")
        print("  status bar: \(note)")
        print("  tray title: \(warning.title)")
        for line in lines { print("  tray line:  \(line)") }
    }

    // MARK: - One answer: the status bar, and nothing else

    @Test("One answer for every markup stays in the status bar and raises no tray entry")
    func oneAnswerIsASentenceAndNotATrayEntry() async throws {
        let harness = try await makeHarness(named: "Skip Report Uniform.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        await drawArea(square(x: 400, y: 400, side: 100), harness, reaching: 1)
        await drawArea(square(x: 600, y: 400, side: 100), harness, reaching: 2)

        let records = await harness.core.session.orderedMarkups
        let areas = records.map(\.id.rawValue)
        #expect(areas.count == 2)
        harness.core.canvas.select(markupIDs: Set(areas), additive: false)

        let preset = Self.slabPreset()
        defer { harness.core.toolLibrary.setMode(.draw, for: preset.panel) }
        armForApply(preset, harness)
        harness.canvas.handleClick(at: PDFPointValue(x: 450, y: 450), additive: false)

        // The apply really happened: the subject the preset carries is on both markups.
        #expect(await wait {
            harness.core.snapshot.markups.allSatisfy { $0.subject == preset.defaultSubject }
        }, "the click did not apply anything, so the branch below proves nothing")

        // …and it really did skip something, so this is the "one answer" case and not the
        // "nothing was skipped" case, which would make the assertion below vacuous.
        let note = try #require(harness.core.status.snapshot.activeToolNote)
        #expect(note.contains("skipped"), "nothing was skipped at all; the test is measuring the wrong branch: \(note)")
        #expect(note.contains("Depth"))

        #expect(
            harness.core.document.warnings.isEmpty,
            """
            one distinct answer raised a tray entry. "2 markups skipped Depth" is a complete \
            report and the status bar already carries it; a tray line repeating it is the \
            noise that makes a warnings tray worth ignoring. Tray: \
            \(harness.core.document.warnings.map(\.title))
            """
        )
        print("--- 25.3: one answer, one surface ---")
        print("  status bar: \(note)")
        print("  tray:       \(harness.core.document.warnings.count) entries")
    }
}
