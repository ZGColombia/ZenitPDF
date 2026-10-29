import Foundation
import Testing
import ZPDFAppCore

/// NL-DOCS-09: back and forward through jumps, with the viewport each jump left.
struct NextLevelDocumentsNavigationHistoryTests {

    private let a = NavigationPlace(pageID: UUID(), left: 10, top: 700)
    private let b = NavigationPlace(pageID: UUID(), left: nil, top: 612)
    private let c = NavigationPlace(pageID: UUID(), left: 0, top: 0)

    @Test("Back returns the place a jump left, forward returns again; a new jump clears forward")
    func backAndForward() {
        var history = NavigationHistory()
        #expect(history.back.isEmpty)
        history.willJump(from: a)          // a → b
        history.willJump(from: b)          // b → c
        #expect(history.goBack(from: c) == b)
        #expect(history.goBack(from: b) == a)
        #expect(history.goBack(from: a) == nil, "nothing further back")
        #expect(history.goForward(from: a) == b)
        #expect(!history.forward.isEmpty)
        history.willJump(from: b)          // a new jump from b
        #expect(history.forward.isEmpty, "a new jump clears what lay ahead")
    }

    @Test("The same place is recorded once; places on removed sheets are dropped; capacity holds")
    func housekeeping() {
        var history = NavigationHistory()
        history.willJump(from: a)
        history.willJump(from: a)
        #expect(history.back == [a])
        history.willJump(from: b)
        history.keep(only: [b.pageID])
        #expect(history.back == [b])
        for index in 0..<(NavigationHistory.capacity + 20) {
            history.willJump(from: NavigationPlace(pageID: UUID(), left: Double(index), top: 0))
        }
        #expect(history.back.count == NavigationHistory.capacity)
    }
}
