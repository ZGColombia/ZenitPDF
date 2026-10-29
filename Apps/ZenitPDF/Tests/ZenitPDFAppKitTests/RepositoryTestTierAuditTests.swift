import AppKit
import Foundation
import Testing

/// ``SharedTestStateTests`` widened from one directory to every test target in the repository.
///
/// ### The blind spot this closes
///
/// ``SharedTestStateTests`` turned that class of defect into eight tests, and the hole in them
/// was measured on the night they were written: the suite **scans `Apps/ZenitPDF/Tests` and
/// nothing else**, while the class it enumerates lives in every test tier. The demonstration was
/// not an argument, it was a count:
///
/// * The gate sweep that verified those tests minted three `zenit-author-tests-<UUID>.plist` files
///   from `ZPDFAppCore`, a package the audit cannot see.
/// * The six `build-ui-packages.sh` runs that verified the AppKit-globals repair minted **24 more** from
///   `ZPDFUIShell` — 2 594 → 2 634 preference files in eleven minutes — while the application
///   tier's four fixed `.scratch` names did not move at all.
/// * And `LedgerPanePanelsTests` carried `UserDefaults(suiteName: name) ?? .standard`, the
///   exact fallback the app-tier rule forbids **by name**, in a directory the app-tier rule
///   does not read.
/// * The count itself had a blind spot: it matched only `zenit`-prefixed files, so 26
///   `zpdf-update-tests-<UUID>.plist` files from the update package (since removed) were
///   invisible to the census as well as to the scan.
///
/// So this suite reads the repository, not the directory it lives in. It is deliberately a
/// **text scan of source**, because that is what fails on the run that introduces an offender
/// rather than on some later run that happens to interleave badly — the same reason
/// ``SharedTestStateTests`` gives.
/// `Scripts/verify-test-tier-hygiene.sh` re-states the same rules in shell, independently, so a
/// test tier that fails to compile cannot take its own auditor down with it, and adds the half
/// no source scan can do: a preference-file census across a real suite run.
///
/// ### The needles are assembled at run time
///
/// …so this file does not match its own scan and needs no exemption from it. An exempt scanner
/// is a hole; ``SharedTestStateTests`` makes the same choice for the same reason.
@MainActor
@Suite("Repository-wide test tier audit", .appTierSerialised)
struct RepositoryTestTierAuditTests {

    /// `…/Apps/ZenitPDF/Tests/ZenitPDFAppKitTests/ThisFile.swift` → the repository root.
    private static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ZenitPDFAppKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ZenitPDF
        .deletingLastPathComponent()   // Apps
        .deletingLastPathComponent()   // <root>

    /// Every test target in the repository. `ExternalResearch` is excluded on purpose: those are
    /// third-party clones kept for study, no line of which is built or run here.
    private static func repositoryTestTargets() throws -> [URL] {
        let manager = FileManager.default
        var directories: [URL] = []
        for container in ["Apps", "Packages", "Bridges", "Tests"] {
            let containerURL = repositoryRoot.appendingPathComponent(container, isDirectory: true)
            let children = (try? manager.contentsOfDirectory(atPath: containerURL.path)) ?? []
            for child in children.sorted() {
                let tests = containerURL
                    .appendingPathComponent(child, isDirectory: true)
                    .appendingPathComponent("Tests", isDirectory: true)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: tests.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                directories.append(tests)
            }
        }
        return directories
    }

    private struct SourceLine {
        let path: String
        let number: Int
        let text: String
        var description: String { "\(path):\(number): \(text)" }
    }

    /// Every non-comment line of every Swift file under every test target.
    private static func allLines() throws -> (lines: [SourceLine], files: Int, targets: Int) {
        let manager = FileManager.default
        let targets = try repositoryTestTargets()
        var lines: [SourceLine] = []
        var files = 0
        for target in targets {
            guard let walker = manager.enumerator(at: target, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                files += 1
                let relative = url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
                for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("///"), !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
                    lines.append(SourceLine(path: relative, number: index + 1, text: trimmed))
                }
            }
        }
        return (lines, files, targets.count)
    }

    /// Three files legitimately carry a needle, and each of them is the machinery the rules are
    /// about rather than a test using it: ``ScratchDefaults`` and ``ShellScratchDefaults`` read
    /// `NSHomeDirectory()` to census the Preferences folder, and `SharedTestStateTests` states
    /// the same rules over one directory.
    ///
    /// **This file is deliberately not on the list.** Every needle above is assembled at run
    /// time from fragments, so the scan does not match its own statement of itself. An exempt
    /// scanner is a hole, and the cheapest way to keep one honest is to leave it inside its own
    /// scan and make it survive.
    private static let auditors: Set<String> = [
        "SharedTestStateTests.swift",
        "ShellScratchDefaults.swift",
        "AppTestSupport.swift",
    ]

    private static func offenders(_ predicate: (String) -> Bool) throws -> (found: [String], files: Int, targets: Int) {
        let (lines, files, targets) = try allLines()
        let found = lines
            .filter { !auditors.contains(($0.path as NSString).lastPathComponent) }
            .filter { predicate($0.text) }
            .map(\.description)
        return (found, files, targets)
    }

    /// A gate that scans nothing must fail. This is that assertion, and it is
    /// first because every rule below is worthless without it.
    @Test("The scan reaches every test target in the repository, not just this one")
    func theScanIsRepositoryWide() throws {
        let (lines, files, targets) = try Self.allLines()
        #expect(targets >= 25, "only \(targets) test target directories found")
        #expect(files >= 250, "only \(files) test source files found")
        #expect(lines.count >= 20_000, "only \(lines.count) source lines read")
        // And it must actually leave the application tier: 28.4's whole finding was a scan
        // that stopped here.
        let outside = Set(
            lines
                .map { $0.path.split(separator: "/").prefix(2).joined(separator: "/") }
                .filter { !$0.hasPrefix("Apps/") }
        )
        #expect(outside.count >= 20, "the scan saw only \(outside.count) non-application targets: \(outside.sorted())")
    }

    @Test("No test in any tier falls back to the real defaults")
    func noTestFallsBackToTheRealDefaults() throws {
        // 27.1's defect with a different key, and the one `LedgerPanePanelsTests` carried in a
        // directory the application-tier audit could not read.
        let fallback = "?? " + ".standard"
        let passedIn = "defaults: " + ".standard"
        let (found, _, targets) = try Self.offenders { $0.contains(fallback) || $0.contains(passedIn) }
        #expect(targets >= 25)
        #expect(found.isEmpty, """
            a suite name that cannot be created must be a failure, never the user's real \
            preferences: \(found)
            """)
    }

    @Test("No test in any tier writes the real UserDefaults")
    func noTestWritesTheRealDefaults() throws {
        let realDefaults = "UserDefaults" + ".standard"
        let (found, _, targets) = try Self.offenders { line in
            guard line.contains(realDefaults) else { return false }
            // Reading is how several suites prove the real domain is clean; the offence is a
            // write.
            return line.contains(".set(")
                || line.contains(".removeObject(")
                || line.contains(".removePersistentDomain(")
        }
        #expect(targets >= 25)
        #expect(found.isEmpty, "a test writing the real preferences, in another tier: \(found)")
    }

    @Test("No defaults suite name in any tier carries a UUID")
    func noScratchSuiteNameCarriesAUUID() throws {
        // The litter rule, stated as source rather than as a count. `cfprefsd` owns a named
        // domain the moment it is asked for one and writes its plist whether or not a key is
        // ever stored; `removePersistentDomain` empties the domain and leaves the file, and
        // deleting the file loses a race the daemon always wins. One fixed name per prefix is
        // the only fix that works, and this is what keeps it in place.
        let suiteArgument = "UserDefaults(" + "suiteName"
        let (found, _, targets) = try Self.offenders { line in
            guard line.contains(suiteArgument) || line.contains("suiteName =") || line.contains("suiteName:") else {
                return false
            }
            return line.contains("UUID()")
        }
        #expect(targets >= 25)
        #expect(found.isEmpty, """
            one plist per test per run is how a development machine's Preferences folder \
            reached 2 634: \(found)
            """)
    }

    @Test("No test in any tier writes the general pasteboard")
    func noTestWritesThePasteboard() throws {
        let writes = [".clearContents(", ".setData(", ".setString(", ".setPropertyList(", ".writeObjects("]
        let (found, _, targets) = try Self.offenders { line in
            guard line.contains("NSPasteboard.general") else { return false }
            return writes.contains(where: line.contains)
        }
        #expect(targets >= 25)
        #expect(found.isEmpty, "the general pasteboard is the user's clipboard: \(found)")
    }

    @Test("No test in any tier opens anything through NSWorkspace")
    func noTestDrivesTheWorkspace() throws {
        let (found, _, targets) = try Self.offenders { line in
            line.contains("NSWorkspace.shared")
                && (line.contains(".open(") || line.contains(".launchApplication") || line.contains(".selectFile("))
        }
        #expect(targets >= 25)
        #expect(found.isEmpty, "that puts an application on the user's screen: \(found)")
    }

    @Test("No test in any tier writes into the user's home")
    func noTestWritesIntoTheUsersHome() throws {
        // Assembled at run time, so this rule does not match its own statement of itself —
        // and so `SharedTestStateTests`, which enforces the same rule over this directory,
        // does not have to exempt this file. An exempt scanner is a hole.
        let home = "NSHomeDirectory" + "()"
        let needles = [home] + ["document", "applicationSupport", "desktop", "downloads"].map { ".\($0)Directory" }
        let (found, _, targets) = try Self.offenders { line in
            needles.contains(where: line.contains)
        }
        #expect(targets >= 25)
        #expect(found.isEmpty, """
            a fixture belongs in FileManager.default.temporaryDirectory — an earlier fixture was in \
            the right place and only the modal leaked; these would not be: \(found)
            """)
    }

    /// The AppKit-globals race, generalised: a target that reaches AppKit's lazily-created globals in
    /// more than one concurrently-scheduled `@MainActor` suite inherits the race that killed
    /// the `ZPDFUIShell` test **process** twice in six runs.
    @Test("Every test target that touches AppKit's process globals serialises itself")
    func appKitTargetsAreSerialised() throws {
        let manager = FileManager.default
        let targets = try Self.repositoryTestTargets()
        #expect(targets.count >= 25)

        // Assembled at run time for the same reason as every other needle in this file.
        let globalNeedles = ["NSCursor" + ".", "NSApplication" + ".shared", "NSWindow" + "("]
        var offenders: [String] = []
        var checked: [String] = []
        for target in targets {
            guard let walker = manager.enumerator(at: target, includingPropertiesForKeys: nil) else { continue }
            var touchesGlobals = false
            var suiteAttributes: [String] = []
            var hasGate = false
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if url.lastPathComponent.hasSuffix("SerialGate.swift") { hasGate = true }
                for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let line = String(raw)
                    if line.hasPrefix("@Suite") { suiteAttributes.append(line) }
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("///"), !trimmed.hasPrefix("//") else { continue }
                    if globalNeedles.contains(where: trimmed.contains) {
                        touchesGlobals = true
                    }
                }
            }
            guard touchesGlobals else { continue }
            let relative = target.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
            checked.append(relative)
            let unserialised = suiteAttributes.filter { !$0.contains("TierSerialised") }
            if !hasGate || !unserialised.isEmpty {
                offenders.append(
                    "\(relative): \(suiteAttributes.count) suites, \(unserialised.count) not serialised, gate file: \(hasGate)"
                )
            }
        }
        // Two targets do reach these globals today — the application tier and the shell tier —
        // and both carry a gate. A run that finds none has stopped looking.
        #expect(checked.count >= 2, "the scan found no AppKit-touching test target at all: \(checked)")
        #expect(offenders.isEmpty, """
            NSCursor.arrow is empty until something asks for \
            NSApplication.shared, and in a full run that something is whichever of your own \
            tests made a window first. These targets inherit that race: \(offenders)
            """)
    }
}
