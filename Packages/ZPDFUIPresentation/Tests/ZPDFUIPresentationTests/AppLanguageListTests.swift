import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Live test 8 follow-up: lists inside English sentences were joined in the system region's
/// language, so on a Swedish Mac Prepare This Set read "passed over: A-102 och A-104".
@Suite("App-language lists")
struct AppLanguageListTests {

    /// Old output on this sv_SE Mac: `ListFormatter.localizedString(byJoining:)` gave
    /// "A-102 och A-104" and "Depth, Slope och Wall height".
    @Test("A list in an English sentence is joined in English, whatever the system region")
    func joinedInTheAppLanguage() {
        #expect(AppLanguageList.joined([]) == "")
        #expect(AppLanguageList.joined(["A-102"]) == "A-102")
        #expect(AppLanguageList.joined(["A-102", "A-104"]) == "A-102 and A-104")
        #expect(AppLanguageList.joined(["Depth", "Slope", "Wall height"]) == "Depth, Slope, and Wall height")
    }

    @Test("A skipped-property report lists its properties in English")
    func skipReportListIsEnglish() {
        let line = MarkupSkipReport.Group(propertyNames: ["Depth", "Slope"], markupIDs: [UUID()])
        #expect(line.propertyList == "Depth and Slope")
    }
}
