import CoreGraphics
import Foundation

/// The catalog hazards of a file on disk, without opening it through PDFKit.
///
/// The same Core Graphics inspection ``PDFKitDocumentProvider`` runs on open, callable by a
/// write path that has only the file: the annotated export asks whether the drawing is signed
/// before it chooses between an incremental update (the signature survives) and a full rewrite
/// (it does not).
public enum DocumentHazardProbe {

    /// The hazards Core Graphics finds in the file's catalog, or `[]` when it will not open it.
    public static func hazards(ofFileAt url: URL, limits: DocumentLimits = .standard) -> DocumentHazards {
        CatalogInspector.inspect(document: CGPDFDocument(url as CFURL), limits: limits).hazards
    }
}
