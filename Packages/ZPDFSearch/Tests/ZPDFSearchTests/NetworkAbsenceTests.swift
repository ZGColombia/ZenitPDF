import Foundation
import Testing

@testable import ZPDFSearch

/// Spec 17.4: "local only; no cloud OCR". This suite is what makes that a fact rather than
/// an intention.
///
/// Two independent checks, because either one alone is weak:
///
/// 1. **Source scan.** No file in `Sources/` mentions a networking API. Catches the case
///    where someone adds `URLSession` tomorrow, and catches it in a readable way.
/// 2. **Symbol scan.** The compiled object files carry no undefined symbol from any
///    networking framework. Catches what the source scan cannot: a networking call
///    reached indirectly, through a dependency or a differently spelled API.
///
/// Neither check may silently pass by finding nothing to look at. If the object files
/// cannot be located, the test fails.
@Suite("No network")
struct NetworkAbsenceTests {

    /// The package root, found from this file rather than from a working directory that
    /// `swift test` does not promise anything about.
    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ZPDFSearchTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ZPDFSearch

    /// Networking, subprocess execution and dynamic loading, spelled the way they appear
    /// in Swift source.
    static let forbiddenSourcePatterns = [
        "URLSession", "NSURLConnection", "CFURLRequest", "URLRequest",
        "NWConnection", "NWBrowser", "NWListener", "CFSocket", "getaddrinfo",
        "import Network", "import CFNetwork", "import CoreServices",
        "Process(", "posix_spawn", "execve", "NSTask", "NSAppleScript",
        "dlopen", "dlsym", "PDFView", "JSContext", "WKWebView"
    ]

    /// Undefined symbols that would appear if anything in the library reached a network.
    ///
    /// Matched as substrings of the mangled names `nm -u` reports, so
    /// `_$s10Foundation10URLSessionC` is caught by `URLSession`.
    static let forbiddenSymbolFragments = [
        "URLSession", "NSURLConnection", "CFURLRequest", "CFURLConnection",
        "CFNetwork", "nw_connection", "nw_endpoint", "nw_listener", "nw_browser",
        "_socket", "_connect", "_getaddrinfo", "_gethostbyname", "_send", "_recv",
        "_dlopen", "_dlsym", "_posix_spawn", "_execve", "_fork"
    ]

    @Test("No source file in the library target mentions a networking API")
    func sourcesAreClean() throws {
        let sources = Self.packageRoot.appendingPathComponent("Sources", isDirectory: true)
        let files = try Self.swiftFiles(under: sources)
        #expect(files.count >= 10, "found only \(files.count) source files; the scan is looking in the wrong place")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = String(line)
                // A pattern named inside a doc comment is documentation, not a call.
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for pattern in Self.forbiddenSourcePatterns where code.contains(pattern) {
                    Issue.record(
                        "\(file.lastPathComponent):\(number + 1) mentions \(pattern): \(trimmed)"
                    )
                }
            }
        }
    }

    @Test("The compiled library links no networking, subprocess or dynamic-loading symbol")
    func symbolsAreClean() throws {
        let objects = try Self.builtObjectFiles()
        #expect(
            !objects.isEmpty,
            "no ZPDFSearch object files under \(Self.objectDirectoryDescription) — build the package first"
        )

        var scanned = 0
        for object in objects {
            let undefined = try Self.undefinedSymbols(of: object)
            // An object with no undefined symbols at all would mean `nm` did not read it.
            #expect(!undefined.isEmpty, "\(object.lastPathComponent) reported no symbols")
            scanned += 1
            for symbol in undefined {
                for fragment in Self.forbiddenSymbolFragments where symbol.contains(fragment) {
                    Issue.record("\(object.lastPathComponent) references \(symbol) (matched \(fragment))")
                }
            }
        }
        #expect(scanned >= 1)
        print("[ZPDFSearch] symbol scan: \(scanned) object files, no networking symbols")
    }

    @Test("Vision and CoreGraphics are the only heavyweight frameworks the library needs")
    func frameworksAreExpected() throws {
        let objects = try Self.builtObjectFiles()
        #expect(!objects.isEmpty)
        var sawVision = false
        for object in objects {
            let undefined = try Self.undefinedSymbols(of: object)
            if undefined.contains(where: { $0.contains("VNRecognizeTextRequest") }) { sawVision = true }
        }
        #expect(sawVision, "the recogniser is not linked, so the OCR path cannot be doing anything")
    }

    // MARK: - Plumbing

    static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The SwiftPM products directory this test bundle was built into and is running from.
    ///
    /// Derived from the loaded `.xctest` bundle rather than assumed to be `<package>/.build`,
    /// so a build with `--scratch-path` scans its own objects, and the objects scanned are the
    /// ones linked into the binary running this test — never a stale build left in another
    /// scratch directory. `nil` when the test is not running from an `.xctest` bundle; the
    /// callers then find no objects and fail.
    static let productsDirectory: URL? = {
        let bundle = Bundle(for: BundleLocator.self).bundleURL
        guard bundle.pathExtension == "xctest" else { return nil }
        return bundle.deletingLastPathComponent()
    }()

    /// Where the `ZPDFSearch` objects are looked for, for failure messages.
    static var objectDirectoryDescription: String {
        guard let products = productsDirectory else {
            return "the products directory (the test is not running from an .xctest bundle: "
                + "\(Bundle(for: BundleLocator.self).bundleURL.path))"
        }
        return "\(products.path) (ZPDFSearch.build/ or ZPDFSearch.o)"
    }

    /// The object files SwiftPM produced for the `ZPDFSearch` library target, in the products
    /// directory the test bundle sits in. Both SwiftPM build systems are covered:
    ///
    /// * the native build system writes one `.o` per source file to `ZPDFSearch.build/`;
    /// * Swift Build writes the target as one relocatable `ZPDFSearch.o`, which is the object
    ///   the test bundle links.
    ///
    /// Only the library target is collected; the test target's own objects are not.
    static func builtObjectFiles() throws -> [URL] {
        guard let products = productsDirectory else { return [] }
        let fileManager = FileManager.default
        var objects: [URL] = []

        let perFile = products.appendingPathComponent("ZPDFSearch.build", isDirectory: true)
        if let enumerator = fileManager.enumerator(at: perFile, includingPropertiesForKeys: nil) {
            objects += enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "o" }
        }

        let prelinked = products.appendingPathComponent("ZPDFSearch.o", isDirectory: false)
        if fileManager.fileExists(atPath: prelinked.path) {
            objects.append(prelinked)
        }
        return objects
    }

    /// `nm -u`, as a set of symbol names.
    ///
    /// A subprocess in a *test* is fine; the rule the package obeys is that its **library**
    /// target cannot spawn one, and `sourcesAreClean` is what enforces that.
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
        let text = String(decoding: data, as: UTF8.self)
        return Set(
            text.split(separator: "\n").map {
                String($0.trimmingCharacters(in: .whitespaces))
            }.filter { !$0.isEmpty }
        )
    }
}

/// Anchors `Bundle(for:)` to the test bundle that contains this file.
private final class BundleLocator {}
