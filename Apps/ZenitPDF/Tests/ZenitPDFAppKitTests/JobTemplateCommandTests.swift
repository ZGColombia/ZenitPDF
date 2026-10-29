import AppKit
import Foundation
import Testing
import ZPDFAppCore
@testable import ZenitPDFAppKit

/// Feature 18's menu commands, with every prompt injected — no sheet, no panel, no window
/// on screen. The capture/apply arithmetic itself is proven in ZPDFAppCore;
/// this suite pins the application flow: prompt → store → status, and back.
@MainActor
@Suite(.appTierSerialised)
struct JobTemplateCommandTests {

    @Test("Save captures the rig under the prompted name; Apply installs it back")
    func saveThenApplyRoundTrip() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Template.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)

        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)

        // Injected store and prompts: the test is the person.
        let storeDirectory = directory.appendingPathComponent("templates", isDirectory: true)
        let previousStore = ProjectWindowController.jobTemplateStore
        let previousName = ProjectWindowController.templateNamePrompt
        let previousPicker = ProjectWindowController.templatePicker
        defer {
            ProjectWindowController.jobTemplateStore = previousStore
            ProjectWindowController.templateNamePrompt = previousName
            ProjectWindowController.templatePicker = previousPicker
        }
        ProjectWindowController.jobTemplateStore = { JobTemplateStore(directory: storeDirectory) }
        ProjectWindowController.templateNamePrompt = { _ in "Villa Standard" }
        ProjectWindowController.templatePicker = { names, _, _ in
            names.firstIndex(of: "Villa Standard")
        }

        let presetCountBefore = core.toolLibrary.presets.count
        #expect(presetCountBefore > 0, "the fixture rig must have presets to capture")

        controller.saveJobTemplate(for: document)
        let store = JobTemplateStore(directory: storeDirectory)
        var storedTemplates: [JobTemplate] = []
        for _ in 0..<100 {
            storedTemplates = (try? await store.read()) ?? []
            if !storedTemplates.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(storedTemplates.count == 1, "the save command never reached the store")
        #expect(storedTemplates.first?.name == "Villa Standard")
        let stored = try #require(storedTemplates.first)
        #expect(stored.presets.count == presetCountBefore,
                "the template must carry the whole preset rig")

        // Apply is the same rig coming home — and the drawing's scale is nobody's to touch,
        // which the AppCore suite proves structurally (a template has no scale field at all).
        controller.applyJobTemplate(for: document)
        #expect(await AppTestSupport.wait {
            core.toolLibrary.presets.count == presetCountBefore
        })

        document.close()
    }
}
