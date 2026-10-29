import AppKit
import Foundation
import Testing
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Found live, 2026-08-29: clicking a drawing in the Files list switched the navigator to the
/// Search page, when it should have stayed on Files. Each tab's layout
/// restores its own persisted navigator section when built, so fronting another tab yanked
/// the pane to whatever that tab had stored — Search, in the reported case. The rule now: the
/// navigator is one pane; a tab switch carries the visible section across, always.
@MainActor
@Suite(.appTierSerialised)
struct NavigatorSectionCarryTests {

    @Test("Switching tabs from the Files list keeps the navigator on Files")
    func tabSwitchCarriesTheVisibleSection() async throws {
        // This test moves the navigator to Files, Search and Zones, and a layout store persists
        // the section. Against the process store, every window any later test opened came up
        // on Zones — no page rows, so no Navigator thumbnail was ever requested, which is what
        // MultiPageWindowProbeTests timed out on whenever it ran after this suite. Its own
        // store, dropped at the end, keeps the section it leaves behind to itself.
        let previousStore = ZenitProcessDefaults.override
        ZenitProcessDefaults.override = ZenitScratchDefaults()
        defer {
            (ZenitProcessDefaults.override as? ZenitScratchDefaults)?.removeAll()
            ZenitProcessDefaults.override = previousStore
        }
        let firstURL = try AppTestSupport.writeFixturePDF(named: "CarryA.pdf")
        let secondURL = try AppTestSupport.writeFixturePDF(named: "CarryB.pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let first = try AppTestSupport.makeDocument(opening: firstURL)
        let controller = ProjectWindowController(document: first)
        #expect(await AppTestSupport.wait { first.shell != nil })
        first.addWindowController(controller)
        let second = try AppTestSupport.makeDocument(opening: secondURL)
        controller.attach(document: second)
        #expect(await AppTestSupport.wait { second.shell != nil })
        #expect(await AppTestSupport.wait {
            controller.canvasController(for: first) != nil
                && controller.canvasController(for: second) != nil
        })

        let firstLayout = try #require(controller.layoutController(for: first))
        let secondLayout = try #require(controller.layoutController(for: second))

        // The person is on Files in the front tab (second is active after attach) and the
        // background tab's layout claims Search — the exact shape of the report.
        secondLayout.panelState.navigatorSection = .drawings
        firstLayout.panelState.navigatorSection = .search

        controller.activateTab(id: first.documentIdentity)
        #expect(firstLayout.panelState.navigatorSection == .drawings,
                "a click in Files must land on a tab still showing Files, never Search")

        // And back, from any other section: the visible section always travels.
        firstLayout.panelState.navigatorSection = .zones
        controller.activateTab(id: second.documentIdentity)
        #expect(secondLayout.panelState.navigatorSection == .zones)

        first.close()
        second.close()
    }
}
