import Foundation
import Testing
@testable import ZenitCLICore

/// NL-PLAT-13: the read-only CLI refuses what is not a project, by name.
@Suite("zenit CLI — NL-PLAT-13")
struct ZenitCLITests {
    @Test("A path that is not a .zpdfproj is refused with a sentence")
    func refusesNonProject() async {
        do {
            _ = try await ProjectReader(url: URL(fileURLWithPath: "/tmp/plan.pdf")).load()
            Issue.record("a PDF was read as a project")
        } catch {
            #expect("\(error)".contains("is not a Zenit PDF project"))
        }
    }
}
