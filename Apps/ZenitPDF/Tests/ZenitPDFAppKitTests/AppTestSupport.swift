import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ZenitPDFAppKit

/// Shared plumbing for the application-tier tests: a tiny real PDF on disk, a loaded
/// document, and the poll-until helper the async document load needs.
@MainActor
enum AppTestSupport {

    /// Writes a vector PDF (a stroked rectangle per page) into a fresh scratch directory.
    ///
    /// `pageCount` defaults to one, so every existing caller is unchanged. More than one page
    /// exists for the artwork import chooser: a file with three pages is the case the import
    /// used to answer by silently taking the first one, and a one-page
    /// fixture cannot tell a chooser that works from a chooser that is not there.
    static func writeFixturePDF(
        named name: String = "Plan A-102.pdf",
        pageCount: Int = 1
    ) throws -> URL {
        let pages = max(1, pageCount)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-apptests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        // Object numbering: 1 catalogue, 2 page tree, then a page and a content stream per
        // page, interleaved, so page n is object 2n + 1 and its stream is 2n + 2.
        let kids = (0..<pages).map { "\($0 * 2 + 3) 0 R" }.joined(separator: " ")
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>".utf8)
        ]
        for page in 0..<pages {
            // A different rectangle per page, so "which page was imported" is answerable from
            // the geometry rather than only from the page index.
            let inset = 72 + page * 20
            let content = Data(
                "2 w 0 0 0 RG\n\(inset) \(inset) m 372 \(inset) l 372 272 l \(inset) 272 l h S\n".utf8
            )
            objects.append(Data(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents \(page * 2 + 4) 0 R >>".utf8
            ))
            var streamData = Data("<< /Length \(content.count) >>\nstream\n".utf8)
            streamData.append(content)
            streamData.append(Data("\nendstream".utf8))
            objects.append(streamData)
        }

        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
        return url
    }

    /// A fixture the helper could not write.
    struct FixtureError: Error { let reason: String }

    /// Writes an encrypted one-page vector PDF (LT-38): stroked linework behind a user
    /// password, in a fresh scratch directory. `PDFDocument(url:)` opens it with
    /// `isLocked == true`, which is exactly the file the locked-drawing defect was about.
    static func writeLockedFixturePDF(
        named name: String = "Locked Plan.pdf",
        password: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-locked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        let options: [CFString: Any] = [
            kCGPDFContextUserPassword: password,
            kCGPDFContextOwnerPassword: password
        ]
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, options as CFDictionary) else {
            throw FixtureError(reason: "CoreGraphics refused to create an encrypted PDF context")
        }
        context.beginPDFPage(nil)
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(2)
        context.stroke(CGRect(x: 72, y: 72, width: 300, height: 200))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// Opens a PDF into a document and starts its load. The caller waits on the state it
    /// needs and is responsible for `close()`.
    static func makeDocument(opening url: URL) throws -> ZenitPDFProjectDocument {
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        return document
    }

    /// Polls the main actor until `condition` holds, so tests wait on the document's own
    /// async load rather than on a fixed sleep.
    ///
    /// ### Why fifteen seconds, measured rather than guessed
    ///
    /// The default was ten, and the app gate was green one run in six; it was
    /// then raised to sixty, which hid the symptom. Neither number came from a measurement.
    /// `ZENIT_WAIT_TRACE=1` prints every wait longer than 250 ms, and on this machine over the
    /// full 210-test suite:
    ///
    /// | | slowest single wait |
    /// |---|---|
    /// | suites running in parallel | **11.0 s** |
    /// | suites running one at a time (``AppTierSerialisation``) | **1.03 s** |
    ///
    /// So ten seconds was never a bound on the product; it was a bound on how long a poll could
    /// be starved of the one main actor by the other twenty-nine main-actor tests. With the
    /// serial gate in place the real worst case is one second, and the whole suite still passes
    /// with the budget set to three — measured, five runs of five, the same afternoon. Fifteen
    /// is that worst case with a 15× margin: wide enough that a slow machine never decides a
    /// verdict, narrow enough that a condition which will never come true says so in fifteen
    /// seconds instead of a minute.
    ///
    /// Callers asserting a *bounded* behaviour — the quit watchdog, the termination path, OCR —
    /// pass their own explicit deadline, and those are meaningful numbers rather than slack.
    static func wait(
        upTo seconds: Double = 15,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        let started = Date()
        let deadline = started.addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() {
                Self.recordWait(since: started)
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let late = condition()
        Self.recordWait(since: started, satisfied: late)
        return late
    }

    /// Temporary instrumentation for diagnosing slow waits. Enabled by
    /// `ZENIT_WAIT_TRACE=1`; prints every wait that took longer than 250 ms.
    private static func recordWait(since started: Date, satisfied: Bool = true) {
        guard ProcessInfo.processInfo.environment["ZENIT_WAIT_TRACE"] == "1" else { return }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 0.25 || !satisfied {
            FileHandle.standardError.write(Data(String(
                format: "ZWAIT %.3fs satisfied=%@\n", elapsed, satisfied ? "yes" : "NO"
            ).utf8))
        }
    }
}

/// A `UserDefaults` suite that does not add a file to the user's machine every time it runs.
///
/// ### The measurement
///
/// The open item is *the class* rather than the instance: nothing else enumerates the
/// process-wide state an app-tier test can reach, including anything written outside a
/// per-test temporary directory. Counting them,
/// 2026-08-25:
///
/// ```
/// $ ls ~/Library/Preferences | grep -ci '^zenit'
/// 2547
/// ```
///
/// One empty plist per scratch suite any Zenit test had ever created — 1 108 from the author
/// suites, 609 from the ledger power tools, 348 from the drop-bookmark test, the rest from the
/// presentation tier. They hold no data: the suites that called
/// `removePersistentDomain(forName:)` did clear their values.
///
/// ### Why deleting the file is not the fix, measured rather than assumed
///
/// The first attempt at this helper removed the domain **and** deleted the plist, and
/// `aScratchDefaultsSuiteLeavesNoFileBehind` passed — the file really is gone at the moment it
/// is checked. Counting again after that run: **2 586**, up 39, including seven named
/// `zenit-scratch-proof`, which is the proving test's own prefix. `cfprefsd` owns the domain,
/// not the file; deleting the file leaves the domain registered and the daemon writes it out
/// again later. A test cannot win that race and should not try.
///
/// ### The fix: one suite name per prefix, for the life of the machine
///
/// The file is unavoidable; **a new file per test is not**. The suite name is now fixed per
/// prefix instead of carrying a UUID, and the domain is emptied before and after each use. The
/// app test target is serialised (``AppTierSerialisation``), so one test holds a given prefix
/// at a time and the isolation a UUID was buying is already there. The machine gains at most
/// one empty plist per prefix, ever, instead of one per test per run.
///
/// ``SharedTestStateTests/aScratchDefaultsSuiteIsCleanAndAddsNoNewFile`` asserts both halves:
/// the domain is empty on entry and on exit, and the count of `zenit`-prefixed plists does not
/// grow across a use.
@MainActor
enum ScratchDefaults {

    /// Where `cfprefsd` puts a named suite for an unsandboxed process.
    static func fileURL(for suiteName: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(suiteName).plist")
    }

    /// How many `zenit`-prefixed suite files the machine currently carries.
    static func zenitSuiteFileCount() -> Int {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.lowercased().hasPrefix("zenit") && $0.hasSuffix(".plist") }.count
    }

    /// Whether `~/Library/Preferences` can be listed at all. Every account has `com.apple.*`
    /// files there, so this is the positive control for a `zenit` census that may honestly be
    /// zero on a machine that has never run the suite.
    static func preferencesFolderIsListable() -> Bool {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return !names.isEmpty
    }

    /// The one suite name this prefix ever uses. Not a UUID — see the type's documentation.
    static func suiteName(for prefix: String) -> String { "\(prefix).scratch" }

    /// Runs `body` against a private suite that is empty on entry and emptied on exit.
    static func with<T>(
        prefix: String,
        _ body: @MainActor (UserDefaults, String) throws -> T
    ) throws -> T {
        let name = suiteName(for: prefix)
        let defaults = try #require(
            UserDefaults(suiteName: name),
            "a scratch suite must never fall back to UserDefaults.standard"
        )
        // Empty on entry as well as on exit: the previous run of this prefix may have died
        // before its `defer`, and inheriting its keys is 27.1's defect in miniature.
        defaults.removePersistentDomain(forName: name)
        defer { discard(defaults, suiteName: name) }
        return try body(defaults, name)
    }

    /// Empties the domain and flushes it. The file stays — deliberately, and only one of it.
    static func discard(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.synchronize()
        CFPreferencesAppSynchronize(suiteName as CFString)
    }
}

/// Serialises the tests that register documents with `NSDocumentController.shared`.
///
/// The shared document registry, second half. `NSDocumentController.shared` is one object for the whole
/// test process, and `ZenitApplicationDelegate.reviewEditedDocuments` walks *every* registered
/// document, autosaving and closing each. Two suites that each `addDocument` and then drive a
/// review therefore review — and close — one another's documents. The loser's own autosave then
/// fails with *"the package handle is closed"* and its assertion reads a verdict the product
/// never produced. Nothing about that is a defect in the application: it is two tests sharing a
/// singleton, and it is why the app gate was worth "about two runs in three".
///
/// The first half of the fix — making `drainStorageShutdowns()` await before it empties the
/// list — is already in the shipping document. This is the other half, and it is test-only on
/// purpose: a verification pass must not change the behaviour it is judging.
///
/// Main-actor isolated, so the flag and the queue need no lock of their own. Acquire before the
/// first `addDocument` and release in a `defer` registered on the same line, so the release is
/// the last thing the test does — after every `removeDocument` and `close()` defer above it.
@MainActor
enum SharedDocumentControllerGate {

    private static var isHeld = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    /// Waits until no other test is using `NSDocumentController.shared`.
    static func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    /// Hands the controller to the next waiting test, or marks it free.
    static func release() {
        if waiting.isEmpty {
            isHeld = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
