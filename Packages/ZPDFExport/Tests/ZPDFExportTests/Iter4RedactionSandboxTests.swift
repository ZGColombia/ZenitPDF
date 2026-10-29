import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ZPDFExport

/// Iteration 4 re-fix: C-09 in the sandbox.
///
/// The shipped app is sandboxed with `com.apple.security.files.user-selected.read-write` only. A
/// save panel grants the file it names and nothing beside it, so the first C-09 fix — one copy at
/// the panel's file and every other drawing's copy beside it — wrote the first copy and was then
/// refused "Operation not permitted" on the second, and every redacted copy's hidden
/// `.zpdf-redact-…` staging sibling was refused too. `swift test` runs unsandboxed and saw none of
/// it. These tests run Apply's writes in a child process (`zpdf-redaction-probe`, the same
/// `RedactionCopySet` and redactors the app calls) under `sandbox-exec` with the two grant shapes
/// the app can get: a folder from an open panel (several drawings) and one file from a save
/// panel (one drawing). Each profile is proved to bite before it is trusted, as
/// `SandboxedSaveTests` does (a gate that denies nothing proves nothing).
@Suite("Iteration 4 re-fix — redaction under the sandbox's grant shapes (C-09)", .serialized, .sharedHeap)
struct Iter4RedactionSandboxTests {

    final class Anchor {}

    static let box = CGRect(x: 60, y: 180, width: 300, height: 40)

    /// A one-sheet 420 × 300 pt drawing with `secret` under ``box`` and `kept` above it.
    static func drawing(at url: URL, secret: String, kept: String) throws {
        var media = CGRect(x: 0, y: 0, width: 420, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for (text, y) in [(secret, 192.0), (kept, 250.0)] {
            context.textPosition = CGPoint(x: 70, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])), context)
        }
        context.stroke(CGRect(x: 20, y: 20, width: 380, height: 260))
        context.endPDFPage()
        context.closePDF()
    }

    static func text(of url: URL) -> String { PDFDocument(url: url)?.page(at: 0)?.string ?? "" }

    /// A workspace: `root/source/Redact A.pdf` and `root/source/Redact B.pdf`.
    static func workspace() throws -> (root: URL, a: URL, b: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-it4r-sandbox-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let a = source.appendingPathComponent("Redact A.pdf"), b = source.appendingPathComponent("Redact B.pdf")
        try drawing(at: a, secret: "PRIMARYSECRET 111", kept: "Keep A")
        try drawing(at: b, secret: "ANNEXSECRET 222", kept: "Keep B")
        return (root, a, b)
    }

    static func probeURL() throws -> URL {
        let bundle = Bundle(for: Anchor.self).bundleURL
        let candidates = [
            bundle.deletingLastPathComponent().appendingPathComponent("zpdf-redaction-probe"),
            bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("zpdf-redaction-probe"),
        ]
        return try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
                            "zpdf-redaction-probe not built beside \(bundle.path)")
    }

    /// `realpath(3)`: seatbelt matches the canonical path (`/private/var/…`), the tests hand out
    /// `/var/…`; both spellings go into a profile.
    static func spellings(_ url: URL) -> Set<String> {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(url.path, &buffer) else { return [url.path] }
        return [url.path, String(cString: resolved)]
    }

    /// The powerbox shape: every write under `root` denied, except under `granted` — a folder an
    /// open panel chose, or the one file a save panel named (which need not exist yet).
    static func profile(root: URL, granted: URL) -> String {
        let roots = spellings(root)
        let grants = roots.map { "\($0)/\(granted.path.dropFirst(root.path.count + 1))" }
        return (["(version 1)", "(allow default)"]
            + roots.map { "(deny file-write* (subpath \"\($0)\"))" }
            + grants.map { "(allow file-write* (subpath \"\($0)\"))" }).joined(separator: "\n")
    }

    struct Run { let status: Int32; let output: String; let error: String }

    static func run(_ executable: URL, _ arguments: [String], sandbox profile: String) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, executable.path] + arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile(), error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self), error: String(decoding: error, as: UTF8.self))
    }

    /// Proves `profile` denies writing `denied` and allows writing `allowed`.
    static func expectProfileBites(_ profile: String, denied: URL, allowed: URL?) throws {
        let refused = try run(URL(fileURLWithPath: "/usr/bin/touch"), [denied.path], sandbox: profile)
        #expect(refused.status != 0, "the profile let \(denied.lastPathComponent) be written")
        #expect(!FileManager.default.fileExists(atPath: denied.path))
        if let allowed {
            let granted = try run(URL(fileURLWithPath: "/usr/bin/touch"), [allowed.path], sandbox: profile)
            #expect(granted.status == 0, "the profile refused the granted \(allowed.lastPathComponent): \(granted.error)")
            try? FileManager.default.removeItem(at: allowed)
        }
    }

    @Test("C-09: two drawings' copies are all written inside a chosen folder under its grant, and nothing beside it")
    func folderGrantWritesEveryCopy() throws {
        let (root, a, b) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let profile = Self.profile(root: root, granted: folder)
        // The old place of the second copy — beside the chosen file — and the old hidden staging
        // sibling are both refused under a grant that does not cover them.
        try Self.expectProfileBites(profile, denied: root.appendingPathComponent("Redact B — Redacted.pdf"), allowed: folder.appendingPathComponent("probe"))
        try Self.expectProfileBites(profile, denied: root.appendingPathComponent(".zpdf-redact-probe.pdf"), allowed: nil)

        let probe = try Self.probeURL()
        let pictures = try Self.run(probe, ["folder", folder.path, a.path, b.path], sandbox: profile)
        #expect(pictures.status == 0, "the sandboxed Apply failed: \(pictures.error)")
        let sharp = try Self.run(probe, ["folder", folder.path, "--sharp", a.path, b.path], sandbox: profile)
        #expect(sharp.status == 0, "the sandboxed Keep Sharp Apply failed: \(sharp.error)")

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["Redact A — Redacted 2.pdf", "Redact A — Redacted.pdf", "Redact B — Redacted 2.pdf", "Redact B — Redacted.pdf"], "\(names)")
        for name in names {
            let text = Self.text(of: folder.appendingPathComponent(name))
            let isA = name.hasPrefix("Redact A")
            #expect(!text.contains(isA ? "PRIMARYSECRET" : "ANNEXSECRET"), "\(name): \(text)")
            #expect(!text.contains(isA ? "ANNEXSECRET" : "PRIMARYSECRET"), "\(name): \(text)")
            if name.contains("Redacted 2") {
                // Keep Sharp: the text outside the box stays searchable.
                #expect(text.contains(isA ? "Keep A" : "Keep B"), "\(name): \(text)")
            }
        }
        // Nothing but the chosen folder and the drawings in the workspace.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["Chosen", "source"])
    }

    @Test("C-09: one drawing's copy is written at the save panel's file under that file's grant alone, and replaced in place")
    func fileGrantWritesTheCopyWithoutASibling() throws {
        let (root, a, _) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let chosen = root.appendingPathComponent("Chosen.pdf")
        let profile = Self.profile(root: root, granted: chosen)
        // Old: StagedFileReplacement staged the copy as a hidden sibling of the chosen file, which
        // this grant refuses — the write failed at every place a person could choose.
        try Self.expectProfileBites(profile, denied: root.appendingPathComponent(".zpdf-redact-probe.pdf"), allowed: chosen)

        let probe = try Self.probeURL()
        let first = try Self.run(probe, ["file", chosen.path, a.path], sandbox: profile)
        #expect(first.status == 0, "the sandboxed redaction failed: \(first.error)")
        #expect(!Self.text(of: chosen).contains("PRIMARYSECRET"))
        // Again over the file now there (Replace in the save panel): swapped in place.
        let again = try Self.run(probe, ["file", chosen.path, "--sharp", a.path], sandbox: profile)
        #expect(again.status == 0, "the sandboxed replace failed: \(again.error)")
        let text = Self.text(of: chosen)
        #expect(!text.contains("PRIMARYSECRET") && text.contains("Keep A"), "\(text)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["Chosen.pdf", "source"])
    }

    @Test("C-09: a drawing that cannot be redacted leaves no copy of the set in the folder, and the error names it")
    func failedDrawingLeavesNoCopy() async throws {
        let (root, a, b) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a PDF".utf8).write(to: b)
        let marks = [RedactionMark(pageIndex: 0, rect: Self.box)]
        do {
            _ = try await RedactionCopySet.write(names: ["Redact A", "Redact B"], into: folder, protecting: [a, b]) { index, staged in
                try RasterRedactor.redact(source: [a, b][index], marks: marks, to: staged)
            }
            Issue.record("a set with an unreadable drawing was written")
        } catch let refusal as RedactionRefusal {
            // Old: A's copy stayed in the folder and B's error said nothing of it.
            #expect(refusal == .copyFailed(drawing: "Redact B", reason: RedactionRefusal.unreadable.description))
            #expect(refusal.description.contains("no redacted copy of any marked drawing was kept"), "\(refusal)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test("C-09: a copy whose name is taken while the set is made is never written over; the copies already moved are removed")
    func takenNameRollsBack() async throws {
        let (root, a, b) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marks = [RedactionMark(pageIndex: 0, rect: Self.box)]
        let someoneElses = folder.appendingPathComponent("Redact B — Redacted.pdf")
        await #expect(throws: RedactionRefusal.self) {
            _ = try await RedactionCopySet.write(names: ["Redact A", "Redact B"], into: folder, protecting: [a, b]) { index, staged in
                let outcome = try RasterRedactor.redact(source: [a, b][index], marks: marks, to: staged)
                // Another program takes B's name after it was chosen.
                if index == 1 { try Data("theirs".utf8).write(to: someoneElses) }
                return outcome
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Redact B — Redacted.pdf"])
        #expect(try Data(contentsOf: someoneElses) == Data("theirs".utf8))
    }

    @Test("C-09: copy names stay inside the folder, never hidden, and never take a name already there")
    func targetNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-it4r-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("Annex — Redacted.pdf"))
        let targets = RedactionCopySet.targets(named: ["Plan", "Annex", "annex", "../Up/Out", ".hidden", ""], suffix: "Redacted", in: folder)
        #expect(targets.map(\.lastPathComponent) == [
            "Plan — Redacted.pdf", "Annex — Redacted 2.pdf", "annex — Redacted 3.pdf",
            "-Up-Out — Redacted.pdf", "hidden — Redacted.pdf", "Drawing — Redacted.pdf",
        ])
        #expect(targets.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL })
    }
}
