import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// RT-9, retest of LT-12 (2026-08-31): activating View ▸ Coverage Map in the shipping build
/// still never showed a checkmark. This drives the REAL menu path: the item exactly as
/// ZenitMenuBar builds it, performed and then validated by the window controller.
@MainActor
@Suite(.appTierSerialised)
struct CoverageMapMenuTests {

    @Test("Toggling Coverage Map flips the presenter flag and the menu checkmark")
    func coverageToggleShowsInTheMenu() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Coverage.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        document.addWindowController(controller)
        let core = try #require(document.core)

        let item = NSMenuItem(
            title: "Coverage Map",
            action: #selector(ZenitCommandResponding.performZenitCommand(_:)),
            keyEquivalent: ""
        )
        item.representedObject = ZPDFCommandID.toggleCoverageMap.rawValue

        #expect(core.canvas.showsCoverageMap == false)
        controller.performZenitCommand(item)
        #expect(core.canvas.showsCoverageMap == true,
                "RT-9: the menu action never reached the presenter flag")

        _ = controller.validateMenuItem(item)
        #expect(item.state == .on, "RT-9: the checkmark is not set when the overlay is on")

        controller.performZenitCommand(item)
        _ = controller.validateMenuItem(item)
        #expect(core.canvas.showsCoverageMap == false)
        #expect(item.state == .off)
        document.close()
    }
}
