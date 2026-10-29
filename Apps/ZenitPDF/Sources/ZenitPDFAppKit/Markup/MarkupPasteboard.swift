import AppKit
import ZPDFAppCore

/// Where copied markups go (nl-markup, NL-MARKUP-05, NL-UX-03).
///
/// An instance on the window controller, injected by the app-tier tests, never a process-wide
/// override: `NSPasteboard.general` is the whole machine's clipboard, and a test that wrote it
/// would be writing the user's (the same rule as `snippetPasteboard`).
@MainActor
public protocol MarkupPasteboardAccess: AnyObject {
    /// Writes copied markups: the private payload and a plain-text line per markup. Returns a
    /// token that ``addPicture(_:ifStill:)`` checks, so a picture rendered later never lands on
    /// a clipboard somebody has since overwritten.
    @discardableResult
    func writeMarkups(_ payload: Data, plainText: String) -> Int
    /// Adds the PNG picture of the copied markups, for other applications.
    func addPicture(_ png: Data, ifStill token: Int)
    /// The private payload currently on the clipboard, or `nil`.
    func readMarkups() -> Data?
}

/// The shipping clipboard.
@MainActor
public final class SystemMarkupPasteboard: MarkupPasteboardAccess {

    static let type = NSPasteboard.PasteboardType(MarkupClipboardPayload.pasteboardType)

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    public func writeMarkups(_ payload: Data, plainText: String) -> Int {
        pasteboard.clearContents()
        pasteboard.declareTypes([Self.type, .string], owner: nil)
        pasteboard.setData(payload, forType: Self.type)
        pasteboard.setString(plainText, forType: .string)
        return pasteboard.changeCount
    }

    public func addPicture(_ png: Data, ifStill token: Int) {
        guard pasteboard.changeCount == token else { return }
        pasteboard.addTypes([.png], owner: nil)
        pasteboard.setData(png, forType: .png)
    }

    public func readMarkups() -> Data? {
        pasteboard.data(forType: Self.type)
    }
}

/// A clipboard that lives in this process only: what a test process, or any process that is not
/// the assembled application, copies to, so no test can overwrite the user's clipboard.
@MainActor
public final class ScratchMarkupPasteboard: MarkupPasteboardAccess {
    public private(set) var payload: Data?
    public private(set) var plainText: String?
    public private(set) var picture: Data?
    private var changeCount = 0

    public init() {}

    @discardableResult
    public func writeMarkups(_ payload: Data, plainText: String) -> Int {
        changeCount += 1
        self.payload = payload
        self.plainText = plainText
        picture = nil
        return changeCount
    }

    public func addPicture(_ png: Data, ifStill token: Int) {
        guard token == changeCount else { return }
        picture = png
    }

    public func readMarkups() -> Data? { payload }
}

/// The clipboard a new window copies markups to.
@MainActor
enum MarkupPasteboards {
    /// The system clipboard in the shipping application, a scratch one everywhere else.
    static func makeDefault() -> any MarkupPasteboardAccess {
        ZenitProcessDefaults.isAssembledApplication ? SystemMarkupPasteboard() : ScratchMarkupPasteboard()
    }
}
