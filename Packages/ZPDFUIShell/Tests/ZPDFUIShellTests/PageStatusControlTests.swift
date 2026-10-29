import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The status bar's page control: what a typed page number resolves to.
///
/// Changed 2026-08-26, after opening a 23-sheet elevation set — the page readout was in the
/// bottom-left corner and was only a readout. It now sits in the middle with an arrow on each
/// side, and a page number typed into the field goes straight to that page.
///
/// This is the one rule for a typed sheet reference — sheet number, then label, then position.
/// The presenters navigate by identity and index only; `goToPage(label:)`, which carried a second
/// and a third version of the rule, was removed (T-033).
@Suite("Page status control", .shellTierSerialised)
struct PageStatusControlTests {

    /// A drawing set whose sheets are labelled by position, which is the common case.
    private let plainSet = ["1", "2", "3", "4", "5"]
    /// A set with printed sheet numbers that are not positions.
    private let namedSet = ["A-101", "A-102", "S-201"]
    /// The hard case: labels that are numbers, but not the positions.
    private let renumberedSet = ["101", "102", "103"]

    @Test("On a set labelled by position, typing the number goes to that page")
    func plainNumbers() {
        #expect(StatusBarDisplay.pageDestination(forTyped: "3", labels: plainSet) == 2)
        #expect(StatusBarDisplay.pageDestination(forTyped: "1", labels: plainSet) == 0)
        #expect(StatusBarDisplay.pageDestination(forTyped: "5", labels: plainSet) == 4)
    }

    @Test("A printed sheet number reaches its sheet, whatever its position")
    func printedLabels() {
        #expect(StatusBarDisplay.pageDestination(forTyped: "A-101", labels: namedSet) == 0)
        #expect(StatusBarDisplay.pageDestination(forTyped: "S-201", labels: namedSet) == 2)
        // Case does not matter: nobody types the capitalisation of a sheet number carefully.
        #expect(StatusBarDisplay.pageDestination(forTyped: "s-201", labels: namedSet) == 2)
    }

    @Test("On a set with printed labels, a bare position still works")
    func positionFallback() {
        #expect(StatusBarDisplay.pageDestination(forTyped: "2", labels: namedSet) == 1)
        #expect(StatusBarDisplay.pageDestination(forTyped: "3", labels: namedSet) == 2)
    }

    @Test("A label that is a number wins over the same number as a position")
    func labelBeatsPosition() {
        // Typing 101 into a set labelled 101, 102, 103 means the sheet printed 101 — position
        // 101 does not exist. Getting this backwards would send the reader nowhere at all.
        #expect(StatusBarDisplay.pageDestination(forTyped: "101", labels: renumberedSet) == 0)
        #expect(StatusBarDisplay.pageDestination(forTyped: "103", labels: renumberedSet) == 2)
        // …and a position that is not also a label still resolves as a position.
        #expect(StatusBarDisplay.pageDestination(forTyped: "2", labels: renumberedSet) == 1)
    }

    @Test("Surrounding whitespace is ignored")
    func whitespace() {
        #expect(StatusBarDisplay.pageDestination(forTyped: "  4 ", labels: plainSet) == 3)
        #expect(StatusBarDisplay.pageDestination(forTyped: "\tA-102\n", labels: namedSet) == 1)
    }

    @Test("Text that names no page resolves to nothing, and navigates nowhere")
    func rubbishGoesNowhere() {
        #expect(StatusBarDisplay.pageDestination(forTyped: "", labels: plainSet) == nil)
        #expect(StatusBarDisplay.pageDestination(forTyped: "   ", labels: plainSet) == nil)
        #expect(StatusBarDisplay.pageDestination(forTyped: "hello", labels: plainSet) == nil)
        #expect(StatusBarDisplay.pageDestination(forTyped: "0", labels: plainSet) == nil)
        #expect(StatusBarDisplay.pageDestination(forTyped: "-2", labels: plainSet) == nil)
        #expect(StatusBarDisplay.pageDestination(forTyped: "6", labels: plainSet) == nil, "past the end")
        #expect(StatusBarDisplay.pageDestination(forTyped: "999", labels: plainSet) == nil)
    }

    @Test("An empty document resolves nothing rather than trapping on an empty range")
    func emptyDocument() {
        #expect(StatusBarDisplay.pageDestination(forTyped: "1", labels: []) == nil)
    }
}
