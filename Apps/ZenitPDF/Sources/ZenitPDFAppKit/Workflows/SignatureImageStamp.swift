import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// Tools ▸ New Signature Stamp from Image… (NL-PDF-22).
///
/// A photo or scan of a handwritten signature becomes a stamp tool: the paper removed, the pen
/// line traced into sharp outlines (`SignatureImageTracer`), stored in the project like any
/// imported artwork, and added to the Tool Library under a name that says what it is — **an
/// image of a signature, not a digital signature**. Placing it proves nothing about who placed
/// it; signing the PDF is File ▸ Export Drawing ▸ Sign a Copy with a Certificate….
@MainActor
enum SignatureImageStamp {

    static let openPanelIdentifier = "signatureStamp.chooseImage"
    static let refusalIdentifier = "signatureStamp.refused"
    static let resultNoteID = UUID(uuidString: "7B2E4D19-0C3A-4F58-9E61-2A4B6C8D0E1F")!

    /// The name every signature stamp starts with, whatever the person renames it to later:
    /// "Signature image (A. Berg)".
    ///
    /// It said "Signature image — not a digital signature (…)", and the Tool Library's row cut
    /// it to "Signature image — not…" — a disclaimer with its point cut off, and no way to tell
    /// two signatures apart (L-62). The name now says what the tool is and whose it is; the
    /// disclaimer is the note the command posts, said in full.
    static func presetName(sourceName: String) -> String {
        String(
            format: NSLocalizedString(
                "Signature image (%@)",
                comment: "Tool Library name of a stamp made from a photographed signature; the image file name"
            ),
            (sourceName as NSString).deletingPathExtension
        )
    }

    /// The Tool Library category signature stamps are filed under (L-62). They were filed under
    /// Review, beside Approved and Rejected, which they are not.
    static var category: String {
        NSLocalizedString("Signatures", comment: "Tool Library category of stamps made from a photographed signature")
    }

    /// The tool already made from the same picture, if any: the same bytes trace to the same
    /// artwork, so a second import is the same tool twice (L-62).
    static func existingPreset(for digest: String, in presets: [ToolPresetSummary]) -> ToolPresetSummary? {
        presets.first { $0.markupKind == .stamp && $0.stamp?.artwork?.digest == digest }
    }

    /// The stamp tool for traced artwork. Pure.
    static func preset(for artwork: ImportedArtwork, id: UUID = UUID(), sortIndex: Int) -> ToolPresetSummary {
        let descriptor = ProjectArtworkStore.descriptor(of: artwork)
        // 150 pt wide, the height from the signature's own proportions.
        let aspect = artwork.geometry.sourceAspectRatio > 0 ? artwork.geometry.sourceAspectRatio : 3
        let width = 150.0
        let height = max(20, min(150, width / aspect))
        let template = StampTemplate(id: id, widthPoints: width, heightPoints: height, artwork: descriptor)
        var preset = ToolPresetSummary(
            id: id,
            name: presetName(sourceName: artwork.sourceName),
            category: category,
            panel: .myTools,
            markupKind: .stamp,
            colorRGBA: descriptor.sourceInk ?? ColorRGBA(red: 0.1, green: 0.15, blue: 0.5, alpha: 1),
            defaultSubject: NSLocalizedString("Signature image", comment: "Takeoff subject of a signature-image stamp"),
            stamp: template,
            provenance: ToolPresetProvenance(origin: .createdHere)
        )
        preset.sortIndex = sortIndex
        return preset
    }

    enum Outcome: Equatable {
        case added(presetID: UUID)
        case refused(String)
    }

    /// Traces, stores and adds the stamp. The half of the command worth asserting.
    static func add(imageAt url: URL, to document: ZenitPDFProjectDocument) async -> Outcome {
        guard let package = document.projectPackage, let core = document.core else {
            return .refused(NSLocalizedString(
                "Save this drawing as a project first. The signature image is stored inside the project so it travels with it.",
                comment: "Signature stamp refusal in Quick PDF Mode"
            ))
        }
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let artwork = try await Task.detached(priority: .userInitiated) { try SignatureImageTracer.trace(fileAt: url) }.value
            // L-62: importing the same picture twice made two identical tools without a word.
            if let existing = existingPreset(for: artwork.digest, in: core.toolLibrary.presets) {
                return .refused(String(
                    format: NSLocalizedString(
                        "This picture is already in the Tool Library as “%@”.",
                        comment: "Signature stamp refusal: the same image was imported before; the existing tool's name"
                    ),
                    existing.name
                ))
            }
            try await ProjectArtworkStore.store(artwork, in: package)
            document.updateChangeCount(.changeDone)
            let existing = core.toolLibrary.presets
            let preset = preset(for: artwork, sortIndex: existing.count)
            document.applyToolPresets(existing + [preset])
            core.document.post(AppWarning(
                id: resultNoteID,
                severity: .info,
                title: NSLocalizedString("Signature image added to the Tool Library.", comment: "Signature stamp note title"),
                message: NSLocalizedString(
                    "It is a picture of a signature, not a digital signature: placing it proves nothing about who placed it. To sign the PDF itself, use File ▸ Export Drawing ▸ Sign a Copy with a Certificate….",
                    comment: "Signature stamp note detail"
                ),
                source: NSLocalizedString("Tool Library", comment: "Warning source: the tool library"),
                isDismissible: true,
                timestamp: Date()
            ))
            return .added(presetID: preset.id)
        } catch let refusal as SignatureImageTracer.Refusal {
            return .refused(refusal.description)
        } catch let refusal as ArtworkImportRefusal {
            return .refused(refusal.reason)
        } catch {
            return .refused(String(describing: error))
        }
    }

    /// Tools ▸ New Signature Stamp from Image….
    static func run(document: ZenitPDFProjectDocument, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString(
            "Choose a photo or scan of a handwritten signature on plain paper. The paper is removed and the pen line traced.",
            comment: "Signature stamp open panel message"
        )
        ZenitModalPresenter.runOpenPanel(panel, identifier: openPanelIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let url = urls.first else { return }
            Task { @MainActor in
                if case let .refused(reason) = await add(imageAt: url, to: document) {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("No signature stamp was made.", comment: "Signature stamp refusal title")
                    alert.informativeText = reason
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert dismissal"))
                    ZenitModalPresenter.runAlert(alert, identifier: refusalIdentifier, sheetedOn: window) { _ in }
                }
            }
        }
    }
}
