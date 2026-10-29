import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// NL-MEASURE-05 (ADR-0030 §5.6): under a shape in progress, A belongs to the drawing ("arc next
/// segment") and no letter shortcut may take it — a tool switch would throw the shape away.
@MainActor
@Suite("A under a shape in progress (NL-MEASURE-05)", .shellTierSerialised)
struct ArcKeyClaimTests {

    @Test("A claimed by the drawing is passed on to the canvas; unclaimed it arms Area")
    func claimedLetterIsNotAShortcut() {
        let environment = ProjectShellEnvironment.mock()
        let router = ToolSlotKeyRouter(presenter: environment.toolLibrary)
        var performed: [ZPDFCommandID] = []
        router.performCommand = { performed.append($0) }
        var shapeInProgress = true
        router.claimsDrawingKey = { characters, modifiers in characters == "a" && modifiers.isEmpty && shapeInProgress }

        // Old behaviour with a wired router: A armed Area and the shape in progress was discarded.
        #expect(!router.handleKey(characters: "a", modifiers: [], focus: .canvas), "the key goes on to the canvas")
        #expect(performed.isEmpty)
        // Other letters are unaffected by the claim.
        #expect(router.handleKey(characters: "p", modifiers: [], focus: .canvas))
        #expect(performed == [.panTool])

        shapeInProgress = false
        #expect(router.handleKey(characters: "a", modifiers: [], focus: .canvas))
        #expect(performed.last == .measureArea)
    }
}
