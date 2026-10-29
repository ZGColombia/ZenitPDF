import Foundation
import Testing
@testable import ZenitPDFAppKit

/// The product's dropped-file bookmarks must never reach the test process's real defaults.
///
/// Old behaviour: `DroppedFileBookmarks.remember(_:)` defaulted to `UserDefaults.standard`, and the
/// window's drop handlers called it without a store, so an app-tier drop test wrote
/// `zenit.droppedFileBookmarks` into the `swiftpm-testing-helper` domain and
/// `Scripts/verify-test-tier-hygiene.sh` failed on it.
@MainActor
@Suite("Dropped-file bookmark domain", .appTierSerialised)
struct DroppedFileBookmarksDomainTests {

    @Test("Outside the assembled bundle the bookmark store is a scratch store, not UserDefaults.standard")
    func bookmarkStoreIsScratchInTests() {
        #expect(!ZenitProcessDefaults.isAssembledApplication)
        // Compared outside `#expect`: the macro's expansion of `!==` over these two operands
        // aborts Swift 6.4's SILGen ("invalid conformance"), which took the whole test target down.
        let bookmarks: AnyObject = ZenitProcessDefaults.bookmarks
        let standard: AnyObject = UserDefaults.standard
        let isSameStore = bookmarks === standard
        #expect(!isSameStore)
        #expect(ZenitProcessDefaults.bookmarks is ZenitScratchDefaults)
    }

    @Test("Remembering a dropped file through the product store leaves the real domain untouched")
    func rememberDoesNotTouchStandardDefaults() throws {
        let before = UserDefaults.standard.data(forKey: DroppedFileBookmarks.defaultsKey)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-bm-domain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Dropped.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: file)

        DroppedFileBookmarks.remember(file, defaults: ZenitProcessDefaults.bookmarks)
        defer { DroppedFileBookmarks.removeAll(defaults: ZenitProcessDefaults.bookmarks) }

        #expect(UserDefaults.standard.data(forKey: DroppedFileBookmarks.defaultsKey) == before)
    }
}
