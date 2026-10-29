import Foundation

/// Fixtures that model a construction drawing *set* rather than one sheet: sheet numbers in the
/// title block and in `/PageLabels`, a bookmark tree, named destinations, links between sheets,
/// and body text that cites other sheets (NL-DOCS-01).
enum SheetSetFixtures {

    static let sheetBox = FixturePageSize.archD
    static let borderRect = FixtureRect(llx: 36, lly: 36, urx: 1692, ury: 2556)
    static let titleBlockRect = FixtureRect(llx: 1128, lly: 36, urx: 1692, ury: 288)
    /// Around the sheet number (36 pt Helvetica on the baseline y = 80).
    static let numberRegion = FixtureRect(llx: 1140, lly: 66, urx: 1500, ury: 124)
    /// Around the sheet title (16 pt Helvetica on the baseline y = 206).
    static let titleRegion = FixtureRect(llx: 1140, lly: 196, urx: 1680, ury: 230)

    static let disciplines: [(letter: String, first: Int, group: String, titles: [String])] = [
        ("A", 101, "ARCHITECTURAL", [
            "SITE PLAN", "FLOOR PLAN LEVEL 1", "FLOOR PLAN LEVEL 2", "FLOOR PLAN LEVEL 3",
            "ROOF PLAN", "ELEVATIONS NORTH SOUTH", "ELEVATIONS EAST WEST", "BUILDING SECTIONS",
            "WALL SECTIONS", "DOOR SCHEDULE"
        ]),
        ("S", 201, "STRUCTURAL", [
            "FOUNDATION PLAN", "FRAMING PLAN LEVEL 1", "FRAMING PLAN LEVEL 2", "FRAMING PLAN LEVEL 3",
            "ROOF FRAMING PLAN", "STEEL DETAILS", "CONCRETE DETAILS", "FOUNDATION DETAILS",
            "CONNECTION DETAILS", "GENERAL NOTES"
        ]),
        ("M", 301, "MECHANICAL", [
            "MECHANICAL PLAN LEVEL 1", "MECHANICAL PLAN LEVEL 2", "MECHANICAL PLAN LEVEL 3",
            "ROOF MECHANICAL PLAN", "DUCTWORK RISER", "PIPING PLAN", "PLUMBING PLAN",
            "EQUIPMENT SCHEDULE", "MECHANICAL DETAILS", "CONTROLS DIAGRAM"
        ])
    ]

    /// Every sheet, in page order.
    static let sheets: [FixtureSheet] = {
        var out: [FixtureSheet] = []
        for discipline in disciplines {
            for (offset, title) in discipline.titles.enumerated() {
                out.append(FixtureSheet(
                    pageIndex: out.count,
                    number: "\(discipline.letter)-\(discipline.first + offset)",
                    title: title,
                    discipline: discipline.letter
                ))
            }
        }
        return out
    }()

    /// The sheet cited by "SEE …" on page `i`: ten sheets on, wrapping.
    static func seeTarget(_ i: Int) -> Int { (i + 10) % 30 }
    /// The sheet cited by "3/…" on page `i`: the next sheet, wrapping.
    static func detailTarget(_ i: Int) -> Int { (i + 1) % 30 }

    /// A link's rectangle around text of `count` glyphs at `origin` and `size`: Helvetica's
    /// widest capitals are 0.722 em, so 0.75 em per glyph always covers the run; 4 pt margin.
    static func linkRect(at origin: FixturePoint, glyphs count: Int, size: Double) -> FixtureRect {
        FixtureRect(
            llx: origin.x - 4,
            lly: origin.y - 4,
            urx: origin.x + Double(count) * size * 0.75 + 4,
            ury: origin.y + size + 4
        )
    }

    static let seeOrigin = FixturePoint(200, 2200)
    static let detailOrigin = FixturePoint(200, 2100)
    static let extraOrigin = FixturePoint(200, 2000)
    static let reviewOrigin = FixturePoint(200, 1900)
    static let bodySize: Double = 14
    static let uri = "https://example.invalid/specification"
    static let javaScript = "app.alert(1)"

    static func thirtySheets() throws -> FixtureBuild {
        let kind = FixtureKind.set30SheetsTitleBlocks
        var texts: [FixtureText] = []
        var links: [FixtureLink] = []
        var references: [FixtureSheetReference] = []
        var bodies: [Int: [(id: String, text: String, origin: FixturePoint, size: Double, titleBlock: Bool)]] = [:]

        for sheet in sheets {
            let i = sheet.pageIndex
            let see = sheets[seeTarget(i)]
            let detail = sheets[detailTarget(i)]
            var strings: [(id: String, text: String, origin: FixturePoint, size: Double, titleBlock: Bool)] = [
                ("project", "PROJECT ZENIT FIXTURE SET", FixturePoint(1152, 262), 12, true),
                ("title", sheet.title, FixturePoint(1152, 206), 16, true),
                ("sheet-caption", "SHEET", FixturePoint(1152, 150), 10, true),
                ("scale", "SCALE 1:100", FixturePoint(1400, 150), 10, true),
                ("number", sheet.number, FixturePoint(1152, 80), 36, true),
                ("see", "SEE \(see.number)", seeOrigin, bodySize, false),
                ("detail", "3/\(detail.number)", detailOrigin, bodySize, false)
            ]
            // Every fifth link keeps a scroll position, the rest fit the page.
            let keepsPosition = i % 5 == 0
            links.append(FixtureLink(
                pageIndex: i,
                rect: linkRect(at: seeOrigin, glyphs: 4 + see.number.count, size: bodySize),
                target: .page(index: see.pageIndex, left: keepsPosition ? 144 : nil, top: keepsPosition ? 2400 : nil)
            ))
            links.append(FixtureLink(
                pageIndex: i,
                rect: linkRect(at: detailOrigin, glyphs: 2 + detail.number.count, size: bodySize),
                target: .named(detail.number)
            ))
            references.append(FixtureSheetReference(pageIndex: i, text: "SEE \(see.number)", citedSheet: see.number, resolves: true))
            references.append(FixtureSheetReference(pageIndex: i, text: "3/\(detail.number)", citedSheet: detail.number, resolves: true))
            if i == 0 {
                strings.append(("specification", "SPECIFICATION", extraOrigin, bodySize, false))
                links.append(FixtureLink(
                    pageIndex: i,
                    rect: linkRect(at: extraOrigin, glyphs: 13, size: bodySize),
                    target: .uri(uri)
                ))
            }
            if i == 29 {
                // A reference to a sheet the set does not contain: no link, and a QA finding.
                strings.append(("missing", "5/A-999", extraOrigin, bodySize, false))
                references.append(FixtureSheetReference(pageIndex: i, text: "5/A-999", citedSheet: "A-999", resolves: false))
                strings.append(("review", "REVIEW NOTE", reviewOrigin, bodySize, false))
                links.append(FixtureLink(
                    pageIndex: i,
                    rect: linkRect(at: reviewOrigin, glyphs: 11, size: bodySize),
                    target: .javaScript(javaScript)
                ))
            }
            bodies[i] = strings
            for entry in strings {
                texts.append(FixtureText(
                    id: "p\(i)-\(entry.id)",
                    pageIndex: i,
                    string: entry.text,
                    origin: entry.origin,
                    fontSize: entry.size,
                    fontName: "Helvetica",
                    isTitleBlock: entry.titleBlock
                ))
            }
        }

        // Bookmarks: a section per discipline, a sheet entry per sheet, and two detail
        // bookmarks on the same page under A-102 (a sheet must keep its own name).
        var outline: [FixtureOutlineEntry] = []
        for (d, discipline) in disciplines.enumerated() {
            let first = d * 10
            let children: [FixtureOutlineEntry] = (0..<10).map { offset in
                let sheet = sheets[first + offset]
                let details: [FixtureOutlineEntry] = sheet.number == "A-102"
                    ? [FixtureOutlineEntry(title: "DETAIL 1", pageIndex: sheet.pageIndex),
                       FixtureOutlineEntry(title: "DETAIL 3", pageIndex: sheet.pageIndex)]
                    : []
                return FixtureOutlineEntry(title: "\(sheet.number) \(sheet.title)", pageIndex: sheet.pageIndex, children: details)
            }
            outline.append(FixtureOutlineEntry(title: discipline.group, pageIndex: first, children: children))
        }
        let named = Dictionary(uniqueKeysWithValues: sheets.map { ($0.number, $0.pageIndex) })

        let sheetSet = FixtureSheetSet(
            sheets: sheets,
            pageLabels: sheets.map(\.number),
            outline: outline,
            namedDestinations: named,
            links: links,
            references: references,
            numberRegion: numberRegion,
            titleRegion: titleRegion
        )
        let manifest = FixtureManifest(
            kind: kind,
            title: "Thirty-sheet ARCH D drawing set with title blocks",
            purpose: "Sheet identity and set navigation: sheet numbers and titles in each title block and "
                + "in /PageLabels, a bookmark tree with a detail level, named destinations, GoTo, named, "
                + "URI and JavaScript links, and cross-references in body text including one to a missing sheet.",
            fileName: kind.fileName,
            pageCount: sheets.count,
            pages: sheets.map { FixturePage(index: $0.pageIndex, mediaBox: sheetBox, hasTextLayer: true) },
            texts: texts,
            notes: [
                "Labels come from three /PageLabels ranges: /P (A-) /St 101, /P (S-) /St 201, /P (M-) /St 301.",
                "Sheet number: 36 pt Helvetica at (1152, 80), inside numberRegion; title: 16 pt at (1152, 206), "
                    + "inside titleRegion. Both regions are the same on every sheet.",
                "Page i cites sheet (i + 10) mod 30 with an explicit GoTo link and sheet (i + 1) mod 30 with a "
                    + "named-destination link; page 29 also cites A-999, which does not exist, with no link.",
                "The URI and JavaScript links exist to be shown and never followed or run."
            ],
            sheetSet: sheetSet
        )

        return FixtureBuild(manifest: manifest) {
            try write(sheetSet: sheetSet, bodies: bodies, kind: kind)
        }
    }

    private static func write(
        sheetSet: FixtureSheetSet,
        bodies: [Int: [(id: String, text: String, origin: FixturePoint, size: Double, titleBlock: Bool)]],
        kind: FixtureKind
    ) throws -> Data {
        let builder = PDFDocumentBuilder(kind: kind)
        let font = try builder.addBase14Font(baseFont: "Helvetica")
        let pageNumbers = sheetSet.sheets.map { _ in builder.reserveObject() }

        func destination(_ page: Int, left: Double? = nil, top: Double? = nil) -> String {
            if left == nil && top == nil { return "[\(pageNumbers[page]) 0 R /Fit]" }
            let l = left.map { PDFNumber.string($0) } ?? "null"
            let t = top.map { PDFNumber.string($0) } ?? "null"
            return "[\(pageNumbers[page]) 0 R /XYZ \(l) \(t) null]"
        }

        for sheet in sheetSet.sheets {
            let i = sheet.pageIndex
            var content = PDFContentStream()
            content.setLineWidth(2)
            content.setStrokeGray(0)
            for rect in [borderRect, titleBlockRect] {
                content.appendRing(rect.counterClockwiseCorners, close: true)
                content.stroke()
            }
            content.setFillGray(0)
            for entry in bodies[i] ?? [] {
                let literal = try PDFSyntax.literalString(entry.text, kind: kind)
                content.showText(literal, font: "F1", size: entry.size, at: entry.origin)
            }
            let contents = try builder.addContentStream(content)
            var annots: [Int] = []
            for link in sheetSet.links where link.pageIndex == i {
                let action: String
                switch link.target {
                case let .page(index, left, top):
                    action = "/A << /S /GoTo /D \(destination(index, left: left, top: top)) >>"
                case let .named(name):
                    action = "/Dest \(try PDFSyntax.name(name, kind: kind))"
                case let .uri(target):
                    action = "/A << /S /URI /URI \(try PDFSyntax.literalString(target, kind: kind)) >>"
                case let .javaScript(script):
                    action = "/A << /S /JavaScript /JS \(try PDFSyntax.literalString(script, kind: kind)) >>"
                }
                annots.append(builder.addObject(
                    "<< /Type /Annot /Subtype /Link /Rect \(PDFNumber.array(link.rect)) /Border [0 0 0] \(action) >>"
                ))
            }
            let annotEntry = annots.isEmpty ? "" : "/Annots [" + annots.map { "\($0) 0 R" }.joined(separator: " ") + "]"
            builder.addPage(
                mediaBox: sheetBox,
                resources: "<< /Font << /F1 \(font) 0 R >> >>",
                contentObject: contents,
                extraEntries: annotEntry,
                reservedNumber: pageNumbers[i]
            )
        }

        // Outline items, sibling-linked (PDF 32000-1 §12.3.3).
        let root = builder.reserveObject()
        func writeLevel(_ entries: [FixtureOutlineEntry], parent: Int) throws -> (first: Int, last: Int, count: Int)? {
            guard !entries.isEmpty else { return nil }
            let numbers = entries.map { _ in builder.reserveObject() }
            var total = 0
            for (index, entry) in entries.enumerated() {
                var dictionary = "/Title \(try PDFSyntax.literalString(entry.title, kind: kind)) /Parent \(parent) 0 R "
                    + "/Dest \(destination(entry.pageIndex))"
                if index > 0 { dictionary += " /Prev \(numbers[index - 1]) 0 R" }
                if index < entries.count - 1 { dictionary += " /Next \(numbers[index + 1]) 0 R" }
                if let children = try writeLevel(entry.children, parent: numbers[index]) {
                    dictionary += " /First \(children.first) 0 R /Last \(children.last) 0 R /Count \(children.count)"
                    total += children.count
                }
                builder.setObject(numbers[index], "<< \(dictionary) >>")
                total += 1
            }
            return (numbers[0], numbers[numbers.count - 1], total)
        }
        if let top = try writeLevel(sheetSet.outline, parent: root) {
            builder.setObject(root, "<< /Type /Outlines /First \(top.first) 0 R /Last \(top.last) 0 R /Count \(top.count) >>")
        }

        let dests = try sheetSet.sheets.map { sheet in
            "\(try PDFSyntax.name(sheet.number, kind: kind)) \(destination(sheet.pageIndex))"
        }.joined(separator: " ")
        var ranges: [String] = []
        for (d, discipline) in disciplines.enumerated() {
            ranges.append("\(d * 10) << /S /D /P \(try PDFSyntax.literalString("\(discipline.letter)-", kind: kind)) /St \(discipline.first) >>")
        }
        builder.catalogExtraEntries = "/PageLabels << /Nums [\(ranges.joined(separator: " "))] >> "
            + "/Outlines \(root) 0 R /Dests << \(dests) >> /PageMode /UseOutlines"
        return try builder.data()
    }
}
