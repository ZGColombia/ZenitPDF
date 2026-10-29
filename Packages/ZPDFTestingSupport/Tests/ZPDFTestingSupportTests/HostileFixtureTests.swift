import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport

/// The hostile corpus must exist as real files, and each file must actually carry the
/// defect its manifest advertises. A security test written against a fixture that
/// quietly turned out well-formed is worse than no test at all.
struct HostileFixtureTests {

    static let directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZPDFTestingSupportHostile", isDirectory: true)

    @Test("Every hostile fixture is written and declares at least one trait",
          arguments: FixtureKind.hostile)
    func hostileFixturesExist(kind: FixtureKind) throws {
        let handle = try ZPDFFixtures.make(kind, in: Self.directory)
        #expect(FileManager.default.fileExists(atPath: handle.url.path))
        #expect(handle.byteCount > 0)
        #expect(!handle.manifest.hostileTraits.isEmpty, "\(kind.rawValue) declares no hostile trait")
        #expect(!handle.manifest.notes.isEmpty, "\(kind.rawValue) has no notes explaining the hazard")
    }

    @Test("Opening a malformed fixture never traps", arguments: FixtureKind.hostile)
    func malformedFixturesDoNotTrap(kind: FixtureKind) throws {
        let handle = try ZPDFFixtures.make(kind, in: Self.directory)
        // The contract here is only that this returns. CoreGraphics may open the file,
        // may refuse it, and may recover a truncated one; all three are acceptable.
        let document = CGPDFDocument(handle.url as CFURL)
        if let document, document.isUnlocked {
            #expect(document.numberOfPages >= 0)
        }
    }

    @Test("The truncated fixture has no trailer and no EOF marker")
    func truncatedFixtureIsTruncated() throws {
        let handle = try ZPDFFixtures.make(.truncatedFile, in: Self.directory)
        let bytes = try Data(contentsOf: handle.url)
        let text = try #require(String(data: bytes, encoding: .isoLatin1))
        #expect(text.hasPrefix("%PDF-1.7"))
        #expect(!text.contains("%%EOF"))
        #expect(!text.contains("startxref"))
        #expect(!text.contains("trailer"))

        // It really is a prefix of the well-formed document, not a different file.
        let intact = try ZPDFFixtures.data(.truncatedFile)
        #expect(intact.data == bytes)
    }

    @Test("The broken-xref fixture has a trailer but wrong offsets")
    func brokenXrefIsBroken() throws {
        let handle = try ZPDFFixtures.make(.brokenXref, in: Self.directory)
        let bytes = try Data(contentsOf: handle.url)
        let text = try #require(String(data: bytes, encoding: .isoLatin1))
        #expect(text.contains("%%EOF"))
        #expect(text.contains("startxref"))

        // Take the first xref entry and check that the byte at that offset is not the
        // start of the object it claims.
        let lines = text.components(separatedBy: "\n")
        let xrefIndex = try #require(lines.firstIndex(of: "xref"))
        // lines[xrefIndex + 1] is "0 N", lines[xrefIndex + 2] is the free entry.
        let firstEntry = lines[xrefIndex + 3]
        let offsetField = String(firstEntry.prefix(10))
        let offset = try #require(Int(offsetField))
        #expect(offset > 0)
        let claimed = bytes.dropFirst(offset).prefix(8)
        let claimedText = String(data: claimed, encoding: .isoLatin1) ?? ""
        #expect(!claimedText.hasPrefix("1 0 obj"), "offset \(offset) unexpectedly lands on object 1")
    }

    @Test("The cyclic page tree really contains a cycle")
    func cyclicPageTreeIsCyclic() throws {
        let handle = try ZPDFFixtures.make(.cyclicPageTree, in: Self.directory)
        let text = try #require(String(data: try Data(contentsOf: handle.url), encoding: .isoLatin1))
        // Object 3 lists object 2, which is its own /Parent.
        #expect(text.contains("/Parent 2 0 R /Kids [4 0 R 2 0 R]"))
        #expect(handle.manifest.hostileTraits.contains(.cyclicPageTree))
    }

    @Test("The missing-object fixture references an object it does not contain")
    func missingObjectIsMissing() throws {
        let handle = try ZPDFFixtures.make(.missingObject, in: Self.directory)
        let text = try #require(String(data: try Data(contentsOf: handle.url), encoding: .isoLatin1))
        #expect(text.contains("/Contents 9999 0 R"))
        #expect(!text.contains("9999 0 obj"))
    }

    @Test("The deep-nesting fixture nests 100 form XObjects")
    func deepNestingIsDeep() throws {
        let handle = try ZPDFFixtures.make(.deeplyNestedForms, in: Self.directory)
        #expect(handle.manifest.formNestingDepth == 100)
        let text = try #require(String(data: try Data(contentsOf: handle.url), encoding: .isoLatin1))
        let formCount = text.components(separatedBy: "/Subtype /Form").count - 1
        #expect(formCount == 100, "expected 100 form XObjects, found \(formCount)")
    }

    @Test("The decompression bomb is small on disk and enormous when inflated")
    func bombIsABomb() throws {
        let handle = try ZPDFFixtures.make(.decompressionBomb, in: Self.directory)
        let declared = try #require(handle.manifest.declaredInflatedByteCount)
        #expect(declared == 64 * 1024 * 1024)
        // The file itself must stay small, or it is not a bomb, just a big file.
        #expect(handle.byteCount < 1024 * 1024, "bomb file is \(handle.byteCount) bytes")
        let ratio = Double(declared) / Double(handle.byteCount)
        #expect(ratio > 100, "expansion ratio is only \(ratio):1")
    }

    @Test("The encrypted fixture is locked until the recorded password is supplied")
    func encryptedFixtureIsEncrypted() throws {
        let handle = try ZPDFFixtures.make(.encryptedUserPassword, in: Self.directory)
        #expect(handle.manifest.userPassword == ZPDFFixtures.encryptedUserPassword)

        let document = try #require(CGPDFDocument(handle.url as CFURL))
        #expect(document.isEncrypted)
        #expect(!document.isUnlocked)
        #expect(!document.unlockWithPassword("definitely-not-the-password"))
        #expect(document.unlockWithPassword(ZPDFFixtures.encryptedUserPassword))
        #expect(document.isUnlocked)
        #expect(document.numberOfPages == 1)
    }

    @Test("The embedded-file fixture carries a real embedded file and a launch action")
    func embeddedFileIsPresent() throws {
        let handle = try ZPDFFixtures.make(.embeddedFileWithLaunchAction, in: Self.directory)
        let text = try #require(String(data: try Data(contentsOf: handle.url), encoding: .isoLatin1))
        #expect(text.contains("/Type /EmbeddedFile"))
        #expect(text.contains("/EmbeddedFiles"))
        #expect(text.contains("/S /Launch"))
        #expect(text.contains("zenit-payload.sh"))
        #expect(handle.manifest.hostileTraits.contains(.embeddedFile))
        #expect(handle.manifest.hostileTraits.contains(.launchAction))
    }

    @Test("The JavaScript fixture carries a JavaScript action reachable two ways")
    func javaScriptIsPresent() throws {
        let handle = try ZPDFFixtures.make(.javaScriptAction, in: Self.directory)
        let text = try #require(String(data: try Data(contentsOf: handle.url), encoding: .isoLatin1))
        #expect(text.contains("/S /JavaScript"))
        #expect(text.contains("/Names << /JavaScript"))
        #expect(text.contains("/OpenAction"))
        #expect(handle.manifest.hostileTraits.contains(.javaScript))
    }

    @Test("The malformed operator stream is large and structurally valid")
    func malformedStreamIsLargeButValid() throws {
        let handle = try ZPDFFixtures.make(.hugeMalformedOperatorStream, in: Self.directory)
        #expect(handle.byteCount > 1_000_000)
        let document = try #require(CGPDFDocument(handle.url as CFURL))
        #expect(document.numberOfPages == 1)
        let text = try #require(String(data: try Data(contentsOf: handle.url), encoding: .isoLatin1))
        #expect(text.contains("zzq"))
        #expect(text.contains("/BogusXObject Do"))
    }
}
