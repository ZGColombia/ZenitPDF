import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import ZenitPDFAppKit

/// LT-38, 2026-08-29: a password-protected drawing opened as a silent
/// blank page — `PDFDocument(url:)` succeeds with `isLocked == true`, every page renders
/// white, and "Vector Snap unavailable" was the only hint. The honest path proven here:
/// the open pauses on the password question; the right password unlocks the drawing; a
/// cancel or a wrong password fails the open with words and closes the tab — never a
/// blank sheet.
@MainActor
@Suite(.appTierSerialised)
struct LockedDrawingTests {

    private func wait(
        upTo seconds: Double = 30,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    /// The password every locked fixture is written with.
    private static let password = "byggare1"

    /// Writes an encrypted one-page PDF: some stroked linework behind a user password.
    private func writeLockedFixturePDF(named name: String = "Locked Plan.pdf") throws -> URL {
        let url = try AppTestSupport.writeLockedFixturePDF(named: name, password: Self.password)
        // The fixture must actually be what LT-38 was about, or these tests prove nothing.
        let probe = try #require(PDFDocument(url: url), "the locked fixture failed to open at all")
        #expect(probe.isEncrypted && probe.isLocked,
                "the fixture is not locked, so it cannot regress-test LT-38")
        return url
    }

    /// Opens the fixture the way the controller path does — designated initializer, so
    /// `fileURL` is set exactly as a real ⌘O open sets it — and runs the shipping
    /// `makeWindowControllers()`.
    private func openLikeTheApp(_ url: URL) throws -> ZenitPDFProjectDocument {
        let document = try ZenitPDFProjectDocument(
            contentsOf: url,
            ofType: UTType.pdf.identifier
        )
        document.makeWindowControllers()
        return document
    }

    @Test("The right password unlocks the drawing and it opens with real content")
    func theRightPasswordUnlocksTheDrawing() async throws {
        let url = try writeLockedFixturePDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let previousPrompt = ZenitPDFProjectDocument.passwordPrompt
        defer { ZenitPDFProjectDocument.passwordPrompt = previousPrompt }
        var asked: [String] = []
        ZenitPDFProjectDocument.passwordPrompt = { fileName in
            asked.append(fileName)
            return Self.password
        }

        let document = try openLikeTheApp(url)
        defer {
            document.hostWindowController?.window?.close()
            document.close()
        }
        #expect(await wait { document.core != nil && !document.isLoading })
        #expect(document.loadFailure == nil)
        #expect(asked == ["Locked Plan.pdf"], "the prompt was asked \(asked.count) times")

        // Not blank and not locked: the drawing is really open.
        let drawing = try #require(document.drawing)
        #expect(drawing.pages.count == 1)
        let locked = await drawing.rasterSource.isLocked
        #expect(!locked, "the source is still locked — the password never reached the reopen")
        let image = try? await drawing.rasterSource.render(
            pageIndex: 0,
            displaySize: CGSize(width: 595, height: 842),
            requestedScale: 1
        )
        #expect(image != nil, "an unlocked drawing must render")

        // And it is a real tab, not a squatter (LT-38b's half of LT-33).
        let host = try #require(document.hostWindowController)
        #expect(host.documents.contains(where: { $0 === document }))
        #expect(document.core?.document.tabs.first?.title == "Locked Plan")
    }

    @Test("Cancelling the password prompt refuses the open in words and closes the tab")
    func cancellingThePromptRefusesTheOpen() async throws {
        let url = try writeLockedFixturePDF(named: "Cancelled.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let previousPrompt = ZenitPDFProjectDocument.passwordPrompt
        ZenitErrorPresenter.reset()
        defer {
            ZenitPDFProjectDocument.passwordPrompt = previousPrompt
            ZenitErrorPresenter.reset()
        }
        ZenitPDFProjectDocument.passwordPrompt = { _ in nil }

        let document = try openLikeTheApp(url)
        let host = try #require(document.hostWindowController)
        defer { host.window?.close() }
        #expect(await wait { document.loadFailure != nil })
        guard case ZenitDocumentError.passwordRequired = try #require(document.loadFailure) else {
            Issue.record("the refusal is \(String(describing: document.loadFailure)), not passwordRequired")
            return
        }
        #expect(document.core == nil, "a refused open must not build a session")

        // The refusal was said out loud through the injectable error door…
        #expect(await wait { !ZenitErrorPresenter.recorded.isEmpty },
                "the refusal was silent — LT-38's exact defect")
        let presented = ZenitErrorPresenter.recorded.compactMap { $0 as? ZenitDocumentError }
        #expect(presented.contains(.passwordRequired("Cancelled.pdf")))

        // …and the failed tab is really gone, not a lingering blank sheet.
        #expect(await wait { !host.documents.contains(where: { $0 === document }) },
                "the failed document still sits in the window as a blank tab")
    }

    @Test("A wrong password refuses the open in words, and offers no repair")
    func aWrongPasswordRefusesTheOpen() async throws {
        let url = try writeLockedFixturePDF(named: "Wrong.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let previousPrompt = ZenitPDFProjectDocument.passwordPrompt
        ZenitErrorPresenter.reset()
        ZenitModalPresenter.reset()
        defer {
            ZenitPDFProjectDocument.passwordPrompt = previousPrompt
            ZenitErrorPresenter.reset()
            ZenitModalPresenter.reset()
        }
        ZenitPDFProjectDocument.passwordPrompt = { _ in "fel-losenord" }

        let document = try openLikeTheApp(url)
        let host = try #require(document.hostWindowController)
        defer { host.window?.close() }
        #expect(await wait { document.loadFailure != nil })
        guard case ZenitDocumentError.wrongPassword = try #require(document.loadFailure) else {
            Issue.record("the refusal is \(String(describing: document.loadFailure)), not wrongPassword")
            return
        }
        #expect(await wait { !ZenitErrorPresenter.recorded.isEmpty })
        let presented = ZenitErrorPresenter.recorded.compactMap { $0 as? ZenitDocumentError }
        #expect(presented.contains(.wrongPassword("Wrong.pdf")))
        #expect(await wait { !host.documents.contains(where: { $0 === document }) })

        // An encrypted refusal is not damage: the "Repair a Copy…" alert must not appear.
        #expect(!ZenitModalPresenter.didRequest(ProjectWindowController.damagedDrawingModalIdentifier),
                "a locked drawing was offered a repair it cannot survive")
        #expect(!DamagedDrawingRepair.canOffer(
            for: url,
            afterLoadFailure: ZenitDocumentError.wrongPassword("Wrong.pdf")
        ))
    }

    @Test("The shipping prompt goes through the modal door and answers Cancel with nobody there")
    func theDefaultPromptIsBehindTheModalDoor() async throws {
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }

        // Nobody there: the only honest answer is nil — never an invented password, and
        // never a drawn dialogue (the presenter refuses to draw outside the bundle).
        let refused = DrawingPasswordPrompt.ask(fileName: "Locked Plan.pdf")
        #expect(refused == nil)
        #expect(ZenitModalPresenter.didRequest(DrawingPasswordPrompt.modalIdentifier))
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
        #expect(ZenitModalPresenter.lastRecorded?.title.contains("Locked Plan.pdf") == true)
        #expect(ZenitModalPresenter.lastRecorded?.buttons == ["Unlock", "Cancel"])

        // An injected Cancel is honoured the same way.
        ZenitModalPresenter.handler = { _ in .button(1) }
        #expect(DrawingPasswordPrompt.ask(fileName: "Locked Plan.pdf") == nil)
    }
}
