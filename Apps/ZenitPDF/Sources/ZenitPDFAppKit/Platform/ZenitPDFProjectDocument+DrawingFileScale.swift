import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFMeasureDictionary
import ZPDFUIPresentation

/// The scale a CAD program already wrote into the PDF (NL-PLAT-06).
///
/// Many CAD exporters record, per viewport, "one point here is this many metres" (`/VP` →
/// `/Measure`). That is exact, and it is offered — never applied silently — as one tray note:
/// "The drawing file gives each sheet its scale", Apply installs each sheet's own ratio, labelled
/// as coming from the drawing file, on every sheet that has no scale yet. A sheet a person already
/// calibrated is never touched.
@MainActor
enum DrawingFileScaleOffers {

    struct Offer {
        weak var document: ZenitPDFProjectDocument?
        var scales: [(pageID: PageID, denominator: Decimal, label: String)]
    }

    static var pending: [UUID: Offer] = [:]

    /// Per page: the viewport that governs it — the largest box, a whole-page viewport counting as
    /// the whole page — and how many distinct ratios the page declares.
    nonisolated static func governing(_ viewports: [PDFMeasureViewport], pageArea: (Int) -> Double) -> [Int: (PDFMeasureViewport, distinct: Int)] {
        var result: [Int: (PDFMeasureViewport, distinct: Int)] = [:]
        for (page, group) in Dictionary(grouping: viewports, by: \.pageIndex) {
            guard let best = group.max(by: { ($0.area ?? pageArea(page)) < ($1.area ?? pageArea(page)) }) else { continue }
            result[page] = (best, Set(group.map(\.ratioDenominator)).count)
        }
        return result
    }

    /// The applied scale's name, from the ratio it applies (X-052). It used to be built from the
    /// viewport's own ratio, which is per default-space unit: on a `/UserUnit 2` sheet the scale
    /// read 1:100 and was named "1:200 from the drawing file".
    nonisolated static func label(denominator: Decimal) -> String {
        String(format: NSLocalizedString("1:%@ from the drawing file", comment: "Scale label for a scale read from the PDF's own measure dictionary; the denominator"),
               NSDecimalNumber(decimal: denominator).stringValue)
    }
}

extension ZenitPDFProjectDocument {

    /// Reads the drawing's measure dictionaries once, off the main actor, and offers them.
    func offerDrawingFileScale() {
        guard let drawing, let core else { return }
        let url = drawing.url
        let pages = drawing.pages
        Task { @MainActor [weak self] in
            let viewports = await Task.detached(priority: .utility) { () -> [PDFMeasureViewport] in
                guard let document = CGPDFDocument(url as CFURL) else { return [] }
                return PDFMeasureReader.viewports(in: document)
            }.value
            guard let self, !viewports.isEmpty else { return }
            let governing = DrawingFileScaleOffers.governing(viewports) { index in
                guard pages.indices.contains(index) else { return .infinity }
                let box = pages[index].visibleBox
                return Double(box.size.width * box.size.height)
            }
            var scales: [(pageID: PageID, denominator: Decimal, label: String)] = []
            var mixed = false
            for (index, entry) in governing.sorted(by: { $0.key < $1.key }) where pages.indices.contains(index) {
                let page = pages[index]
                guard await core.session.scale(onPage: page.id) == nil else { continue }
                // A /UserUnit page: the viewport factor is per default-space unit, which the
                // preset ratio then multiplies by the user unit; divided back out, once, for the
                // ratio and its label alike (X-052).
                let denominator = entry.0.ratioDenominator(userUnit: page.userUnit)
                scales.append((page.id, denominator, DrawingFileScaleOffers.label(denominator: denominator)))
                mixed = mixed || entry.distinct > 1
            }
            guard let first = scales.first, let firstViewport = governing[pages.firstIndex { $0.id == first.pageID } ?? 0]?.0 else { return }
            let warningID = UUID()
            DrawingFileScaleOffers.pending[warningID] = .init(document: self, scales: scales)
            let ratio = "1:" + NSDecimalNumber(decimal: first.denominator).stringValue
            var message = scales.count == 1
                ? String(format: NSLocalizedString("Written into the PDF by the program that made it%@. Apply it, or calibrate by hand as usual.", comment: "Drawing-file scale offer detail; optional ' (1 in = 8 ft)'"),
                         firstViewport.ratioText.map { " (\($0))" } ?? "")
                : String(format: NSLocalizedString("%lld sheets carry their own scale, written into the PDF by the program that made it. Apply sets each sheet that has no scale yet.", comment: "Drawing-file scale offer detail for several sheets; count"), Int64(scales.count))
            if mixed {
                message += " " + NSLocalizedString("Some sheets hold viewports at different scales; the largest viewport's scale is used. Check detail views before measuring in them.", comment: "Drawing-file scale offer: mixed viewports")
            }
            core.document.post(AppWarning(
                id: warningID,
                severity: .info,
                title: scales.count == 1
                    ? String(format: NSLocalizedString("The drawing file says %@.", comment: "Drawing-file scale offer title; the ratio"), ratio)
                    : NSLocalizedString("The drawing file gives each sheet its scale.", comment: "Drawing-file scale offer title for several sheets"),
                message: message,
                source: NSLocalizedString("Scale proposal", comment: "Warning source"),
                actionTitle: scales.count == 1
                    ? String(format: NSLocalizedString("Apply %@", comment: "Scale proposal action; the ratio"), ratio)
                    : String(format: NSLocalizedString("Apply to %lld Sheets", comment: "Drawing-file scale action; sheet count"), Int64(scales.count)),
                isDismissible: true,
                timestamp: Date()
            ))
        }
    }

    /// The tray's Apply for a drawing-file scale offer. Returns whether the warning was one.
    func handleDrawingFileScaleAction(_ warningID: UUID) -> Bool {
        guard let offer = DrawingFileScaleOffers.pending.removeValue(forKey: warningID), offer.document === self, let core else { return false }
        Task { @MainActor in
            for scale in offer.scales {
                // Re-checked at the press: a scale made by hand meanwhile is never overwritten.
                guard await core.session.scale(onPage: scale.pageID) == nil else { continue }
                _ = try? await core.commands.setPresetScale(page: scale.pageID, ratioDenominator: scale.denominator, label: scale.label)
            }
            core.document.dismissWarning(id: warningID)
            await core.refresh()
        }
        return true
    }
}
