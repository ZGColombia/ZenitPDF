import Foundation
import ZPDFAppCore
import ZPDFExport

extension DocumentPrintView {

    /// The print sheets for a job, each carrying its page's calibrated drawing ratio so the
    /// printed note can state the scale the paper is at (NL-PDF-06).
    ///
    /// Only a uniform scale has a ratio to state; a separately calibrated X/Y scale prints as
    /// "not to scale" at any reduction, which is true.
    static func sheets(for pages: [FlattenPage], session: TakeoffSession) async -> [Sheet] {
        var sheets: [Sheet] = []
        sheets.reserveCapacity(pages.count)
        for page in pages {
            var ratio: Double?
            if let scale = await session.pageScale(page.page.id), scale.matrix.isUniform {
                ratio = DocumentPrintLayout.drawnRatio(
                    metresPerPoint: scale.matrix.metresPerPointX,
                    userUnit: page.page.userUnit
                )
            }
            sheets.append(Sheet(flatten: page, drawnRatio: ratio))
        }
        return sheets
    }
}
