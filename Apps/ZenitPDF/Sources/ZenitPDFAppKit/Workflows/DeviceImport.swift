import AppKit
import UniformTypeIdentifiers
import ZPDFImageIntake

/// File ▸ Import from iPhone or iPad (NL-PDF-11): a document scanned or a sheet photographed
/// with the phone arrives as a drawing.
///
/// The system builds the submenu (Take Photo, Scan Documents) from the standard item and hands
/// the result to the responder that asked for it — no camera entitlement, no network, no
/// account. A scan arrives as a PDF and opens as a Quick PDF; a photo arrives as an image and
/// opens through the image intake (NL-PLAT-04), which asks for the paper size when the photo
/// states no resolution rather than guessing one.
@MainActor
enum DeviceImport {

    /// What the requestor accepts from the device, in the order preferred.
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .pdf, NSPasteboard.PasteboardType(UTType.heic.identifier), NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        .png, .tiff
    ]

    /// Opens the imported file. A test injects its own; the product opens it as a document.
    static var opener: (@MainActor (URL) -> Void)?

    /// Where imports are kept: the application's own container, beside repaired copies.
    static var importsFolder: URL {
        DamagedDrawingRepair.repairedCopiesRoot.deletingLastPathComponent().appendingPathComponent("Imported", isDirectory: true)
    }

    /// The row's title, in the application's own words.
    static var menuTitle: String {
        NSLocalizedString("Import from iPhone or iPad", comment: "File menu: the system's device import")
    }

    /// The standard item AppKit fills with the person's devices.
    ///
    /// A ``DeviceImportMenuItem``, not a plain `NSMenuItem` (L-01): when AppKit populates the row
    /// it also retitles it from its own string table, and on the installed build that lookup
    /// failed, so the File menu read "<<Import From Device - unlocalized>>". The row keeps its
    /// own title whenever AppKit offers an unlocalized key in its place.
    static func menuItem() -> NSMenuItem {
        let item = DeviceImportMenuItem(title: menuTitle, action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        return item
    }

    /// Whether `title` is AppKit's placeholder for a string its table did not have, such as
    /// "<<Import From Device - unlocalized>>".
    nonisolated static func isUnlocalizedPlaceholder(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("<<") && trimmed.hasSuffix(">>") && trimmed.lowercased().contains("unlocalized")
    }

    /// Writes what the device delivered into the imports folder and returns the file, or `nil`
    /// when the pasteboard holds nothing this accepts.
    static func store(from pasteboard: NSPasteboard, now: Date = Date()) -> URL? {
        guard let type = acceptedTypes.first(where: { pasteboard.data(forType: $0) != nil }),
              let data = pasteboard.data(forType: type) else { return nil }
        let ext: String = switch type {
        case .pdf: "pdf"
        case .png: "png"
        case .tiff: "tiff"
        case NSPasteboard.PasteboardType(UTType.heic.identifier): "heic"
        default: "jpg"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stem = (type == .pdf
            ? NSLocalizedString("Scan", comment: "File name stem of a document scanned with a device")
            : NSLocalizedString("Photo", comment: "File name stem of a photo taken with a device"))
            + " " + formatter.string(from: now)
        do {
            try FileManager.default.createDirectory(at: importsFolder, withIntermediateDirectories: true)
            var url = importsFolder.appendingPathComponent(stem).appendingPathExtension(ext)
            var counter = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = importsFolder.appendingPathComponent("\(stem) \(counter)").appendingPathExtension(ext)
                counter += 1
            }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Stores and opens what arrived. Returns whether anything did.
    static func receive(from pasteboard: NSPasteboard) -> Bool {
        guard let url = store(from: pasteboard) else { return false }
        if let opener { opener(url) } else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        return true
    }
}

extension ProjectWindowController: @preconcurrency NSServicesMenuRequestor {

    /// The window asks for what a device delivers: a scanned PDF or a photo.
    override public func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, DeviceImport.acceptedTypes.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    public func readSelection(from pasteboard: NSPasteboard) -> Bool {
        DeviceImport.receive(from: pasteboard)
    }

    public func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        false
    }
}

/// The File menu's device-import row (L-01). AppKit keeps the row and fills its submenu with the
/// person's devices, but a title it sets from a string table that has no entry — shown as
/// "<<Import From Device - unlocalized>>" — is refused, and the application's own title stays.
final class DeviceImportMenuItem: NSMenuItem {
    override var title: String {
        get { super.title }
        set { super.title = DeviceImport.isUnlocalizedPlaceholder(newValue) ? MainActor.assumeIsolated { DeviceImport.menuTitle } : newValue }
    }

    override var attributedTitle: NSAttributedString? {
        get { super.attributedTitle }
        set {
            if let newValue, DeviceImport.isUnlocalizedPlaceholder(newValue.string) {
                super.attributedTitle = nil
                super.title = MainActor.assumeIsolated { DeviceImport.menuTitle }
            } else {
                super.attributedTitle = newValue
            }
        }
    }
}
