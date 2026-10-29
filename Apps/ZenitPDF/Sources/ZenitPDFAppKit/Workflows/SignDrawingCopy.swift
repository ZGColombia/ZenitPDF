import AppKit
import Foundation
import Security
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// File ▸ Export Drawing ▸ Sign a Copy with a Certificate… (NL-PDF-16, ADR-0028).
///
/// The person picks a certificate from their own keychain and a reason; a signed copy of the
/// drawing is written where they choose. Nothing leaves the machine: no timestamp server, no
/// revocation lookup. The original drawing is never written.
@MainActor
enum SignDrawingCopy {

    static let confirmIdentifier = "pdf.signCopy"
    static let panelIdentifier = "pdf.signCopyPanel"
    static let noIdentityIdentifier = "pdf.signCopyNoCertificate"
    static let resultNoteID = UUID(uuidString: "7D2C9A41-6E3B-4F08-9B5D-3A1E8C0F2B64")!

    /// A signing identity the person can choose, by the name on its certificate.
    struct Identity {
        let name: String
        let identity: SecIdentity
    }

    /// Where identities come from. The keychain in the product; a test replaces it so no test
    /// ever reads the user's keychain.
    static var identityProvider: @MainActor () -> [Identity] = { keychainIdentities() }

    /// Every identity in the person's keychains, by certificate name.
    nonisolated static func keychainIdentities() -> [Identity] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [SecIdentity]
        else { return [] }
        return items.compactMap { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
            let name = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "?"
            return Identity(name: name, identity: identity)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A detached CMS signer for one identity: SHA-256, with the signing time as a signed
    /// attribute.
    nonisolated static func cmsSigner(_ identity: SecIdentity) -> (Data) throws -> Data {
        { covered in
            var encoderOut: CMSEncoder?
            guard CMSEncoderCreate(&encoderOut) == errSecSuccess, let encoder = encoderOut else {
                throw ExportError.annotationExportRefused("the signature encoder could not be created.")
            }
            var status = CMSEncoderAddSigners(encoder, identity)
            if status == errSecSuccess { status = CMSEncoderSetHasDetachedContent(encoder, true) }
            if status == errSecSuccess { status = CMSEncoderSetSignerAlgorithm(encoder, kCMSEncoderDigestAlgorithmSHA256) }
            if status == errSecSuccess { status = CMSEncoderAddSignedAttributes(encoder, .attrSigningTime) }
            if status == errSecSuccess { status = CMSEncoderSetCertificateChainMode(encoder, .chain) }
            if status == errSecSuccess {
                status = covered.withUnsafeBytes { buffer -> OSStatus in
                    guard let base = buffer.baseAddress else { return errSecParam }
                    return CMSEncoderUpdateContent(encoder, base, buffer.count)
                }
            }
            var encoded: CFData?
            if status == errSecSuccess { status = CMSEncoderCopyEncodedContent(encoder, &encoded) }
            guard status == errSecSuccess, let encoded else {
                let reason = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
                throw ExportError.annotationExportRefused("the certificate could not sign the drawing: \(reason).")
            }
            return encoded as Data
        }
    }

    /// A PAdES baseline (B-B) signer for one identity: a hand-built CAdES `SignedData` with
    /// signing-certificate-v2, signed with the identity's private key through
    /// `SecKeyCreateSignature` (ADR-0028 round 2). The key never leaves the keychain.
    nonisolated static func cadesSigner(_ identity: SecIdentity) -> (Data) throws -> Data {
        { covered in
            var certificateRef: SecCertificate?
            var keyRef: SecKey?
            guard SecIdentityCopyCertificate(identity, &certificateRef) == errSecSuccess, let certificateRef,
                  SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess, let keyRef
            else { throw ExportError.annotationExportRefused("the certificate or its private key could not be read.") }
            let attributes = SecKeyCopyAttributes(keyRef) as? [CFString: Any]
            let isEC = (attributes?[kSecAttrKeyType] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String)
            let algorithm: SecKeyAlgorithm = isEC ? .ecdsaSignatureMessageX962SHA256 : .rsaSignatureMessagePKCS1v15SHA256
            return try CAdESSignedData.build(
                content: covered,
                certificate: SecCertificateCopyData(certificateRef) as Data,
                keyKind: isEC ? .ecdsa : .rsa
            ) { signedAttributes in
                var error: Unmanaged<CFError>?
                guard let signature = SecKeyCreateSignature(keyRef, algorithm, signedAttributes as CFData, &error) else {
                    let reason = error.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "unknown"
                    throw ExportError.annotationExportRefused("the certificate could not sign the drawing: \(reason).")
                }
                return signature as Data
            }
        }
    }

    /// The visible seal for a sheet: 200 × 64 pt in the bottom-right corner of the sheet as it is
    /// displayed (its `/Rotate` applied), naming the signer, the time and the reason. Pure.
    static func seal(on page: ZPDFContracts.PageDescriptor, signer: String, reason: String?, at time: Date,
                     artwork: ArtworkGeometry?, dateFormatter: DateFormatter = sealDateFormatter) -> PDFSignatureWriter.Seal {
        // Laid out on the displayed sheet and placed on the page by the export's own matrix, so a
        // landscape sheet stored portrait with /Rotate 90 gets the seal upright in its corner (R-106).
        let sheet = page.rotatedVisibleSize
        let width = max(40, min(200, sheet.width - 24)), height = max(24, min(64, sheet.height - 24))
        let displayed = PDFRect(x: sheet.width - width - 12, y: 12, width: width, height: height)
        var lines = [
            String(format: NSLocalizedString("Digitally signed by %@", comment: "Visible seal line; the signer"), signer),
            dateFormatter.string(from: time)
        ]
        if let reason, !reason.isEmpty { lines.append(reason) }
        return PDFSignatureWriter.Seal(on: page, displayed: displayed, lines: lines, artwork: artwork)
    }

    nonisolated(unsafe) static let sealDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm ZZZZZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Writes a signed copy of the drawing at `source` to `destination`. Pure apart from the
    /// signer: a test passes its own.
    static func write(
        source: URL,
        opened digest: FileDigest?,
        to destination: URL,
        options: PDFSignatureWriter.Options,
        signer: (Data) throws -> Data
    ) throws {
        try write(source: source, opened: digest, to: destination, inPlace: false, options: options, signer: signer)
    }

    /// Writes the signed file. `inPlace` signs the drawing itself — only after the confirmation
    /// said so, and only when the file on disk still begins with the bytes the document opened;
    /// the drawing stays the file's prefix, so the signature covers exactly it plus the seal.
    static func write(
        source: URL,
        opened digest: FileDigest?,
        to destination: URL,
        inPlace: Bool,
        options: PDFSignatureWriter.Options,
        signer: (Data) throws -> Data
    ) throws {
        // "The same file" by the one rule every derived-copy writer uses (S-012): resolved path,
        // then file identity. A hard link to the drawing is the drawing; a path comparison alone
        // sent it down the "copy" branch, which replaced the link's name with the signed copy.
        let same = StagedFileReplacement.sameItem(destination, source)
        guard inPlace == same else {
            throw ExportError.annotationExportRefused(inPlace
                ? "signing in place writes the drawing itself and nothing else."
                : "the signed copy cannot replace the drawing it is made from.")
        }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        if let digest { try StandardAnnotationExport.verifyBegins(data, with: digest) }
        let signed = try PDFSignatureWriter().data(source: data, options: options, signer: signer)
        try SaveMarkupsIntoPDF.atomicallyReplace(destination, with: signed)
    }

    /// The confirmation's choices beyond certificate and reason.
    struct Choices {
        let profile: NSPopUpButton
        let seal: NSButton
        let artwork: NSPopUpButton
    }

    static func profileTitle(_ profile: PDFSignatureWriter.Profile) -> String {
        switch profile {
        case .cadesDetached: NSLocalizedString("PAdES baseline (recommended)", comment: "Signature profile choice")
        case .pkcs7Detached: NSLocalizedString("PKCS #7 (older readers)", comment: "Signature profile choice")
        }
    }

    /// Adds the profile, seal and seal-picture controls under the certificate and reason.
    static func addChoices(to alert: NSAlert, artworkNames: [String], inPlaceAllowed: Bool) -> Choices {
        let profile = NSPopUpButton(frame: NSRect(x: 0, y: 60, width: 320, height: 26), pullsDown: false)
        profile.addItems(withTitles: [profileTitle(.cadesDetached), profileTitle(.pkcs7Detached)])
        profile.setAccessibilityLabel(NSLocalizedString("Signature profile", comment: "Accessibility label: signature profile popup"))
        let seal = NSButton(checkboxWithTitle: NSLocalizedString("Show a visible seal on the sheet on screen", comment: "Sign option: visible seal"), target: nil, action: nil)
        seal.frame = NSRect(x: 0, y: 32, width: 320, height: 22)
        seal.state = .on
        seal.setAccessibilityLabel(seal.title)
        let artwork = NSPopUpButton(frame: NSRect(x: 0, y: 2, width: 320, height: 26), pullsDown: false)
        artwork.addItem(withTitle: NSLocalizedString("Seal without a picture", comment: "Sign option: seal artwork none"))
        artwork.addItems(withTitles: artworkNames)
        artwork.setAccessibilityLabel(NSLocalizedString("Seal picture", comment: "Accessibility label: seal artwork popup"))
        if let existing = alert.accessoryView {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: existing.frame.height + 90))
            existing.frame.origin.y = 90
            container.addSubview(existing)
            for control in [profile, seal, artwork] as [NSView] { container.addSubview(control) }
            alert.accessoryView = container
        }
        if inPlaceAllowed {
            alert.informativeText += " " + NSLocalizedString(
                "Sign This PDF signs the open file itself instead: its original bytes stay at the start of the file.",
                comment: "Sign confirmation: in-place option"
            )
            alert.addButton(withTitle: NSLocalizedString("Sign This PDF", comment: "Sign confirmation: sign in place"))
        }
        return Choices(profile: profile, seal: seal, artwork: artwork)
    }

    /// The confirmation: which certificate, and why. Returns the alert and its two controls.
    static func confirmation(identities: [Identity], fileName: String) -> (NSAlert, NSPopUpButton, NSTextField) {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Sign a copy of “%@”?", comment: "Sign copy confirmation headline; the file name"),
            fileName
        )
        alert.informativeText = NSLocalizedString(
            "The copy is signed with the certificate you choose, on this Mac. The drawing itself is not changed, and no server is contacted.",
            comment: "Sign copy confirmation detail"
        )
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 320, height: 26), pullsDown: false)
        popup.addItems(withTitles: identities.map(\.name))
        popup.setAccessibilityLabel(NSLocalizedString("Signing certificate", comment: "Accessibility label: signing certificate popup"))
        let reason = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        reason.placeholderString = NSLocalizedString("Reason (optional)", comment: "Sign copy reason field placeholder")
        reason.setAccessibilityLabel(NSLocalizedString("Reason for signing", comment: "Accessibility label: signing reason field"))
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        accessory.addSubview(popup)
        accessory.addSubview(reason)
        alert.accessoryView = accessory
        alert.addButton(withTitle: NSLocalizedString("Sign Copy…", comment: "Sign copy confirmation: continue"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Button: cancel"))
        return (alert, popup, reason)
    }
}

extension ProjectWindowController {

    /// File ▸ Export Drawing ▸ Sign a Copy with a Certificate….
    func signDrawingCopy(for document: ZenitPDFProjectDocument) {
        guard let drawing = document.drawing, let window else { return }
        let identities = SignDrawingCopy.identityProvider()
        guard !identities.isEmpty else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("No signing certificate on this Mac", comment: "Sign copy refusal headline")
            alert.informativeText = NSLocalizedString(
                "Add a certificate with its private key to your keychain — one your organisation issued, or your own — and try again.",
                comment: "Sign copy refusal detail"
            )
            ZenitModalPresenter.runAlert(alert, identifier: SignDrawingCopy.noIdentityIdentifier, sheetedOn: window, answerWithoutAUser: .button(0)) { _ in }
            return
        }
        let (alert, popup, reasonField) = SignDrawingCopy.confirmation(identities: identities, fileName: drawing.url.lastPathComponent)
        // The seal's picture: any stamp tool that carries artwork (NL-PDF-16 round 2).
        let stampTools = (document.core?.toolLibrary.presets ?? []).filter { $0.stamp?.artwork != nil }
        let inPlaceAllowed = document.mode == .quickPDF
        let choices = SignDrawingCopy.addChoices(to: alert, artworkNames: stampTools.map(\.name), inPlaceAllowed: inPlaceAllowed)
        ZenitModalPresenter.runAlert(alert, identifier: SignDrawingCopy.confirmIdentifier, sheetedOn: window, answerWithoutAUser: .button(1)) { answer in
            let inPlace = inPlaceAllowed && answer.buttonIndex == 2
            guard answer.buttonIndex == 0 || inPlace else { return }
            let chosen = identities[max(0, min(identities.count - 1, popup.indexOfSelectedItem))]
            let reason = reasonField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile: PDFSignatureWriter.Profile = choices.profile.indexOfSelectedItem == 1 ? .pkcs7Detached : .cadesDetached
            let wantsSeal = choices.seal.state == .on
            let artworkIndex = choices.artwork.indexOfSelectedItem - 1
            Task { @MainActor in
                var seal: PDFSignatureWriter.Seal?
                if wantsSeal {
                    let current = document.core?.document.currentPageID
                    let page = drawing.pages.first { $0.id.rawValue == current } ?? drawing.pages.first
                    var artwork: ArtworkGeometry?
                    if stampTools.indices.contains(artworkIndex), let digest = stampTools[artworkIndex].stamp?.artwork?.digest,
                       let package = document.projectPackage {
                        artwork = try? await ProjectArtworkStore.geometry(forDigest: digest, in: package)
                    }
                    if let page {
                        seal = SignDrawingCopy.seal(on: page, signer: chosen.name, reason: reason.isEmpty ? nil : reason, at: Date(), artwork: artwork)
                    }
                }
                let options = PDFSignatureWriter.Options(
                    reason: reason.isEmpty ? nil : reason,
                    signerName: chosen.name,
                    profile: profile,
                    seal: seal
                )
                let signer = profile == .cadesDetached ? SignDrawingCopy.cadesSigner(chosen.identity) : SignDrawingCopy.cmsSigner(chosen.identity)
                @MainActor func sign(to url: URL) {
                    do {
                        try SignDrawingCopy.write(source: drawing.url, opened: drawing.digest, to: url, inPlace: inPlace, options: options, signer: signer)
                        ExportCompletion.remember(url, document: document)
                        document.core?.document.post(AppWarning(
                            id: SignDrawingCopy.resultNoteID,
                            severity: .info,
                            title: String(
                                format: NSLocalizedString("Signed “%@”", comment: "Sign copy headline; the file name"),
                                url.lastPathComponent
                            ),
                            message: String(
                                format: NSLocalizedString(
                                    "Signed with the certificate of %@. Any change to the signed content will show as modified after signing.",
                                    comment: "Sign copy note; the certificate name"
                                ),
                                chosen.name
                            ),
                            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
                            isDismissible: true,
                            timestamp: Date()
                        ))
                    } catch {
                        ZenitErrorPresenter.present(error, in: window)
                    }
                }
                if inPlace {
                    sign(to: drawing.url)
                    return
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.pdf]
                panel.nameFieldStringValue = drawing.url.deletingPathExtension().lastPathComponent
                    + " — " + NSLocalizedString("Signed", comment: "Signed copy file-name suffix") + ".pdf"
                ZenitModalPresenter.runSavePanel(panel, identifier: SignDrawingCopy.panelIdentifier, sheetedOn: window) { saved in
                    guard let url = saved.firstURL else { return }
                    sign(to: url)
                }
            }
        }
    }
}
