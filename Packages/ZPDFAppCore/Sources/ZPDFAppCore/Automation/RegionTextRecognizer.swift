import CoreGraphics
import Foundation
import Vision
import ZPDFUIPresentation

/// On-device text recognition of one region of a page (NL-AUTO-03), for the reads that need
/// text where the drawing carries none: a scanned title block, a sheet whose lettering is drawn
/// as strokes.
///
/// The caller renders just the region — a title block, not the sheet — and hands the image with
/// the page rectangle it shows. Vision's `VNRecognizeTextRequest` runs on this Mac; nothing is
/// sent anywhere and nothing is written to the search index: a region read for a command is part
/// of that command. Every line comes back in page space with the recogniser's own confidence,
/// so a caller can stay silent on a weak read instead of treating it as the drawing's text.
public enum RegionTextRecognizer {

    /// One recognised line.
    public struct Line: Sendable, Hashable {
        public let text: String
        public let boundsInPageSpace: PDFRectValue
        /// `0…1`, Vision's confidence for the top candidate.
        public let confidence: Double

        /// The line in the form the readers take.
        public var recognisedTextLine: RecognisedTextLine {
            RecognisedTextLine(text: text, boundsInPageSpace: boundsInPageSpace)
        }
    }

    /// Recognises the text in `image`, which shows `region` of the page (page space, origin
    /// bottom-left). Languages default to English and Swedish.
    public static func recognize(
        image: CGImage,
        region: PDFRectValue,
        languages: [String] = ["en-US", "sv-SE"],
        minimumConfidence: Double = 0.3
    ) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let chosen = languages.filter { supported.contains($0) }
        if !chosen.isEmpty { request.recognitionLanguages = chosen }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first,
                  Double(candidate.confidence) >= minimumConfidence else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Vision's box is normalised with its origin bottom-left — the same orientation as
            // page space, so the mapping is a scale and an offset.
            let box = observation.boundingBox
            return Line(
                text: text,
                boundsInPageSpace: PDFRectValue(
                    x: region.minX + Double(box.minX) * region.size.width,
                    y: region.minY + Double(box.minY) * region.size.height,
                    width: Double(box.width) * region.size.width,
                    height: Double(box.height) * region.size.height
                ),
                confidence: Double(candidate.confidence)
            )
        }
        .sorted { $0.boundsInPageSpace.minY != $1.boundsInPageSpace.minY
            ? $0.boundsInPageSpace.minY > $1.boundsInPageSpace.minY
            : $0.boundsInPageSpace.minX < $1.boundsInPageSpace.minX }
    }

    /// The render scale that gives the region's text enough pixels for Vision without rendering
    /// more than it needs: about 40 px per 10 pt of text height at the default, capped so the
    /// crop stays under `maximumPixels`.
    public static func fittedPixelsPerPoint(for region: PDFRectValue, maximumPixels: Double = 16_000_000) -> Double {
        let area = Swift.max(1, region.size.width * region.size.height)
        return Swift.max(1, Swift.min(4, (maximumPixels / area).squareRoot()))
    }
}
