import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Tools ▸ Batch Stamp… — the application-tier join.
///
/// The point of an app-tier test here is the lesson of earlier wiring defects: the
/// engine, the model and the sheet were each provably correct on their own while nothing in
/// the product connected them. So nothing below builds a `BatchApplyModel` and wires its own
/// hooks — every test reaches the hooks only through the model
/// `ProjectWindowController.makeBatchApplyModel(for:)` returns, which is the exact object
/// `presentBatchApply(for:)` puts in the sheet.
///
/// **No sheet is opened here, on purpose.** No test may put a window on screen, and `NSWindow.beginSheet` in a headless test process hangs waiting for a run loop
/// nobody pumps — measured on this file before it was split. The wiring is a value; the window
/// is a shell around it; this tests the value.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct BatchStampWiringTests {

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    /// One A1 sheet with a real content stream.
    ///
    /// **One page, and not by preference.** The first draft was three mixed-size sheets, so the
    /// anchoring claim could be made at this tier too. It never finished: adding a markup to a
    /// multi-page document spins `NavigatorPageThumbnail` in a SwiftUI update loop at 99 % CPU
    /// indefinitely, and it does so for a plain rectangle as readily as for a stamp —
    /// isolated with a probe before this test was reduced. That defect has its own regression
    /// guard (`MultiPageWindowProbeTests`) rather than a silent workaround; the batch's own claims are proved over 312
    /// mixed-size pages in `ZPDFAppCoreTests/StampAndBatchApplyTests`, which needs no window.
    private func writeMixedSizePDF() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-batchstamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Set A.pdf")

        let boxes = ["[0 0 2384 1684]"]
        let kids = (0..<boxes.count).map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [\(kids)] /Count \(boxes.count) >>".utf8)
        ]
        for (index, box) in boxes.enumerated() {
            let contentsRef = 4 + index * 2
            objects.append(Data("""
            << /Type /Page /Parent 2 0 R /MediaBox \(box) /Contents \(contentsRef) 0 R >>
            """.utf8))
            let content = Data("0 0 1 RG 4 w 100 100 m 800 600 l S\n".utf8)
            var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
            stream.append(content)
            stream.append(Data("\nendstream".utf8))
            objects.append(stream)
        }

        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data("""
        trailer
        << /Size \(objects.count + 1) /Root 1 0 R >>
        startxref
        \(xref)
        %%EOF
        """.utf8))
        try bytes.write(to: url)
        return url
    }

    private func stampPreset() -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: "Reviewed",
            category: "Review",
            panel: .myTools,
            markupKind: .stamp,
            colorRGBA: ColorRGBA(red: 0.8, green: 0.1, blue: 0.1),
            defaultSubject: "Review",
            stamp: StampTemplate(
                id: UUID(),
                widthPoints: 160,
                heightPoints: 60,
                fields: [
                    StampFieldDefinition(kind: .date, dateFormat: "yyyy-MM-dd"),
                    StampFieldDefinition(kind: .pageLabel),
                    StampFieldDefinition(kind: .freeText, prompt: "Note")
                ]
            )
        )
    }

    @discardableResult
    /// A fresh personal tool library for this test (sweep 7, 2026-09-26). The Batch Stamp sheet arms the person's own
    /// stamp preset before the shipped review stamps, and the process-wide test container keeps every preset an
    /// earlier suite saved, so in a full run this test armed another suite's stamp and saw no prompt. Returns the
    /// restore step.
    private func isolateToolLibrary() -> () -> Void {
        let previous = ZenitPDFProjectDocument.toolPresetContainerOverride
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-batchstamp-tools-\(UUID().uuidString)", isDirectory: true)
        ZenitPDFProjectDocument.toolPresetContainerOverride = ToolPresetContainerStore(directory: folder)
        return {
            ZenitPDFProjectDocument.toolPresetContainerOverride = previous
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func openWindow(
        on url: URL
    ) async throws -> (document: ZenitPDFProjectDocument, controller: ProjectWindowController) {
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await wait { controller.contentViewController is ProjectWindowLayoutController })
        #expect(await wait { document.core != nil && document.shell != nil })
        controller.window?.layoutIfNeeded()
        return (document, controller)
    }

    @Test("Tools ▸ Batch Stamp… wires the sheet to the engine, places, and undoes as one")
    func batchStampFromTheMenuPlacesAndUndoesAsOne() async throws {
        let restoreToolLibrary = isolateToolLibrary()
        defer { restoreToolLibrary() }
        let url = try writeMixedSizePDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (document, controller) = try await openWindow(on: url)
        // Cleared before closing: these tests commit markups, so the document is dirty, and
        // `close()` on a dirty document reaches `presentUnsavedTakeoffAlert` and waits for an
        // answer nobody is there to give. That is how this file first wedged the app gate for
        // 600 s in `TabbedWindowTests`, one suite later, on the shared document controller.
        defer {
            document.updateChangeCount(.changeCleared)
            document.close()
        }

        let core = try #require(document.core)
        let preset = stampPreset()
        core.toolLibrary.setPresets(core.toolLibrary.presets + [preset])
        #expect(core.snapshot.pages.count == 1)

        // The join under test: the model the window controller builds, with the hooks it
        // installed. Nothing here assigns one, and nothing here opens a window.
        let wired = try #require(controller.makeBatchApplyModel(for: document))
        let model = wired.model

        #expect(model.onPlan != nil, "nothing installed the planner")
        #expect(model.onRun != nil, "nothing installed the runner")
        #expect(model.onCancel != nil, "nothing installed cancel")
        #expect(model.placementPrompt == "Note", "the template's prompt reached the sheet")

        // Nothing runs before a count has been shown.
        #expect(model.canApply == false)
        model.promptedText = "Checked"
        model.preview()
        let plan = try #require(model.plan)
        #expect(plan.placementCount == 1)
        #expect(model.previewSentence.contains("1"))
        #expect(model.canApply)

        await model.run()
        #expect(await wait { core.snapshot.markups.count == 1 })

        let stamped = core.snapshot.markups
        #expect(stamped.allSatisfy { $0.stampTemplateID == preset.stamp?.id })
        // Anchored inside the sheet, top-right (L-58: clear of the title block) with the 36 pt
        // inset the sheet opens with.
        let page = try #require(core.snapshot.pages.first)
        let placed = try #require(stamped.first)
        #expect(placed.boundsInPageSpace.maxX <= page.visibleBox.maxX)
        #expect(placed.boundsInPageSpace.minY >= page.visibleBox.minY)

        // One step on the document's own undo stack — the same ⌘Z the Edit menu sends.
        let undoManager = try #require(document.undoManager)
        #expect(undoManager.canUndo)
        await core.commands.undo()
        await core.refresh()
        #expect(core.snapshot.markups.isEmpty, "one Undo removes all of them")
    }

    @Test("Batch Stamp is offered only when there is a stamp preset and a page")
    func menuValidationRefusesWhenThereIsNothingToStamp() async throws {
        let restoreToolLibrary = isolateToolLibrary()
        defer { restoreToolLibrary() }
        let url = try writeMixedSizePDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (document, controller) = try await openWindow(on: url)
        // Cleared before closing: these tests commit markups, so the document is dirty, and
        // `close()` on a dirty document reaches `presentUnsavedTakeoffAlert` and waits for an
        // answer nobody is there to give. That is how this file first wedged the app gate for
        // 600 s in `TabbedWindowTests`, one suite later, on the shared document controller.
        defer {
            document.updateChangeCount(.changeCleared)
            document.close()
        }

        let core = try #require(document.core)
        let item = NSMenuItem(
            title: "Batch Stamp…",
            action: #selector(ProjectWindowController.performZenitCommand(_:)),
            keyEquivalent: ""
        )
        item.representedObject = ZenitAppCommand.batchApply.rawValue

        // No stamp preset in the library yet: the sheet would be a dead end with a scope
        // picker on it, so the item is disabled and presenting refuses.
        core.toolLibrary.setPresets(core.toolLibrary.presets.filter { $0.stamp == nil })
        #expect(controller.validateMenuItem(item) == false)
        #expect(controller.makeBatchApplyModel(for: document) == nil)

        core.toolLibrary.setPresets(core.toolLibrary.presets + [stampPreset()])
        #expect(controller.validateMenuItem(item))
    }
}
