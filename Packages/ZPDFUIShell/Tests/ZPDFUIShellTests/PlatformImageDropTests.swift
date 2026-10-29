import Foundation
import Testing
@testable import ZPDFUIShell

/// NL-PLAT-04: scans and photos of sheets are drawings too.
@Suite("Navigator accepts drawing images", .shellTierSerialised)
struct PlatformImageDropTests {

    @Test("TIFF, JPEG, PNG and HEIC drops are admitted; text still is not (DXF and DWG reach the CAD intake)")
    func imagesAreAdmitted() {
        // Old code: acceptedExtensions was ["pdf", "zpdfproj"], so a plan-room TIFF was refused.
        let urls = ["scan.TIF", "sheet.tiff", "photo.jpg", "photo.jpeg", "detail.png", "site.HEIC", "x.heif", "plan.dxf", "notes.txt"]
            .map { URL(fileURLWithPath: "/tmp/\($0)") }
        #expect(NavigatorDropPolicy.acceptedURLs(urls).map(\.lastPathComponent)
                == ["scan.TIF", "sheet.tiff", "photo.jpg", "photo.jpeg", "detail.png", "site.HEIC", "x.heif", "plan.dxf"])
    }
}
