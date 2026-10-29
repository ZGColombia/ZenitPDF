import Foundation
import Testing
@testable import ZPDFPDFKitBridge

/// S17 security review — the PDF promises, proved structurally instead of declared.
///
/// `PDFBridgeSecurityPolicy` states six promises as `let … = false`. A test that reads
/// those constants back proves that a constant is a constant; it cannot fail, and it
/// would keep passing on the day the behaviour changed. The promises are only worth
/// something if something *outside* the declaration enforces them, and for this package
/// that something is structural:
///
/// - PDFKit performs actions — `/OpenAction`, `/Launch`, `/URI`, document JavaScript,
///   embedded-file opening — through `PDFView` and nothing else. No `PDFView` in the
///   product means no code path that performs them, whatever a future caller asks for.
/// - Nothing in the package may open a URL, spawn a process, or load a library, because
///   those are the other ways a document's wishes could be carried out.
///
/// Two independent checks, source and symbol, for the reason `NetworkAbsenceTests` in
/// `ZPDFSearch` gives: a source scan is readable but spellable-around, and a symbol scan
/// catches what is reached indirectly. Neither may pass by finding nothing to look at.
@Suite("Structural security promises")
struct StructuralSecurityPromiseTests {

    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ZPDFPDFKitBridgeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ZPDFPDFKitBridge

    /// PDFKit types that act on a document's behalf, and the general escape hatches.
    ///
    /// `PDFView` heads the list: it is the object that follows a link, runs an
    /// `/OpenAction` and opens an embedded file. The view subclasses are here too because
    /// each one constructs or drives a `PDFView`.
    static let forbiddenSourcePatterns = [
        "PDFView", "PDFThumbnailView", "PDFOutlineView",
        "WKWebView", "JSContext", "JSValue", "JavaScriptCore",
        "NSWorkspace", "LSOpenCFURLRef", "openURL",
        "Process(", "NSTask", "posix_spawn", "dlopen", "dlsym",
        "URLSession", "NWConnection"
    ]

    /// The same promises at the object-file level. Matched as substrings of the mangled
    /// names `nm -u` reports.
    static let forbiddenSymbolFragments = [
        "_OBJC_CLASS_$_PDFView",
        "_OBJC_CLASS_$_PDFThumbnailView",
        "_OBJC_CLASS_$_WKWebView",
        "_OBJC_CLASS_$_NSWorkspace",
        "_OBJC_CLASS_$_NSTask",
        "JSEvaluateScript", "JSGlobalContextCreate",
        "URLSession", "CFURLConnection", "nw_connection",
        "_dlopen", "_dlsym", "_posix_spawn", "_execve"
    ]

    @Test("No source file in the bridge names a PDFKit type that performs actions")
    func sourcesNameNoActingType() throws {
        let sources = Self.packageRoot.appendingPathComponent("Sources", isDirectory: true)
        let files = try Self.swiftFiles(under: sources)
        #expect(files.count >= 10, "found only \(files.count) source files; the scan is looking in the wrong place")

        var scannedLines = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = String(line)
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                // A name discussed in a doc comment is documentation, not a call. This
                // package explains at length *why* it never builds a PDFView, and that
                // explanation must not be what fails the test.
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                scannedLines += 1
                for pattern in Self.forbiddenSourcePatterns where code.contains(pattern) {
                    Issue.record("\(file.lastPathComponent):\(number + 1) names \(pattern): \(trimmed)")
                }
            }
        }
        #expect(scannedLines > 1000, "only \(scannedLines) lines of code were scanned")
        print("[ZPDFPDFKitBridge] source scan: \(files.count) files, \(scannedLines) code lines, no acting type")
    }

    @Test("The compiled bridge links no PDFView, no web view, no JavaScript engine")
    func symbolsNameNoActingType() throws {
        let objects = try Self.builtObjectFiles()
        #expect(!objects.isEmpty,
                "no ZPDFPDFKitBridge object files under \(Self.buildDirectory.path) — build the package first")

        var scanned = 0
        var sawPDFKit = false
        for object in objects {
            let undefined = try Self.undefinedSymbols(of: object)
            #expect(!undefined.isEmpty, "\(object.lastPathComponent) reported no symbols")
            scanned += 1
            if undefined.contains(where: { $0.contains("PDFDocument") || $0.contains("PDFAnnotation") }) {
                sawPDFKit = true
            }
            for symbol in undefined {
                for fragment in Self.forbiddenSymbolFragments where symbol.contains(fragment) {
                    Issue.record("\(object.lastPathComponent) references \(symbol) (matched \(fragment))")
                }
            }
        }
        // Negative results are only meaningful if the scan can see positive ones: if no
        // PDFKit symbol at all appears, the scan is reading the wrong object files and a
        // clean result would mean nothing.
        #expect(sawPDFKit, "no PDFKit symbol found at all — the scan is not looking at the bridge")
        #expect(scanned >= 1)
        print("[ZPDFPDFKitBridge] symbol scan: \(scanned) object files, no acting type")
    }

    /// The hazard vocabulary has to actually cover what a hostile document carries;
    /// otherwise "reported and never performed" reports nothing.
    @Test("Every hazard the promises name has a distinct case that can report it")
    func hazardVocabularyCoversThePromises() throws {
        // One case per promise in `PDFBridgeSecurityPolicy`, plus the form dictionaries
        // that carry scripting of their own.
        let named: [(String, DocumentHazards)] = [
            ("documentJavaScript", .documentJavaScript),
            ("javaScriptAction", .javaScriptAction),
            ("openAction", .openAction),
            ("launchAction", .launchAction),
            ("embeddedFiles", .embeddedFiles),
            ("externalURIAction", .externalURIAction),
            ("remoteGoToAction", .remoteGoToAction),
            ("acroForm", .acroForm),
            ("xfaForm", .xfaForm),
            ("documentAdditionalActions", .documentAdditionalActions)
        ]
        var seen: Set<UInt16> = []
        for (name, hazard) in named {
            #expect(!hazard.isEmpty, "\(name) is the empty set")
            #expect(seen.insert(hazard.rawValue).inserted, "\(name) shares a bit with another hazard")
        }
        // The policy's six promises each need a hazard that can report a violation.
        let policy = PDFBridgeSecurityPolicy.current
        #expect(!policy.executesDocumentJavaScript)
        #expect(!policy.followsLaunchActions)
        #expect(!policy.extractsEmbeddedFilesAutomatically)
        #expect(!policy.resolvesExternalReferences)
        #expect(!policy.performsOpenAction)
        #expect(!policy.mutatesSourceDocuments)
    }

    // MARK: - Plumbing

    static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The build directory this test bundle was built into, so a build with `--scratch-path`
    /// scans its own objects rather than assuming `<package>/.build`. The native build system
    /// keeps each target's objects beside the `.xctest` bundle (`<triple>/debug/`); Swift Build
    /// keeps them in `out/Intermediates.noindex/`, next to `out/Products/<configuration>/`.
    /// Falls back to `<package>/.build` when the test is not running from an `.xctest` bundle.
    static let buildDirectory: URL = {
        let bundle = Bundle(for: BundleLocator.self).bundleURL
        guard bundle.pathExtension == "xctest" else {
            return packageRoot.appendingPathComponent(".build", isDirectory: true)
        }
        let products = bundle.deletingLastPathComponent()
        let parent = products.deletingLastPathComponent()
        return parent.lastPathComponent == "Products" ? parent.deletingLastPathComponent() : products
    }()

    static func builtObjectFiles() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: buildDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        // The library's objects only. SwiftPM's newer build layout puts every target of the
        // package under `out/Intermediates.noindex/ZPDFPDFKitBridge.build/`, the *test* target
        // included, and a test is allowed to spawn `nm` (see `undefinedSymbols(of:)`).
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "o" && $0.path.contains("ZPDFPDFKitBridge.build/")
                && !$0.path.contains("ZPDFPDFKitBridgeTests")
        }
    }

    /// A subprocess in a *test* is fine; the rule is that the library target may not
    /// spawn one, and `sourcesNameNoActingType` is what enforces that.
    static func undefinedSymbols(of object: URL) throws -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-u", object.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Set(
            String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { String($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        )
    }
}

/// Anchors `Bundle(for:)` to the test bundle that contains this file.
private final class BundleLocator {}
