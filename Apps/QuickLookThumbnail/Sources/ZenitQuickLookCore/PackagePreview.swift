import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the application records for a project's Space-bar preview (NL-PLAT-21): its name, its
/// size, and the ledger's grand totals exactly as the application shows them — the same lines
/// Shortcuts' Get Totals answers with. Written by the application after each save the person makes,
/// as `thumbnails/summary.json`, beside `thumbnails/preview.png` (the first sheet with its markups).
///
/// One type for both sides: the application encodes it, the preview extension decodes it.
public struct PackagePreviewSummary: Codable, Equatable, Sendable {

    /// One grand total: the column's title and its value as the ledger displays it.
    public struct Total: Codable, Equatable, Sendable {
        public var title: String
        public var text: String

        public init(title: String, text: String) {
            self.title = title
            self.text = text
        }
    }

    /// Bumped on an incompatible change; a reader refuses a version it does not know.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var projectName: String
    /// ISO 8601, the save the summary describes.
    public var savedAt: String
    public var sheetCount: Int
    public var markupCount: Int
    public var totals: [Total]

    public init(projectName: String, savedAt: String, sheetCount: Int, markupCount: Int, totals: [Total]) {
        self.formatVersion = Self.currentFormatVersion
        self.projectName = projectName
        self.savedAt = savedAt
        self.sheetCount = sheetCount
        self.markupCount = markupCount
        self.totals = totals
    }
}

/// The Space-bar preview of a project (NL-PLAT-21): the first sheet with its markups, and a table
/// of the ledger's grand totals, as one HTML page the preview extension hands to Quick Look.
///
/// Built from what the application saved in the package — `thumbnails/summary.json` and
/// `thumbnails/preview.png` — so the extension computes no quantity and parses no drawing while
/// they are there. A project saved by an older build has neither: the preview then shows the
/// Finder thumbnail's picture (``PackageThumbnail``) and says the totals appear after the next save.
///
/// Every member is untrusted, as in ``PackageThumbnail``: links and non-regular files are not
/// read, sizes are capped, the summary's counts and strings are bounded, and every string is
/// escaped before it reaches the page.
public enum PackagePreview {

    public static let summaryMember = "thumbnails/summary.json"
    public static let imageMember = "thumbnails/preview.png"
    /// Largest summary read, in bytes.
    public static let maximumSummaryBytes = 1024 * 1024
    /// At most this many totals are listed; a ledger has one per numeric column.
    public static let maximumTotals = 200
    /// Strings longer than this are cut, with an ellipsis.
    public static let maximumStringLength = 300
    /// The attachment name the page's `<img>` refers to (`cid:`).
    public static let imageAttachmentName = "sheet.png"
    /// The longest side of a sheet the extension draws itself, when the application saved none.
    public static let fallbackImageLongestSide = 1200.0

    /// What the extension replies with: the page, and the sheet picture it refers to.
    public struct Content: Sendable {
        public var html: String
        public var imageData: Data?
    }

    /// The preview of the package at `package`, or `nil` when it has nothing to show — Quick Look
    /// then shows the document icon, the honest answer for a package it cannot read.
    public static func content(for package: URL) -> Content? {
        let summary = summary(in: package)
        let image = imageData(in: package)
        guard summary != nil || image != nil else { return nil }
        let fallbackName = package.deletingPathExtension().lastPathComponent
        return Content(html: html(summary: summary, fallbackName: fallbackName, hasImage: image != nil), imageData: image)
    }

    /// The summary the application saved, bounded; `nil` when it is missing, unreadable, too
    /// large, or from a format this build does not know.
    public static func summary(in package: URL) -> PackagePreviewSummary? {
        let url = package.appendingPathComponent(summaryMember)
        guard PackageThumbnail.isReadableRegularFile(url, limit: maximumSummaryBytes),
              let data = try? Data(contentsOf: url),
              var summary = try? JSONDecoder().decode(PackagePreviewSummary.self, from: data),
              summary.formatVersion == PackagePreviewSummary.currentFormatVersion
        else { return nil }
        summary.projectName = bounded(summary.projectName)
        summary.savedAt = bounded(summary.savedAt)
        summary.sheetCount = max(0, summary.sheetCount)
        summary.markupCount = max(0, summary.markupCount)
        summary.totals = summary.totals.prefix(maximumTotals).map {
            PackagePreviewSummary.Total(title: bounded($0.title), text: bounded($0.text))
        }
        return summary
    }

    /// The sheet picture as PNG bytes: the preview the application saved, else the Finder
    /// thumbnail's picture, else the drawing's first sheet drawn here. Any stored picture is decoded
    /// once to prove it is an image before its bytes are handed on.
    public static func imageData(in package: URL) -> Data? {
        for member in [imageMember, PackageThumbnail.storedImageMember] {
            let url = package.appendingPathComponent(member)
            guard PackageThumbnail.isReadableRegularFile(url, limit: PackageThumbnail.maximumImageBytes),
                  PackageThumbnail.storedImage(url) != nil,
                  let data = try? Data(contentsOf: url)
            else { continue }
            return data
        }
        let longest = CGSize(width: fallbackImageLongestSide, height: fallbackImageLongestSide)
        guard let drawn = PackageThumbnail.render(package: package, maximum: longest) else { return nil }
        return pngData(drawn)
    }

    /// The page. Every string from the package is escaped.
    public static func html(summary: PackagePreviewSummary?, fallbackName: String, hasImage: Bool) -> String {
        let name = escape(summary?.projectName.isEmpty == false ? summary!.projectName : bounded(fallbackName))
        var body = "<h1>\(name)</h1>\n"
        if let summary {
            let sheets = summary.sheetCount == 1
                ? localized("1 sheet", "Quick Look preview: one sheet")
                : String(format: localized("%d sheets", "Quick Look preview: number of sheets"), summary.sheetCount)
            let markups = summary.markupCount == 1
                ? localized("1 markup", "Quick Look preview: one markup")
                : String(format: localized("%d markups", "Quick Look preview: number of markups"), summary.markupCount)
            var meta = "\(sheets) · \(markups)"
            if !summary.savedAt.isEmpty {
                meta += " · " + String(format: localized("saved %@", "Quick Look preview: when the project was saved"), escape(summary.savedAt))
            }
            body += "<p class=\"meta\">\(meta)</p>\n"
        }
        if hasImage {
            let alt = escape(localized("The first sheet with its markups", "Quick Look preview: the sheet picture's description"))
            body += "<img src=\"cid:\(imageAttachmentName)\" alt=\"\(alt)\">\n"
        }
        if let summary, !summary.totals.isEmpty {
            body += "<table>\n<caption>\(escape(localized("Quantity Ledger totals", "Quick Look preview: the totals table's caption")))</caption>\n"
            body += "<thead><tr><th scope=\"col\">\(escape(localized("Column", "Quick Look preview: totals table column header")))</th>"
            body += "<th scope=\"col\">\(escape(localized("Total", "Quick Look preview: totals table value header")))</th></tr></thead>\n<tbody>\n"
            for total in summary.totals {
                body += "<tr><td>\(escape(total.title))</td><td class=\"value\">\(escape(total.text))</td></tr>\n"
            }
            body += "</tbody>\n</table>\n"
        } else if summary != nil {
            body += "<p class=\"note\">\(escape(localized("The ledger has no totals yet.", "Quick Look preview: the ledger is empty")))</p>\n"
        } else {
            body += "<p class=\"note\">\(escape(localized("The totals appear here after the project is next saved.", "Quick Look preview: a project saved before previews had totals")))</p>\n"
        }
        return """
            <!DOCTYPE html>
            <html lang="en"><head><meta charset="utf-8">
            <meta name="color-scheme" content="light dark">
            <style>
            body { font: 13px -apple-system, "Helvetica Neue", sans-serif; margin: 24px; color: #1d1d1f; background: #ffffff; }
            h1 { font-size: 20px; margin: 0 0 4px; }
            .meta, .note { color: #6e6e73; margin: 0 0 16px; }
            img { display: block; max-width: 100%; height: auto; border: 1px solid #d2d2d7; margin: 0 0 20px; background: #ffffff; }
            table { border-collapse: collapse; min-width: 50%; }
            caption { text-align: left; font-weight: 600; margin: 0 0 6px; }
            th, td { text-align: left; padding: 5px 16px 5px 0; border-bottom: 1px solid #d2d2d7; }
            td.value { font-variant-numeric: tabular-nums; }
            @media (prefers-color-scheme: dark) {
              body { color: #f5f5f7; background: #1d1d1f; }
              .meta, .note { color: #a1a1a6; }
              th, td, img { border-color: #424245; }
            }
            </style></head>
            <body>
            \(body)</body></html>
            """
    }

    /// `text` with `& < > " '` escaped for HTML text and attribute values.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    static func bounded(_ text: String) -> String {
        let cleaned = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        guard cleaned.count > maximumStringLength else { return cleaned }
        return String(cleaned.prefix(maximumStringLength - 1)) + "…"
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func localized(_ key: String, _ comment: String) -> String {
        NSLocalizedString(key, comment: comment)
    }
}
