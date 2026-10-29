import CoreGraphics
import Foundation

/// A drawing's `/UserUnit` entries — how many 1/72-inch units one default user-space unit is —
/// read the one way the application and `zenit` both read them (X-051).
///
/// Every preset scale is multiplied by this unit, so a second reading of it is a second way for
/// `zenit export` to print a different Scale cell or length than the application (W-093). The
/// application's loader (`DocumentSessionLoader`, BH-068) and the command-line reader
/// (`ProjectReader`, W-093) each kept a copy of the read and the sanitising rule, and the two
/// already differed: only the application's unlocked an encrypted drawing first.
public enum PageUserUnits {

    /// The largest unit trusted, the specification's practical range.
    public static let maximum = 75_000.0

    /// Pages read at most, as the loader always has: a hostile page count must not turn one
    /// dictionary lookup per page into an unbounded loop.
    public static let maximumPages = 100_000

    /// A user unit the engine can trust: finite and strictly positive, else 1.0 — the contract's
    /// `validate()` refuses anything else, and a hostile file must not be able to make a page
    /// unloadable through it — capped at ``maximum``.
    public static func sanitised(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return min(value, maximum)
    }

    /// Every page that declares a `/UserUnit`, sanitised, keyed by zero-based page index; a page
    /// that declares none is absent, which means 1.0.
    ///
    /// Read straight from each page dictionary with CoreGraphics, the parser the vector extraction
    /// uses. An encrypted drawing is unlocked with `password` first when one is given; a drawing
    /// that stays locked declares nothing, so every page reads as 1.0 on both paths.
    public static func read(from document: CGPDFDocument, password: String? = nil) -> [Int: Double] {
        if document.isEncrypted, !document.isUnlocked, let password {
            _ = document.unlockWithPassword(password)
        }
        guard !document.isEncrypted || document.isUnlocked else { return [:] }
        let count = min(document.numberOfPages, maximumPages)
        guard count > 0 else { return [:] }
        var units: [Int: Double] = [:]
        for number in 1...count {
            guard let page = document.page(at: number), let dictionary = page.dictionary else { continue }
            var real: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(dictionary, "UserUnit", &real) {
                units[number - 1] = sanitised(Double(real))
            }
        }
        return units
    }

    /// ``read(from:password:)`` for the drawing at `url`; nothing when it cannot be opened.
    public static func read(at url: URL, password: String? = nil) -> [Int: Double] {
        guard let document = CGPDFDocument(url as CFURL) else { return [:] }
        return read(from: document, password: password)
    }
}
