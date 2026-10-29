import AppKit
import CoreGraphics
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFMeasureDictionary
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Measure ▸ Find Scale Regions on This Sheet (NL-AUTO-19, NL-MEASURE-16).
///
/// A sheet that holds a 1:100 plan and a 1:20 detail needs a Scale Region over the detail. Two
/// places say where such a region is: the viewports a CAD program wrote into the PDF (`/VP` with a
/// `/Measure`, each with its own box and ratio), and a viewport title printed under a drawing
/// ("DETAIL 3 SCALE 1:20", `ViewportScaleDetector`). Every region found whose ratio differs from
/// the sheet's own scale is offered in the tray with its evidence; **Add Scale Region** installs
/// the region and its preset scale as one undoable step and leaves the sheet's scale alone.
/// Nothing is applied without the press.
@MainActor
enum ScaleRegionOffers {

    /// Where a candidate came from, for the tray wording.
    enum Origin: Equatable, Sendable {
        /// A `/VP` viewport of the drawing file, with its name and scale text when it has them.
        case drawingFile(name: String?, ratioText: String?)
        /// A viewport title printed on the sheet, verbatim.
        case printedTitle(String)
    }

    /// One region worth offering.
    struct Candidate: Equatable, Sendable {
        let ratioNumerator: Decimal
        let ratioDenominator: Decimal
        /// The closed outline, page space, first point not repeated.
        let boundary: [PDFPoint]
        let origin: Origin

        var ratioText: String {
            let numerator = NSDecimalNumber(decimal: ratioNumerator).stringValue
            return "\(numerator):" + NSDecimalNumber(decimal: ratioDenominator).stringValue
        }

        /// The region's name: the viewport's, or the title as printed.
        var name: String {
            switch origin {
            case .drawingFile(let name, _): return name ?? ratioText
            case .printedTitle(let text): return text
            }
        }
    }

    struct Offer {
        weak var document: ZenitPDFProjectDocument?
        let pageID: PageID
        let candidate: Candidate
    }

    /// Offers waiting in the tray, by warning identity.
    static var pending: [UUID: Offer] = [:]

    /// Two ratios within this share of each other are the same scale.
    nonisolated static let sameRatioTolerance = 0.005
    /// A printed title whose drawing lies this much inside a file viewport already offered is the
    /// same region, said twice.
    nonisolated static let duplicateOverlap = 0.5

    /// The regions worth offering on one page, deterministic, file viewports first.
    ///
    /// - Parameters:
    ///   - viewports: the page's `/VP` viewports (any page index is ignored but this one's).
    ///   - titles: the page's printed viewport titles.
    ///   - pageDenominator: the sheet's own scale as `1:N`, or `nil` when it has none.
    ///   - userUnit: the page's `/UserUnit`; a viewport factor is per default-space unit.
    nonisolated static func candidates(
        viewports: [PDFMeasureViewport],
        titles: [ViewportScaleProposal],
        pageDenominator: Decimal?,
        userUnit: Double
    ) -> [Candidate] {
        func differs(_ denominator: Decimal) -> Bool {
            guard let pageDenominator else { return true }
            let a = NSDecimalNumber(decimal: denominator).doubleValue
            let b = NSDecimalNumber(decimal: pageDenominator).doubleValue
            return Swift.abs(a - b) > sameRatioTolerance * b
        }
        var result: [Candidate] = []
        var seen: [(Decimal, CGRect)] = []
        for viewport in viewports {
            // A whole-page viewport is the sheet's own scale (NL-PLAT-06's offer), never a region.
            guard let box = viewport.bbox?.standardized, box.width > 0, box.height > 0 else { continue }
            let denominator = viewport.ratioDenominator(userUnit: userUnit)
            guard denominator > 0, differs(denominator) else { continue }
            guard !seen.contains(where: { $0.0 == denominator && $0.1 == box }) else { continue }
            seen.append((denominator, box))
            result.append(Candidate(
                ratioNumerator: 1,
                ratioDenominator: denominator,
                boundary: corners(of: box),
                origin: .drawingFile(name: viewport.name, ratioText: viewport.ratioText)
            ))
        }
        for title in titles {
            let box = CGRect(x: title.region.origin.x, y: title.region.origin.y, width: title.region.size.width, height: title.region.size.height).standardized
            guard box.width > 0, box.height > 0, title.ratio.numerator > 0 else { continue }
            let numerator = Decimal(title.ratio.numerator)
            let denominator = Decimal(title.ratio.denominator) / numerator
            guard differs(denominator) else { continue }
            let duplicate = seen.contains { entry in
                let shared = entry.1.intersection(box)
                return !shared.isNull && shared.width * shared.height >= duplicateOverlap * box.width * box.height
            }
            guard !duplicate else { continue }
            seen.append((denominator, box))
            result.append(Candidate(
                ratioNumerator: numerator,
                ratioDenominator: Decimal(title.ratio.denominator),
                boundary: corners(of: box),
                origin: .printedTitle(title.evidence.sourceText.trimmingCharacters(in: .whitespacesAndNewlines))
            ))
        }
        return result
    }

    nonisolated static func corners(of box: CGRect) -> [PDFPoint] {
        [
            PDFPoint(x: Double(box.minX), y: Double(box.minY)), PDFPoint(x: Double(box.maxX), y: Double(box.minY)),
            PDFPoint(x: Double(box.maxX), y: Double(box.maxY)), PDFPoint(x: Double(box.minX), y: Double(box.maxY))
        ]
    }

    /// The sheet's own scale as `1:N` on its page (`N` = metres per point ÷ 0.0254/72 ÷ user unit),
    /// rounded to 1/1000 like the viewport reader, or `nil` for a sheet with no scale.
    nonisolated static func denominator(of scale: ScaleTransform?, userUnit: Double) -> Decimal? {
        guard let scale, userUnit > 0 else { return nil }
        let raw = scale.matrix.metresPerPointX / (0.0254 / 72) / userUnit
        guard raw.isFinite, raw > 0 else { return nil }
        return Decimal(string: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), raw))
    }

    /// The tray entry for one candidate.
    static func warning(for candidate: Candidate, id: UUID, pageID: PageID) -> AppWarning {
        let evidence: String
        switch candidate.origin {
        case .drawingFile(let name, let ratioText):
            let described = [name, ratioText].compactMap { $0 }.joined(separator: ", ")
            evidence = described.isEmpty
                ? NSLocalizedString("A viewport written into the PDF by the program that made it.", comment: "Scale Region offer evidence: a PDF viewport with no name")
                : String(format: NSLocalizedString("The viewport “%@”, written into the PDF by the program that made it.", comment: "Scale Region offer evidence: the PDF viewport's name and scale text"), described)
        case .printedTitle(let text):
            evidence = String(format: NSLocalizedString("The sheet prints “%@” under this drawing.", comment: "Scale Region offer evidence: the printed viewport title"), text)
        }
        return AppWarning(
            id: id,
            severity: .info,
            title: String(format: NSLocalizedString("Part of this sheet is drawn at %@.", comment: "Scale Region offer title; the ratio"), candidate.ratioText),
            message: evidence + " " + NSLocalizedString(
                "Add a Scale Region so measurements inside it use that scale. The sheet's own scale stays as it is.",
                comment: "Scale Region offer advice"
            ),
            source: NSLocalizedString("Scale proposal", comment: "Warning source"),
            actionTitle: NSLocalizedString("Add Scale Region", comment: "Scale Region offer action"),
            isDismissible: true,
            timestamp: Date(),
            relatedPageID: pageID.rawValue
        )
    }
}

extension ZenitPDFProjectDocument {

    /// Finds the regions of a page and offers each in the tray. Returns how many were offered.
    ///
    /// Offers for the same page that are still waiting are replaced, so asking twice never
    /// stacks them.
    @discardableResult
    func offerScaleRegions(
        onPage page: ZPDFContracts.PageDescriptor,
        viewports: [PDFMeasureViewport],
        titles: [ViewportScaleProposal]
    ) async -> Int {
        guard let core else { return 0 }
        let pageScale = await core.session.pageScale(page.id)
        let candidates = ScaleRegionOffers.candidates(
            viewports: viewports.filter { $0.pageIndex == page.index },
            titles: titles,
            pageDenominator: ScaleRegionOffers.denominator(of: pageScale, userUnit: page.userUnit),
            userUnit: page.userUnit
        )
        for (id, offer) in ScaleRegionOffers.pending where offer.document === self && offer.pageID == page.id {
            ScaleRegionOffers.pending[id] = nil
            core.document.dismissWarning(id: id)
        }
        for candidate in candidates {
            let id = UUID()
            ScaleRegionOffers.pending[id] = .init(document: self, pageID: page.id, candidate: candidate)
            core.document.post(ScaleRegionOffers.warning(for: candidate, id: id, pageID: page.id))
        }
        return candidates.count
    }

    /// The tray's Add Scale Region. Returns whether the warning was one of these offers.
    @discardableResult
    func handleScaleRegionOffer(_ warningID: UUID) -> Bool {
        guard let offer = ScaleRegionOffers.pending[warningID], offer.document === self, let core else { return false }
        ScaleRegionOffers.pending[warningID] = nil
        Task { @MainActor in
            do {
                try await core.commands.addRegionPresetScale(
                    page: offer.pageID,
                    ratioNumerator: offer.candidate.ratioNumerator,
                    ratioDenominator: offer.candidate.ratioDenominator,
                    label: offer.candidate.ratioText,
                    boundary: offer.candidate.boundary,
                    name: offer.candidate.name
                )
                core.document.dismissWarning(id: warningID)
                await core.refresh()
            } catch {
                core.status.setActiveToolNote(Self.regionOfferRefusal(error))
            }
        }
        return true
    }

    /// What the status strip says when a region could not be added.
    static func regionOfferRefusal(_ error: any Error) -> String {
        if case DocumentCommandError.noScale = error {
            return NSLocalizedString(
                "Set the sheet's own scale first, then add the Scale Region.",
                comment: "Status note: a Scale Region offer was pressed on a sheet with no scale"
            )
        }
        return String(describing: error)
    }
}

extension ProjectWindowController {

    /// Measure ▸ Find Scale Regions on This Sheet.
    func beginFindScaleRegions(for document: ZenitPDFProjectDocument) {
        guard let core = document.core, let current = core.document.currentPageID,
              let source = document.loadedDrawing(forPage: current),
              let page = source.pages.first(where: { $0.id.rawValue == current }) else { return }
        Task { @MainActor [weak self] in
            guard await core.session.pageScale(page.id) != nil else {
                self?.presentScaleSheet(
                    for: document,
                    notice: NSLocalizedString(
                        "Set this sheet's own scale first; Scale Regions are the parts drawn at another scale.",
                        comment: "Calibration sheet notice when Find Scale Regions runs on a sheet with no scale"
                    )
                )
                return
            }
            core.status.setActiveToolNote(NSLocalizedString("Looking for drawings at other scales…", comment: "Status note while scale regions are searched"))
            let url = source.url
            let viewports = await Task.detached(priority: .userInitiated) { () -> [PDFMeasureViewport] in
                guard let pdf = CGPDFDocument(url as CFURL) else { return [] }
                return PDFMeasureReader.viewports(in: pdf)
            }.value
            var titles: [ViewportScaleProposal] = []
            let lines = (try? await source.rasterSource.pageTextLines(pageIndex: page.index)) ?? []
            if !lines.isEmpty, let self,
               let extraction = try? await self.automationExtraction(for: document, page: page) {
                let box = page.visibleBox
                titles = await ViewportScaleDetector().proposalsInBackground(
                    lines: lines.map { line in
                        RecognisedTextLine(text: line.text, boundsInPageSpace: PDFRectValue(
                            x: line.boundsInPageSpace.origin.x, y: line.boundsInPageSpace.origin.y,
                            width: line.boundsInPageSpace.width, height: line.boundsInPageSpace.height
                        ))
                    },
                    pageBox: PDFRectValue(x: box.origin.x, y: box.origin.y, width: box.size.width, height: box.size.height),
                    primitives: extraction.primitives
                )
            }
            let count = await document.offerScaleRegions(onPage: page, viewports: viewports, titles: titles)
            core.status.setActiveToolNote(Self.scaleRegionsFoundNote(count))
        }
    }

    /// The status note after Find Scale Regions, for every count (W-014: "1 Scale Regions
    /// proposed…" used to be the only form).
    static func scaleRegionsFoundNote(_ count: Int) -> String {
        guard count > 0 else {
            return NSLocalizedString("No part of this sheet declares a scale other than the sheet's own.", comment: "Status note: Find Scale Regions found nothing")
        }
        return LocalizedPlural.string(
            "%lld Scale Regions proposed in the warning tray.", count: count,
            one: NSLocalizedString("%lld Scale Region proposed in the warning tray.", comment: "Status note: Find Scale Regions found one"),
            other: NSLocalizedString("%lld Scale Regions proposed in the warning tray.", comment: "Status note: Find Scale Regions found some; the count")
        )
    }
}
