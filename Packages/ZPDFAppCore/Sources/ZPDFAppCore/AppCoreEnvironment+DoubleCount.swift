import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// The tray side of the double-count guard (NL-MEASURE-13).
extension AppCoreEnvironment {

    /// The defaults key that turns the guard off. Absent means on.
    public static let doubleCountGuardDefaultsKey = "ZenitDoubleCountGuardEnabled"

    /// The tray source every double-count warning carries, so the set can be kept current.
    public static var doubleCountWarningSource: String {
        NSLocalizedString("Double count", comment: "Warning source: two overlapping areas of the same subject")
    }

    /// Whether the guard runs: on unless the person turned it off.
    public static func doubleCountGuardEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: doubleCountGuardDefaultsKey) as? Bool ?? true
    }

    /// Recomputes the overlaps and keeps the tray exactly in step: a warning per overlapping
    /// pair, named by both labels and the shared area; a pair that no longer overlaps loses its
    /// warning. Text and a symbol, never colour alone (the tray's own rule).
    ///
    /// Only a warning whose words changed is posted, and it keeps the time it was first raised
    /// (U-038). Every warning used to be re-posted after every command, a label or colour edit
    /// included, each post re-sorting and republishing the whole tray with a new timestamp.
    ///
    /// A warning the person dismissed stays dismissed while its pair says the same thing
    /// (V-034). It used to come back after the next command of any kind — a colour edit
    /// elsewhere included — because the tray's dismissal recorded nothing and this refresh
    /// re-posted every finding it did not see standing. A pair whose words change (another
    /// shared area, a new label) is news and is posted again; a pair that stops overlapping is
    /// forgotten, so a later overlap is raised afresh.
    ///
    /// - Parameter enabled: whether the guard runs; `nil` reads the person's setting. Tests pass
    ///   it explicitly rather than writing a preference file.
    public func refreshDoubleCountWarnings(enabled: Bool? = nil) async {
        let existing = document.warnings.filter { $0.source == Self.doubleCountWarningSource }
        guard enabled ?? Self.doubleCountGuardEnabled() else {
            for warning in existing { document.dismissWarning(id: warning.id) }
            // Turning the guard back on is asking to see every overlap again.
            doubleCountPosted = [:]
            dismissedDoubleCounts = [:]
            publishDoubleCountRegions([:])
            return
        }
        // What the guard left in the tray last time and is not there now, the person dismissed.
        let inTray = Set(existing.map(\.id))
        for (id, posted) in doubleCountPosted where !inTray.contains(id) {
            dismissedDoubleCounts[id] = Self.doubleCountWords(posted)
        }
        let findings = await session.doubleCountFindings()
        publishDoubleCountRegions(Dictionary(grouping: findings, by: \.pageID).mapValues { $0.flatMap(\.region) })
        let formatter = snapshot.ledger.formatter
        let standing = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current: Set<UUID> = []
        var posted: [UUID: AppWarning] = [:]
        for finding in findings {
            let id = Self.warningID(finding.first, finding.second)
            current.insert(id)
            let quantity = Shown.Quantity.squareMetres(finding.squareMetres)
            let area = formatter.text(quantity)
            let unit = formatter.symbol(quantity)
            let warning = AppWarning(
                id: id,
                severity: .warning,
                title: String(
                    format: NSLocalizedString(
                        "Two “%@” areas overlap",
                        comment: "Double-count warning title; the subject"
                    ),
                    finding.subject
                ),
                message: String(
                    format: NSLocalizedString(
                        "%1$@ and %2$@ share %3$@ %4$@. Both are summed, so that area is counted twice.",
                        comment: "Double-count warning: first label, second label, shared area, area unit"
                    ),
                    finding.firstLabel, finding.secondLabel, area, unit
                ),
                source: Self.doubleCountWarningSource,
                timestamp: standing[id]?.timestamp ?? Date(),
                relatedMarkupID: finding.second.rawValue,
                relatedPageID: finding.pageID.rawValue
            )
            if let dismissed = dismissedDoubleCounts[id] {
                if dismissed == Self.doubleCountWords(warning) { continue }
                dismissedDoubleCounts[id] = nil
            }
            posted[id] = warning
            guard standing[id] != warning else { continue }
            document.post(warning)
        }
        for warning in existing where !current.contains(warning.id) {
            document.dismissWarning(id: warning.id)
        }
        dismissedDoubleCounts = dismissedDoubleCounts.filter { current.contains($0.key) }
        doubleCountPosted = posted
    }

    /// What a double-count warning says, the identity a dismissal is kept against.
    static func doubleCountWords(_ warning: AppWarning) -> String {
        warning.title + "\n" + warning.message
    }

    /// Keeps the hatch regions and tells the canvas when they moved.
    private func publishDoubleCountRegions(_ regions: [PageID: [PolygonGeometry]]) {
        // NL-UX-20: every window hatches the same overlaps.
        for view in windowViews { view.publishDoubleCountRegions(regions) }
        guard regions != doubleCountRegions else { return }
        doubleCountRegions = regions
        onDoubleCountRegionsChanged?()
    }

    /// One identity per unordered pair, so re-posting replaces instead of stacking.
    static func warningID(_ a: MarkupID, _ b: MarkupID) -> UUID {
        let (low, high) = a.rawValue.uuidString < b.rawValue.uuidString ? (a.rawValue, b.rawValue) : (b.rawValue, a.rawValue)
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: low.uuid) { lowBytes in
            withUnsafeBytes(of: high.uuid) { highBytes in
                for index in 0..<16 {
                    // Rotating the second operand keeps (a, b) and (b, a) apart from (a, a).
                    bytes[index] = lowBytes[index] ^ highBytes[(index + 5) % 16] ^ 0xD5
                }
            }
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
