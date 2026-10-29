import Foundation
import Testing
@testable import ZPDFUIShell

/// Quality-loop iteration 1, re-fix of area "quantities-core": the Inspector's choice row
/// (NL-MEASURE-10's Display units) says what is chosen, what is mixed, and what no option wrote.
@Suite("Iteration 1 re-fix quantities-core (Inspector choice row)", .shellTierSerialised)
struct Iter1RQuantitiesCoreInspectorTests {

    static let choices = [
        InspectorParameterChoice(id: "project", title: "Project units"),
        InspectorParameterChoice(id: "metres", title: "Metres")
    ]

    @Test("A choice row's menu reads the chosen option, the mixed placeholder, or Custom")
    func choiceLabel() {
        let chosen = InspectorParameterRowModel(id: "displayUnits", title: "Display units", text: "metres", isMixed: false, unitSymbol: "", choices: Self.choices)
        #expect(chosen.choiceLabel == "Metres")
        let mixed = InspectorParameterRowModel(id: "displayUnits", title: "Display units", text: "", isMixed: true, unitSymbol: "", choices: Self.choices)
        #expect(mixed.choiceLabel == InspectorSelectionSummary.mixedPlaceholder)
        let custom = InspectorParameterRowModel(id: "displayUnits", title: "Display units", text: "", isMixed: false, unitSymbol: "", choices: Self.choices)
        #expect(custom.choiceLabel == "Custom")
        // A typed row has no options and keeps its text field.
        let depth = InspectorParameterRowModel(id: "depth", title: "Depth", text: "200", isMixed: false, unitSymbol: "mm")
        #expect(depth.choices.isEmpty)
    }
}
