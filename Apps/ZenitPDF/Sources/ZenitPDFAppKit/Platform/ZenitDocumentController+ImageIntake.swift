import AppKit
import UniformTypeIdentifiers
import ZPDFImageIntake

extension ZenitDocumentController {

    /// How a derived drawing (a PDF made from a scan or a DXF) is opened. `nil` — the shipping
    /// value — opens it through this controller like any PDF; a test replaces it, because the test
    /// runner has no bundle that declares the PDF type.
    static var derivedDrawingOpener: ((URL, Bool, @escaping (NSDocument?, Bool, (any Error)?) -> Void) -> Void)?

    func openDerivedDrawing(_ url: URL, display: Bool, completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        if let opener = Self.derivedDrawingOpener {
            opener(url, display, completionHandler)
        } else {
            openDocument(withContentsOf: url, display: display, completionHandler: completionHandler)
        }
    }

    /// Whether an open of `url` is an image to convert rather than a document to read.
    nonisolated static func isImageDrawing(_ url: URL) -> Bool {
        ImageIntake.canOpen(url)
    }

    /// The content types the Open panel offers: projects, PDFs, the drawing images, CAD files and
    /// Zenit's own data files (NL-PLAT-03), which act on the drawing in front.
    nonisolated static var openPanelContentTypes: [UTType] {
        [ZenitAppInfo.projectType, .pdf] + ImageIntake.supportedTypes
            + [CADDrawingIntake.dxfExtension, CADDrawingIntake.dwgExtension].compactMap { UTType(filenameExtension: $0) }
            + ZenitDataFileKind.contentTypes
    }

    /// Converts a scan or photo into a PDF drawing and opens that (NL-PLAT-04). `release` ends a
    /// security-scoped access the caller started, after the image has been read.
    func openImageDrawing(
        _ url: URL,
        release: (() -> Void)?,
        display displayDocument: Bool,
        root: URL = ImageDrawingIntake.derivedRoot,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        Task { @MainActor in
            let outcome: Result<ImageDrawingIntake.Derived, any Error> = await Task.detached(priority: .userInitiated) {
                Result { try ImageDrawingIntake.derive(from: url, into: root) }
            }.value
            release?()
            switch outcome {
            case let .failure(error):
                completionHandler(nil, false, ImageDrawingIntake.openError(error, fileName: url.lastPathComponent))
            case let .success(derived):
                self.openDerivedDrawing(derived.pdf, display: displayDocument) { document, alreadyOpen, error in
                    if let document = document as? ZenitPDFProjectDocument {
                        ImageDrawingIntake.post(ImageDrawingIntake.openedNote(for: derived.result), to: document)
                    }
                    completionHandler(document, alreadyOpen, error)
                }
            }
        }
    }
}
