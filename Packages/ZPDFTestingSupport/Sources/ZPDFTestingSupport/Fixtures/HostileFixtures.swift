import CoreGraphics
import Foundation

/// The hostile corpus.
///
/// These are real files, not descriptions of files, so a security test can be an
/// actual test. Nothing here is dangerous to *generate*; the danger is entirely in
/// what a reader might do with it, which is the point.
enum HostileFixtures {

    static let page = FixturePageSize.letter

    /// The user password of `.encryptedUserPassword`.
    static let userPassword = "zenit-fixture-user"
    /// The owner password of `.encryptedUserPassword`. CoreGraphics requires both.
    static let ownerPassword = "zenit-fixture-owner"

    /// How many bytes the decompression bomb's content stream inflates to.
    static let bombInflatedByteCount = 64 * 1024 * 1024

    /// Nesting depth of `.deeplyNestedForms`.
    static let deepFormDepth = 100

    // MARK: - Truncated

    static func truncatedFile() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .truncatedFile,
            title: "Valid document cut off at 55 % of its length",
            purpose: "There is no trailer, no startxref and no %%EOF. A reader must report a "
                + "typed error rather than scanning to the end of memory looking for one.",
            fileName: FixtureKind.truncatedFile.fileName,
            pageCount: 2,
            pages: [
                FixturePage(index: 0, mediaBox: page),
                FixturePage(index: 1, mediaBox: page)
            ],
            hostileTraits: [.truncated],
            isStructurallyValid: false,
            notes: [
                "The prefix that survives is byte-identical to the first 55 % of a well-formed "
                    + "two-page document, so the failure is purely a missing tail."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .truncatedFile)
            for index in 0..<2 {
                var content = PDFContentStream()
                content.setLineWidth(1)
                content.setStrokeGray(0)
                content.move(to: FixturePoint(72, 72 + Double(index) * 20))
                content.line(to: FixturePoint(472, 72 + Double(index) * 20))
                content.stroke()
                let contents = try builder.addContentStream(content)
                builder.addPage(mediaBox: page, contentObject: contents)
            }
            return try builder.data(corruption: .truncate(keepFraction: 0.55))
        }
    }

    // MARK: - Broken cross-reference table

    static func brokenXref() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .brokenXref,
            title: "Correct objects, cross-reference offsets wrong by 37 bytes",
            purpose: "Every offset in the xref table points 37 bytes past the object it claims. "
                + "A reader that trusts the table finds garbage; one that reconstructs the table "
                + "recovers the document. Either outcome is acceptable — a crash is not.",
            fileName: FixtureKind.brokenXref.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            hostileTraits: [.brokenCrossReferenceTable],
            isStructurallyValid: false,
            notes: [
                "The trailer, /Root and %%EOF are all present and correct.",
                "37 is prime and larger than any object header here, so no offset accidentally "
                    + "lands on a valid `N 0 obj` boundary."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .brokenXref)
            var content = PDFContentStream()
            content.setLineWidth(1)
            content.setStrokeGray(0)
            content.appendRing(FixtureRect(x: 72, y: 72, width: 200, height: 100).counterClockwiseCorners, close: true)
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data(corruption: .shiftCrossReferenceOffsets(delta: 37))
        }
    }

    // MARK: - Cyclic page tree

    static func cyclicPageTree() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .cyclicPageTree,
            title: "Page tree whose child lists its own ancestor as a kid",
            purpose: "A depth-first walk that does not track visited nodes recurses forever. The "
                + "reader must bound its traversal and return a typed error or a truncated tree.",
            fileName: FixtureKind.cyclicPageTree.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            hostileTraits: [.cyclicPageTree],
            isStructurallyValid: false,
            notes: [
                "Object 2 is /Pages with /Kids [3 0 R].",
                "Object 3 is /Pages with /Kids [4 0 R 2 0 R] — the second kid is its own parent.",
                "Object 4 is the one real page.",
                "/Count claims 2 while only one page exists, so a reader that trusts /Count "
                    + "allocates for a page it will never find."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let table = PDFObjectTable()
            let catalog = table.reserve()      // 1
            let rootPages = table.reserve()    // 2
            let childPages = table.reserve()   // 3
            let pageObject = table.reserve()   // 4

            var content = PDFContentStream()
            content.setLineWidth(1)
            content.setStrokeGray(0)
            content.move(to: FixturePoint(72, 72))
            content.line(to: FixturePoint(372, 72))
            content.stroke()
            let contents = table.add(
                .stream(dictionaryEntries: "", data: try content.data(kind: .cyclicPageTree))
            )
            let info = table.add(
                "<< /Producer (ZPDFTestingSupport) /Title (hostile-cyclic-page-tree) "
                    + "/CreationDate (D:20260101000000Z) >>"
            )

            table.set(catalog, "<< /Type /Catalog /Pages \(rootPages) 0 R >>")
            table.set(rootPages, "<< /Type /Pages /Kids [\(childPages) 0 R] /Count 2 >>")
            table.set(
                childPages,
                "<< /Type /Pages /Parent \(rootPages) 0 R "
                    + "/Kids [\(pageObject) 0 R \(rootPages) 0 R] /Count 2 >>"
            )
            table.set(
                pageObject,
                "<< /Type /Page /Parent \(childPages) 0 R /MediaBox \(PDFNumber.array(page)) "
                    + "/Resources << >> /Contents \(contents) 0 R >>"
            )

            var writer = RawPDFWriter(
                kind: .cyclicPageTree,
                objectCount: table.count,
                rootObject: catalog,
                body: table.provider(kind: .cyclicPageTree)
            )
            writer.infoObject = info
            return try writer.data()
        }
    }

    // MARK: - Declared but missing object

    /// An object number the file deliberately does not contain.
    static let missingObjectNumber = 9_999

    static func missingObject() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .missingObject,
            title: "Page whose /Contents and /Font point at object 9999, which does not exist",
            purpose: "A dangling indirect reference must resolve to null, not to a wild read. "
                + "The page itself is otherwise perfectly formed.",
            fileName: FixtureKind.missingObject.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            hostileTraits: [.missingObject],
            isStructurallyValid: false,
            notes: [
                "/Size in the trailer counts only the objects that exist, so the reference is "
                    + "out of range as well as absent.",
                "That dangling reference is the only defect: every object the xref table lists "
                    + "(1 ... /Size - 1) has its body in the file, including the page tree at object 2."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let table = PDFObjectTable()
            let catalog = table.reserve()   // 1
            let pages = table.reserve()     // 2
            let pageObject = table.reserve()

            let info = table.add(
                "<< /Producer (ZPDFTestingSupport) /Title (hostile-missing-object) "
                    + "/CreationDate (D:20260101000000Z) >>"
            )
            table.set(catalog, "<< /Type /Catalog /Pages \(pages) 0 R >>")
            table.set(pages, "<< /Type /Pages /Kids [\(pageObject) 0 R] /Count 1 >>")
            table.set(
                pageObject,
                "<< /Type /Page /Parent \(pages) 0 R /MediaBox \(PDFNumber.array(page)) "
                    + "/Resources << /Font << /F1 \(missingObjectNumber) 0 R >> >> "
                    + "/Contents \(missingObjectNumber) 0 R >>"
            )

            var writer = RawPDFWriter(
                kind: .missingObject,
                objectCount: table.count,
                rootObject: catalog,
                body: table.provider(kind: .missingObject)
            )
            writer.infoObject = info
            return try writer.data()
        }
    }

    // MARK: - Deeply nested form XObjects

    static func deeplyNestedForms() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .deeplyNestedForms,
            title: "\(deepFormDepth) levels of form XObjects, each drawing the next",
            purpose: "Recursion depth. An extractor must impose and enforce a nesting cap, and "
                + "must not blow the stack getting there.",
            fileName: FixtureKind.deeplyNestedForms.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            formNestingDepth: deepFormDepth,
            hostileTraits: [.deeplyNestedForms],
            notes: [
                "Each form's /Matrix is [1 0 0 1 1 1], so the innermost line is translated by "
                    + "exactly (\(deepFormDepth), \(deepFormDepth)) relative to the page CTM. An "
                    + "extractor that stops early lands short of that by the number of levels it "
                    + "skipped, which makes the truncation depth directly measurable.",
                "The innermost form draws a line from (0, 0) to (50, 0); in page space that is "
                    + "(\(deepFormDepth), \(deepFormDepth)) to (\(deepFormDepth + 50), \(deepFormDepth)).",
                "The file is structurally valid: the hostility is depth, not corruption."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .deeplyNestedForms)
            let step = FixtureMatrix(a: 1, b: 0, c: 0, d: 1, e: 1, f: 1)
            let bbox = FixtureRect(llx: 0, lly: 0, urx: 400, ury: 400)

            var innerContent = PDFContentStream()
            innerContent.setLineWidth(1)
            innerContent.setStrokeGray(0)
            innerContent.move(to: FixturePoint(0, 0))
            innerContent.line(to: FixturePoint(50, 0))
            innerContent.stroke()
            var current = try builder.addFormXObject(
                bbox: bbox,
                matrix: step,
                resources: "<< >>",
                content: innerContent
            )

            // Levels deepFormDepth-1 down to 1, each drawing the level below it.
            var level = deepFormDepth - 1
            while level >= 1 {
                var content = PDFContentStream()
                content.drawXObject(named: "Nested")
                current = try builder.addFormXObject(
                    bbox: bbox,
                    matrix: step,
                    resources: "<< /XObject << /Nested \(current) 0 R >> >>",
                    content: content
                )
                level -= 1
            }

            var pageContent = PDFContentStream()
            pageContent.drawXObject(named: "Nested")
            let contents = try builder.addContentStream(pageContent)
            builder.addPage(
                mediaBox: page,
                resources: "<< /XObject << /Nested \(current) 0 R >> >>",
                contentObject: contents
            )
            return try builder.data()
        }
    }

    // MARK: - Decompression bomb

    static func decompressionBomb() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .decompressionBomb,
            title: "A small file whose page content stream inflates to 64 MiB",
            purpose: "Decompression must be capped. A reader that inflates a content stream into "
                + "an unbounded buffer allocates 64 MiB from a file of a few dozen kilobytes.",
            fileName: FixtureKind.decompressionBomb.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            hostileTraits: [.decompressionBomb],
            declaredInflatedByteCount: bombInflatedByteCount,
            notes: [
                "The declared /Length is the *compressed* length, as the format requires, so the "
                    + "inflated size is not discoverable without inflating.",
                "The inflated payload is valid PDF content syntax, so a reader cannot bail out on "
                    + "a syntax error before it has already allocated.",
                "Expansion ratio is roughly 1000:1."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .decompressionBomb)
            let unit = "0 0 m 1 1 l S\n"
            let unitBytes = unit.utf8.count
            let repetitions = bombInflatedByteCount / unitBytes
            guard let unitData = unit.data(using: .isoLatin1) else {
                throw FixtureError.encodingFailed(kind: .decompressionBomb, reason: "payload unit")
            }
            var payload = Data(capacity: bombInflatedByteCount)
            // Doubling keeps the number of appends logarithmic in the payload size.
            payload.append(unitData)
            while payload.count * 2 <= repetitions * unitBytes {
                payload.append(payload)
            }
            while payload.count + unitBytes <= repetitions * unitBytes {
                payload.append(unitData)
            }
            // 14 does not divide 64 MiB; pad the remainder with spaces, which are
            // valid content-stream whitespace, so the stream inflates to exactly the
            // `declaredInflatedByteCount` the manifest records.
            let remainder = bombInflatedByteCount - payload.count
            if remainder > 0 {
                payload.append(Data(repeating: 0x20, count: remainder))
            }
            guard payload.count == bombInflatedByteCount else {
                throw FixtureError.generationFailed(
                    kind: .decompressionBomb,
                    reason: "payload is \(payload.count) bytes, declared \(bombInflatedByteCount)"
                )
            }
            let compressed = try PDFFlate.zlibStream(payload, kind: .decompressionBomb)
            payload = Data()
            let contents = builder.addStream(entries: "/Filter /FlateDecode", data: compressed)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: - Encrypted

    static func encryptedUserPassword() throws -> FixtureBuild {
        let path = FixturePath(
            id: "encrypted-line",
            pageIndex: 0,
            kind: .openPolyline,
            points: [FixturePoint(100, 100), FixturePoint(400, 500)],
            length: 500,
            area: 0,
            derivation: .closedForm(
                "sqrt(300^2 + 400^2) = 500. The same 3-4-5 line as the plain single-line "
                    + "fixture, so a decrypted extraction can be compared against it directly.",
                magnitudeFloor: 500
            )
        )

        let manifest = FixtureManifest(
            kind: .encryptedUserPassword,
            title: "Encrypted document, user password \"\(userPassword)\"",
            purpose: "Opening without a password must fail with a typed error and must never "
                + "prompt. Opening with the recorded password must yield the same geometry as the "
                + "plain single-line fixture.",
            fileName: FixtureKind.encryptedUserPassword.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            paths: [path],
            hostileTraits: [.encrypted],
            userPassword: userPassword,
            notes: [
                "Owner password: \"\(ownerPassword)\".",
                "Produced by CoreGraphics' CGPDFContext with kCGPDFContextUserPassword, so the "
                    + "encryption dictionary is whatever the current OS emits rather than a "
                    + "hand-rolled one that might not match any real writer.",
                "This is the only fixture in the corpus that CoreGraphics writes, and therefore "
                    + "the only one whose byte layout is not fixed by ZPDFTestingSupport."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            try encryptedDocumentData()
        }
    }

    private static func encryptedDocumentData() throws -> Data {
        guard let buffer = CFDataCreateMutable(nil, 0) else {
            throw FixtureError.encryptedContextUnavailable
        }
        guard let consumer = CGDataConsumer(data: buffer) else {
            throw FixtureError.encryptedContextUnavailable
        }
        var mediaBox = CGRect(x: page.llx, y: page.lly, width: page.width, height: page.height)
        let auxiliary: [CFString: Any] = [
            kCGPDFContextUserPassword: userPassword,
            kCGPDFContextOwnerPassword: ownerPassword,
            kCGPDFContextAllowsPrinting: false,
            kCGPDFContextAllowsCopying: false,
            kCGPDFContextTitle: FixtureKind.encryptedUserPassword.rawValue,
            kCGPDFContextCreator: "ZPDFTestingSupport"
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, auxiliary as CFDictionary) else {
            throw FixtureError.encryptedContextUnavailable
        }
        context.beginPDFPage(nil)
        context.setLineWidth(1)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.move(to: CGPoint(x: 100, y: 100))
        context.addLine(to: CGPoint(x: 400, y: 500))
        context.strokePath()
        context.endPDFPage()
        context.closePDF()
        return buffer as Data
    }

    // MARK: - Embedded file and launch action

    static let embeddedFileName = "zenit-payload.sh"
    static let embeddedFileContents = "#!/bin/sh\necho \"ZPDFTestingSupport inert payload\"\n"

    static func embeddedFileWithLaunchAction() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .embeddedFileWithLaunchAction,
            title: "Embedded shell script plus a /Launch open action",
            purpose: "Zenit must never execute, extract or offer to open an embedded file, and "
                + "must never honour a /Launch action. This file makes that testable.",
            fileName: FixtureKind.embeddedFileWithLaunchAction.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            hostileTraits: [.embeddedFile, .launchAction],
            notes: [
                "Embedded file name: \(embeddedFileName).",
                "The payload is inert — it echoes a string — but it is a real /EmbeddedFile "
                    + "stream reachable through /Names /EmbeddedFiles.",
                "/OpenAction is << /S /Launch /F (\(embeddedFileName)) >>.",
                "A reader that surfaces the attachment in a UI has already failed this test."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .embeddedFileWithLaunchAction)
            guard let payload = embeddedFileContents.data(using: .isoLatin1) else {
                throw FixtureError.encodingFailed(
                    kind: .embeddedFileWithLaunchAction,
                    reason: "payload is not Latin-1"
                )
            }
            let embedded = builder.addStream(
                entries: "/Type /EmbeddedFile /Subtype /application#2Fx-sh /Params << /Size \(payload.count) >>",
                data: payload
            )
            let fileName = try PDFSyntax.literalString(embeddedFileName, kind: .embeddedFileWithLaunchAction)
            let filespec = builder.addObject(
                "<< /Type /Filespec /F \(fileName) /UF \(fileName) /EF << /F \(embedded) 0 R >> >>"
            )
            let launch = builder.addObject("<< /Type /Action /S /Launch /F \(fileName) >>")
            builder.catalogExtraEntries =
                "/OpenAction \(launch) 0 R "
                + "/Names << /EmbeddedFiles << /Names [\(fileName) \(filespec) 0 R] >> >>"

            var content = PDFContentStream()
            content.setLineWidth(1)
            content.setStrokeGray(0)
            content.move(to: FixturePoint(72, 72))
            content.line(to: FixturePoint(372, 72))
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: - JavaScript

    static let javaScriptSource = "app.alert('ZPDFTestingSupport javascript fixture');"

    static func javaScriptAction() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .javaScriptAction,
            title: "Document-level JavaScript name tree and an /OpenAction",
            purpose: "Zenit executes no PDF JavaScript, ever. This file gives that assertion "
                + "something to assert against.",
            fileName: FixtureKind.javaScriptAction.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            hostileTraits: [.javaScript],
            notes: [
                "The script is `\(javaScriptSource)` — harmless, and observable if it ever runs.",
                "It is reachable twice: through /Names /JavaScript and through /OpenAction.",
                "The page also carries a /Widget-free /Annots-free body, so the JavaScript is the "
                    + "only active content in the file."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .javaScriptAction)
            let source = try PDFSyntax.literalString(javaScriptSource, kind: .javaScriptAction)
            let action = builder.addObject("<< /Type /Action /S /JavaScript /JS \(source) >>")
            let name = try PDFSyntax.literalString("ZenitFixtureScript", kind: .javaScriptAction)
            builder.catalogExtraEntries =
                "/OpenAction \(action) 0 R "
                + "/Names << /JavaScript << /Names [\(name) \(action) 0 R] >> >>"

            var content = PDFContentStream()
            content.setLineWidth(1)
            content.setStrokeGray(0)
            content.move(to: FixturePoint(72, 72))
            content.line(to: FixturePoint(372, 72))
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }
}
