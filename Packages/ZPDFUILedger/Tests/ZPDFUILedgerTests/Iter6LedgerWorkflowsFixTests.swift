import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Loop iteration 6, area ui-workflows-ledger, the package half: W-062 (Delete Snapshot asks
/// before it erases, and a failed delete is reported) and W-068 (the export banner writes its
/// numbers through the ledger's one renderer and its dates in the locale it is given).
/// Never on screen.
@MainActor
@Suite("Loop iteration 6 — ui-workflows-ledger package fixes", .ledgerTierSerialised)
struct Iter6LedgerWorkflowsFixTests {

    // MARK: - W-062

    private static let older = LedgerSnapshotSummary(
        id: "A", name: "Bid 1", createdAt: Date(timeIntervalSince1970: 1_000), author: "", rowCount: 3
    )
    private static let newer = LedgerSnapshotSummary(
        id: "B", name: "Bid 2", createdAt: Date(timeIntervalSince1970: 2_000), author: "", rowCount: 3
    )

    @Test("W-062: Delete Snapshot asks first; Cancel and another selection keep the snapshot")
    func deleteAsksFirst() async {
        let presenter = MockLedgerPresenter()
        presenter.mockSnapshots = [Self.newer, Self.older]
        let model = LedgerSnapshotsModel(presenter: presenter)
        await model.reload()
        #expect(model.selectedID == "B")

        model.requestDelete()
        // Old output: the one press erased "Bid 2" there and then.
        #expect(model.isConfirmingDelete)
        #expect(model.selectedName == "Bid 2")
        #expect(presenter.mockSnapshots.map(\.id) == ["B", "A"])
        model.cancelDelete()
        #expect(!model.isConfirmingDelete)
        #expect(presenter.mockSnapshots.map(\.id) == ["B", "A"])

        // Picking another snapshot abandons the question rather than retargeting it.
        model.requestDelete()
        model.selectedID = "A"
        await model.selectionChanged()
        #expect(!model.isConfirmingDelete)
        #expect(await model.confirmDelete() == false)
        #expect(presenter.mockSnapshots.map(\.id) == ["B", "A"])

        // The second press deletes the one the question named, and says so.
        model.requestDelete()
        #expect(await model.confirmDelete())
        #expect(presenter.mockSnapshots.map(\.id) == ["B"])
        #expect(model.snapshots.map(\.id) == ["B"])
        #expect(model.message == "Snapshot “Bid 1” deleted.")
        #expect(model.selectedID == "B")
    }

    @Test("W-062: a delete the store refuses keeps the selection and says it is still stored")
    func failedDeleteIsReported() async {
        let presenter = GatedReportsPresenter()
        presenter.base.mockSnapshots = [Self.newer, Self.older]
        presenter.deleteFails = true
        let model = LedgerSnapshotsModel(presenter: presenter)
        await model.reload()
        model.selectedID = "A"
        await model.selectionChanged()

        model.requestDelete()
        #expect(await model.confirmDelete() == false)
        // Old output: the Bool was thrown away — selection cleared, the list reloaded and the
        // first snapshot picked again (here "Bid 2"), with no message: it read as a success.
        #expect(model.selectedID == "A")
        #expect(model.message == "“Bid 1” could not be deleted. It is still stored.")
        #expect(model.snapshots.map(\.id) == ["B", "A"])
        #expect(!model.isConfirmingDelete)
    }

    // MARK: - W-068

    private static let planArea = Decimal(string: "1234.5")!

    @Test("W-068: the banner's numbers are the cells' numbers — fr_FR groups with U+00A0, not ICU's U+202F")
    func bannerNumbersMatchTheCells() {
        let french = Locale(identifier: "fr_FR")
        let filter = LedgerFixtures.group(.all, rules: [
            LedgerFixtures.rule(.planArea, .greaterThan, .number(Self.planArea))
        ])
        let banner = LedgerExportWriter.describe(filter: filter, columns: LedgerFixtures.columns, locale: french)
        let cell = LedgerNumberFormatting.exactString(Self.planArea, minimumFractionDigits: 0, locale: french)
        #expect(cell == "1\u{00A0}234,5")
        // Old output: "… 1\u{202F}234,5 m²", from a NumberFormatter of its own.
        #expect(banner.contains(cell), "\(banner.unicodeScalars.map { String($0.value, radix: 16) })")
        #expect(!banner.unicodeScalars.contains("\u{202F}"))
    }

    @Test("W-068: the banner goes through the renderer the application installs")
    func bannerUsesTheInstalledRenderer() {
        // The renderer is process-wide, so it answers differently only for a sentinel value.
        let sentinel = Decimal(string: "424242.125")!
        LedgerNumberFormatting.setRenderer { value, digits, locale, grouping in
            value == sentinel ? "CORE" : LedgerNumberFormatting.builtInRenderer(value, digits, locale, grouping)
        }
        defer { LedgerNumberFormatting.setRenderer(nil) }
        let filter = LedgerFixtures.group(.all, rules: [LedgerFixtures.rule(.count, .equals, .number(sentinel))])
        let banner = LedgerExportWriter.describe(
            filter: filter, columns: LedgerFixtures.columns, locale: Locale(identifier: "en_US_POSIX")
        )
        // Old output: "Count is 424242.125" — the installed renderer was never asked.
        #expect(banner.hasSuffix(" CORE"), "\(banner)")
    }

    @Test("W-068: a date operand is written in the locale the banner is for")
    func bannerDatesFollowTheLocale() {
        let created = LedgerColumn(id: .created, title: "Created", kind: .date, width: 90)
        let day = Date(timeIntervalSince1970: 1_767_312_000) // 2 January 2026, 00:00 UTC
        let filter = LedgerFixtures.group(.all, rules: [LedgerFixtures.rule(.created, .greaterThan, .date(day))])
        func expected(_ identifier: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: identifier)
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: day)
        }
        let swedish = LedgerExportWriter.describe(filter: filter, columns: [created], locale: Locale(identifier: "sv_SE"))
        let american = LedgerExportWriter.describe(filter: filter, columns: [created], locale: Locale(identifier: "en_US"))
        #expect(expected("sv_SE") != expected("en_US"), "the two locales must spell the day differently")
        // Old output: both banners carried the process locale's spelling.
        #expect(swedish.hasSuffix(" \(expected("sv_SE"))"), "\(swedish)")
        #expect(american.hasSuffix(" \(expected("en_US"))"), "\(american)")
    }
}
