import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The coverage map's View-menu toggle: command in, presenter flag flipped, menu state honest.
///
/// The overlay itself is drawn by the canvas host in the application tier; this suite pins the
/// shell half — that the command reaches the presenter and that the menu's check state reads
/// the same flag back, so the tick and the overlay can never disagree.
@MainActor
@Suite("Coverage map toggle", .shellTierSerialised)
struct CoverageToggleTests {

    private func makeEnvironment() -> (ProjectShellEnvironment, MockCanvasPresenter) {
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
        return (environment, mocks.canvas)
    }

    @Test("The command flips the presenter's flag, both ways")
    func commandTogglesTheFlag() {
        let (environment, canvas) = makeEnvironment()
        #expect(!canvas.showsCoverageMap, "the coverage map must start off — it is opt-in")

        environment.perform(.toggleCoverageMap)
        #expect(canvas.showsCoverageMap, "the command never reached the presenter")

        environment.perform(.toggleCoverageMap)
        #expect(!canvas.showsCoverageMap, "the second press must turn it back off")
    }

    @Test("The menu's check state reads the same flag the canvas draws from")
    func menuStateFollowsTheFlag() {
        let (environment, canvas) = makeEnvironment()
        #expect(!environment.isPanelOpen(.toggleCoverageMap))

        environment.perform(.toggleCoverageMap)
        #expect(environment.isPanelOpen(.toggleCoverageMap))
        #expect(environment.isPanelOpen(.toggleCoverageMap) == canvas.showsCoverageMap)

        environment.perform(.toggleCoverageMap)
        #expect(!environment.isPanelOpen(.toggleCoverageMap))
    }

    @Test("The command is in the View menu with an accessibility hint")
    func commandIsDeclared() {
        let declared = ZPDFCommandTable.standard.command(.toggleCoverageMap)
        #expect(declared?.group == .view)
        #expect(declared?.title.isEmpty == false)
        #expect(declared?.accessibilityHint?.isEmpty == false)
    }
}
