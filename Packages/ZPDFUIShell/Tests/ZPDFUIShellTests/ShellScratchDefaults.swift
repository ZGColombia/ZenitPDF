import Foundation
import Testing

/// A private `UserDefaults` suite that costs the machine **one** file, ever — not one per test
/// per run.
///
/// ### What this replaces
///
/// Two suites in this target minted a fresh `UserDefaults(suiteName:)` per test with a UUID in
/// the name. `cfprefsd` owns a named domain once it has been asked for it, and writes the
/// domain's plist into `~/Library/Preferences` whether or not the test ever stores a key.
/// `removePersistentDomain(forName:)` empties the domain and leaves the file; deleting the file
/// loses a race the daemon always wins. So every run left litter behind, and the litter was
/// measured rather than guessed:
///
/// * 2026-08-26 00:20–00:31 — six runs of `build-ui-packages.sh` minted **24** new plists,
///   eighteen `zenit.test.ledgerpane.<UUID>` from `LedgerPaneGroupingTests` and six
///   `zenit.ledgerpane.tests.<UUID>` from `LedgerPanePanelsTests`, one per test per run.
/// * A development machine's Preferences folder reached **2 634** `zenit`-prefixed plists, of
///   which 254 and 58 were those two fixtures.
///
/// And `LedgerPanePanelsTests` carried the sharper half: `UserDefaults(suiteName: name) ??
/// .standard`. The fallback never fired, but the day a suite name is rejected it silently
/// points the fixture at the user's **real** preferences — shared state outside the tree, the
/// defect class that reddened `build-app-package.sh` three times deterministically because the
/// thing deciding the result lived outside the tree.
///
/// ### The fix, and what makes it safe
///
/// One fixed suite name per prefix, emptied before and after each use, and **no fallback**: a
/// suite that cannot be created is a `#require` failure, never `.standard`.
///
/// A fixed name is only safe because this target is serialised — ``ShellTierSerialisation``
/// admits one test at a time across all nineteen suites, so the per-test isolation the UUID was
/// buying is already there and is not being given up. The two changes are one change; landing
/// the fixed name without the serial gate would trade litter for cross-test bleed.
@MainActor
enum ShellScratchDefaults {

    /// The one suite name this prefix ever uses. Not a UUID — see the type's documentation.
    static func suiteName(for prefix: String) -> String { "\(prefix).scratch" }

    /// A private suite, guaranteed empty, that never falls back to the real defaults.
    static func make(prefix: String) throws -> (UserDefaults, String) {
        let name = suiteName(for: prefix)
        let defaults = try #require(
            UserDefaults(suiteName: name),
            "a scratch suite must never fall back to UserDefaults.standard"
        )
        // Empty on entry as well as on exit: a previous run that died before its `defer` must
        // not be inherited. Inheriting it is state leaking between runs, in miniature.
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    /// Empties the domain and flushes it. The file stays — deliberately, and only one of it.
    static func discard(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.synchronize()
        CFPreferencesAppSynchronize(suiteName as CFString)
    }

    /// How many test-prefixed suite files the machine currently carries. Used by the census
    /// test below and by `Scripts/verify-test-tier-hygiene.sh`, which asserts the same number
    /// across a whole suite run from outside the process.
    static func preferenceFileCount() -> Int {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter {
            let lowered = $0.lowercased()
            return (lowered.hasPrefix("zenit") || lowered.hasPrefix("zpdf")) && lowered.hasSuffix(".plist")
        }.count
    }
}

/// The no-litter assertion, made from inside the tier that used to litter.
@Suite("Shell tier preference hygiene", .shellTierSerialised)
@MainActor
struct ShellScratchDefaultsTests {

    @Test("A scratch suite is empty on both sides and adds no new preference file")
    func aScratchSuiteAddsNoFile() throws {
        // The prefix's one file is created the first time it is ever used, on this machine,
        // for good. What must not grow is the count across *repeated* use, so the first use is
        // the warm-up and the measurement spans the second.
        let (warm, warmName) = try ShellScratchDefaults.make(prefix: "zenit.shellscratch.proof")
        warm.set("warm-up", forKey: "zenit.proof")
        warm.synchronize()
        ShellScratchDefaults.discard(warm, suiteName: warmName)

        let before = ShellScratchDefaults.preferenceFileCount()
        #expect(before > 0, "the census read nothing, so it proves nothing")

        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.shellscratch.proof")
        #expect(name.hasSuffix(".scratch"), "the suite name must not carry a UUID: \(name)")
        #expect(defaults.string(forKey: "zenit.proof") == nil,
                "the suite came in carrying a value from an earlier run")
        defaults.set("written by a test", forKey: "zenit.proof")
        defaults.synchronize()
        #expect(defaults.string(forKey: "zenit.proof") == "written by a test")
        ShellScratchDefaults.discard(defaults, suiteName: name)

        let reopened = try #require(UserDefaults(suiteName: name))
        #expect(reopened.string(forKey: "zenit.proof") == nil, "the domain still holds the value")
        #expect(ShellScratchDefaults.preferenceFileCount() == before, """
            the scratch suite added a preference file: \(before) → \
            \(ShellScratchDefaults.preferenceFileCount()). One plist per test per run is how a \
            development machine's Preferences folder reached 2 634.
            """)
    }

    @Test("No suite in this target names a defaults suite outside ShellScratchDefaults")
    func everyScratchSuiteGoesThroughTheHelper() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        // Assembled at run time so this file does not match its own scan.
        let needle = "UserDefaults(" + "suiteName"
        let fallback = "?? " + ".standard"
        var offenders: [String] = []
        for name in names where name != "ShellScratchDefaults.swift" {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                if trimmed.contains(needle) || trimmed.contains(fallback) {
                    offenders.append("\(name):\(number + 1): \(trimmed)")
                }
            }
        }
        #expect(names.count > 10, "the scan examined \(names.count) files")
        #expect(offenders.isEmpty, """
            these name a defaults suite directly, so they leave a plist per run in the user's \
            Preferences folder and can fall back to the real defaults: \(offenders)
            """)
    }
}
