import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// NL-QTY-11: report templates — saved in a library file, applied to another project.
@Suite("Quantities — report templates")
@MainActor
struct NLQuantitiesReportTemplateTests {

    let bugs = NLQuantitiesBugTests()

    @Test("Save 'Client summary' from one project, apply it to another: same grouping, filter and columns")
    func templateTravelsBetweenProjects() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-templates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LedgerReportTemplateStore(directory: directory)

        let first = try await bugs.makeFixture()
        first.environment.ledger.setGrouping([.subject])
        first.environment.ledger.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .subject, comparison: .equals, operand: .text("Slab 1"))
        ]))
        await first.environment.ledger.refresh()
        var template = LedgerReportTemplate.capturing(first.environment.ledger.request, name: "Client summary", format: .pdfReport)
        template.pageSize = .a3
        template.landscape = true
        template.footerNote = "Zenit Group S.A.S. · Estimating"
        try store.save(template)
        // Saving under the same name replaces, it does not duplicate.
        try store.save(template)
        let saved = try store.read()
        #expect(saved.map(\.name) == ["Client summary"])
        #expect(saved.first?.pageSize == .a3 && saved.first?.landscape == true)

        // Another project, unfiltered and ungrouped on screen.
        let second = try await bugs.makeFixture(sizes: [(40, 30), (20, 10), (20, 10)])
        let request = try #require(saved.first).request(onScreen: second.environment.ledger.request)
        #expect(request.grouping == [.subject])
        let (report, unapplied) = try await second.session.exportReportWithDiagnostics(title: "T", request: request)
        #expect(unapplied.isEmpty)
        // Only "Slab 1" survives the template's filter: the 2 m² row.
        #expect(report.metadata.rowCount == 1)
        #expect(report.metadata.totalRowCountBeforeFilter == 3)
        #expect(report.metadata.groupingColumnKeys == ["subject"])

        // "As on screen" templates leave the request alone.
        let onScreen = LedgerReportTemplate(name: "Plain", format: .csv)
        #expect(onScreen.request(onScreen: second.environment.ledger.request) == second.environment.ledger.request)
    }
}
