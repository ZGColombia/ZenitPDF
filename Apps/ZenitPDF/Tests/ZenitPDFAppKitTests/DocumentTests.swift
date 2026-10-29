import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFContracts
import ZPDFPDFKitBridge
@testable import ZenitPDFAppKit

/// What the application layer decides on its own: which type a file is, and how PDFKit's page
/// geometry becomes contract geometry.
@Suite(.appTierSerialised)
struct DocumentRoutingTests {

    @Test("A PDFKit page descriptor becomes a contract page with both boxes intact")
    func pageMapping() throws {
        let documentID = DocumentID(UUID())
        let descriptor = PDFPageDescriptor(
            index: 3,
            label: "A-104",
            labelIsExplicit: true,
            boxes: PageBoxes(
                media: CGRect(x: 0, y: 0, width: 2_384, height: 1_684),
                crop: CGRect(x: 12, y: 8, width: 2_360, height: 1_668),
                bleed: CGRect(x: 0, y: 0, width: 2_384, height: 1_684),
                trim: CGRect(x: 0, y: 0, width: 2_384, height: 1_684),
                art: CGRect(x: 0, y: 0, width: 2_384, height: 1_684)
            ),
            rotation: 90
        )
        let page = try DocumentSessionLoader.contractPage(from: descriptor, documentID: documentID)

        #expect(page.index == 3)
        #expect(page.label == "A-104")
        #expect(page.documentID == documentID)
        #expect(page.rotation == .degrees90)
        #expect(page.boxes.crop.origin.x == 12)
        #expect(page.boxes.crop.size.width == 2_360)
        #expect(page.boxes.media.size.height == 1_684)
        // A 90 degree page reads as landscape on screen even though its crop box is portrait-ish.
        #expect(page.rotatedVisibleSize.width == 1_668)
        #expect(page.rotatedVisibleSize.height == 2_360)
    }

    @Test("The page label is what the document says, never the index")
    func labelIsNotDerivedFromIndex() throws {
        let descriptor = PDFPageDescriptor(
            index: 0,
            label: "iv",
            labelIsExplicit: true,
            boxes: PageBoxes(
                media: CGRect(x: 0, y: 0, width: 100, height: 100),
                crop: CGRect(x: 0, y: 0, width: 100, height: 100),
                bleed: .zero, trim: .zero, art: .zero
            ),
            rotation: 0
        )
        let page = try DocumentSessionLoader.contractPage(from: descriptor, documentID: DocumentID(UUID()))
        #expect(page.label == "iv")
    }

    @Test("Both readable types are declared, project first")
    func readableTypes() {
        #expect(ZenitDocumentController.readableTypeIdentifiers.first == ZenitAppInfo.projectTypeIdentifier)
        #expect(ZenitDocumentController.readableTypeIdentifiers.contains(UTType.pdf.identifier))
        #expect(ZenitDocumentController.readableTypeIdentifiers.count == 2)
    }

    @Test("Every application error states what happened and what to do about it")
    func errorsAreActionable() {
        let cases: [ZenitDocumentError] = [
            .unsupportedFileType("plan.dwg"),
            .documentNotReady,
            .quickModeRequiresProject,
            .projectMissingDocument("Tower.zpdfproj"),
            .noScale
        ]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
    }
}

/// The CSV writer is the one export path wired today, and a mis-quoted cell is a wrong tender line.
@MainActor
@Suite(.appTierSerialised)
struct LedgerCSVExportTests {

    @Test("A plain value is written unquoted")
    func plainValue() {
        #expect(LedgerCSVExport.field("Perimeter Wall") == "Perimeter Wall")
        #expect(LedgerCSVExport.field("14.72") == "14.72")
    }

    @Test("Commas, quotes and newlines are quoted per RFC 4180")
    func quoting() {
        #expect(LedgerCSVExport.field("Wall, north") == "\"Wall, north\"")
        #expect(LedgerCSVExport.field("2\" pipe") == "\"2\"\" pipe\"")
        #expect(LedgerCSVExport.field("line\nbreak") == "\"line\nbreak\"")
    }

    @Test("A decimal comma does not silently split a cell")
    func decimalComma() {
        // A Swedish locale renders 14,72; unquoted that would become two columns.
        #expect(LedgerCSVExport.field("14,72") == "\"14,72\"")
    }
}
