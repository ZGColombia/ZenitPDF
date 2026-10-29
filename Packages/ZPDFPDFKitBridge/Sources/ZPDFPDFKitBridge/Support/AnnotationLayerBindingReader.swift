import CoreGraphics
import Foundation

/// Which annotations belong to which optional-content layer.
///
/// A PDF can attach layer membership in two places, and until 2026-08-27 this product read only
/// one of them. Page **content** joins a layer through marked-content operators (`BDC /OC`),
/// which `VectorLayerVisibilityFilter` handles. An **annotation** joins a layer through an `/OC`
/// entry in its own dictionary — and a real elevation set measured on 2026-08-26 does it
/// exclusively that way: two layers, no marked content at all, and seven `/OC` line
/// annotations. Hiding a layer on that drawing therefore did nothing.
///
/// This reader walks the catalog's `/OCGs` array — whose order defines ``PDFLayerID``, the same
/// rule `LayerCatalogReader` documents — collects each group's dictionary pointer, then walks
/// every page's `/Annots` and matches each annotation's `/OC` back to a group **by object
/// identity** (`CGPDFDictionaryRef` is an `OpaquePointer`, hashable by address). Names are not identity: two layers may share a title, but one CGPDF object has
/// one dictionary.
///
/// `/OC` may also be an `/OCMD` wrapping one group or several; membership is taken from its
/// `/OCGs` entry. Its `/P` policy is honoured for the bound group: `/AllOff` and `/AnyOff` mean
/// "visible when the group is off", recorded as ``Binding/invertsVisibility`` (BH-581). An
/// `/OCMD` with a `/VE` visibility expression is beyond what this product evaluates and is
/// treated as bound to its first group — truthful for every file measured so far, and the
/// conservative reading (the annotation follows *a* named layer rather than none).
public enum AnnotationLayerBindingReader {

    /// One annotation's layer membership.
    public struct Binding: Sendable, Hashable {
        /// Zero-based page index.
        public let pageIndex: Int
        /// The annotation's position in the page's `/Annots` array. Used only as a last-resort
        /// match: `PDFPage.annotations` is *usually* in `/Annots` order, but that is undocumented,
        /// so identity is preferred over it (CR-88).
        public let annotationIndex: Int
        /// The layer, by the `/OCGs`-order identity the whole layer system uses.
        public let layerID: PDFLayerID
        /// The annotation's `/NM` name, when it carries one — a stable identity independent of
        /// array order.
        public let annotationName: String?
        /// The annotation's `/Subtype`, e.g. `Line`, for a rect+subtype match when there is no
        /// `/NM`.
        public let subtype: String?
        /// The annotation's `/Rect`, normalised, for a rect+subtype match.
        public let rect: CGRect?
        /// `true` when the annotation is visible while its layer is **off** — an `/OCMD` with
        /// `/P /AllOff` or `/P /AnyOff`. Binding such an annotation as if it followed the layer
        /// hid it exactly when a conforming viewer shows it (BH-581).
        public let invertsVisibility: Bool

        public init(
            pageIndex: Int,
            annotationIndex: Int,
            layerID: PDFLayerID,
            annotationName: String? = nil,
            subtype: String? = nil,
            rect: CGRect? = nil,
            invertsVisibility: Bool = false
        ) {
            self.pageIndex = pageIndex
            self.annotationIndex = annotationIndex
            self.layerID = layerID
            self.annotationName = annotationName
            self.subtype = subtype
            self.rect = rect
            self.invertsVisibility = invertsVisibility
        }

        /// Whether the annotation is displayed when the given layers are hidden.
        public func shouldDisplay(hiddenLayerIDs: Set<PDFLayerID>) -> Bool {
            let layerHidden = hiddenLayerIDs.contains(layerID)
            return invertsVisibility ? layerHidden : !layerHidden
        }
    }

    /// The bindings, and whether the walk stopped before it had seen every annotation.
    public struct Report: Sendable, Hashable {
        public let bindings: [Binding]
        /// `true` when the node budget ran out or the task was cancelled mid-walk: annotations
        /// past the cut have no binding, and a caller must not present layer visibility as
        /// complete (BH-177). The same flag `CatalogInspector` and `LayerCatalogReader` report.
        public let wasTruncated: Bool

        public init(bindings: [Binding], wasTruncated: Bool) {
            self.bindings = bindings
            self.wasTruncated = wasTruncated
        }
    }

    /// Reads every annotation→layer binding in the document.
    ///
    /// Bounded like every other walk in this package (CR-84): at most
    /// ``DocumentLimits/maximumPageCount`` pages, at most
    /// ``DocumentLimits/maximumAnnotationsPerPage`` annotations per page, a total node budget of
    /// ``DocumentLimits/maximumHazardScanNodes``, and it stops early if its `Task` is cancelled —
    /// so a hostile document with millions of `/Annots` entries cannot make it walk unbounded.
    ///
    /// - Returns: the bindings, or an empty array for the normal document whose annotations
    ///   belong to no layer. Never throws: a malformed `/OC` on one annotation must not take
    ///   layer support down with it, so anything unreadable is simply not a binding. On a budget
    ///   or cancellation cut it returns the bindings collected so far.
    public static func read(
        from document: CGPDFDocument,
        limits: DocumentLimits = .standard
    ) -> [Binding] {
        readReport(from: document, limits: limits).bindings
    }

    /// Reads every binding and says whether the walk was cut short. See ``read(from:limits:)``;
    /// a budget or cancellation cut used to be indistinguishable from a complete walk (BH-177).
    public static func readReport(
        from document: CGPDFDocument,
        limits: DocumentLimits = .standard
    ) -> Report {
        let empty = Report(bindings: [], wasTruncated: false)
        guard let catalog = document.catalog else { return empty }

        // The canonical group list. Index in /OCGs *is* the layer identity.
        var properties: CGPDFDictionaryRef?
        var groupsArray: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties),
              let properties,
              CGPDFDictionaryGetArray(properties, "OCGs", &groupsArray),
              let groupsArray
        else { return empty }

        var groupPointers: [Int: Int] = [:]
        for index in 0..<CGPDFArrayGetCount(groupsArray) {
            var group: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(groupsArray, index, &group), let group else { continue }
            // First occurrence wins, exactly as in `LayerCatalogReader`: a group listed twice
            // (common after incremental updates) must bind its annotations to the same layer
            // row its marked content binds to, or no row hides both halves (BH-176, BH-580).
            let key = Self.address(group)
            if groupPointers[key] == nil { groupPointers[key] = index }
        }
        guard !groupPointers.isEmpty else { return empty }

        var bindings: [Binding] = []
        var budget = limits.maximumHazardScanNodes
        let pageCap = min(max(1, document.numberOfPages), limits.maximumPageCount)
        for pageNumber in 1...pageCap {
            if Task.isCancelled { return Report(bindings: bindings, wasTruncated: true) }
            guard let page = document.page(at: pageNumber),
                  let pageDictionary = page.dictionary else { continue }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(pageDictionary, "Annots", &annotations),
                  let annotations else { continue }

            // The index must stay the true `/Annots` position for the visibility mapping, so the
            // count is capped rather than the index rebased.
            let annotationCap = min(CGPDFArrayGetCount(annotations), limits.maximumAnnotationsPerPage)
            for annotationIndex in 0..<annotationCap {
                guard budget > 0 else { return Report(bindings: bindings, wasTruncated: true) }
                budget -= 1
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, annotationIndex, &annotation),
                      let annotation else { continue }
                var oc: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(annotation, "OC", &oc), let oc else { continue }

                guard let groupIndex = resolveGroupIndex(of: oc, in: groupPointers) else { continue }
                bindings.append(Binding(
                    pageIndex: pageNumber - 1,
                    annotationIndex: annotationIndex,
                    layerID: PDFLayerID(rawValue: "ocg:\(groupIndex)"),
                    annotationName: name(of: annotation),
                    subtype: subtype(of: annotation),
                    rect: rect(of: annotation),
                    invertsVisibility: invertsVisibility(oc, in: groupPointers)
                ))
            }
        }
        return Report(bindings: bindings, wasTruncated: false)
    }

    /// `true` for an `/OCMD` (not a group itself) whose `/P` is `/AllOff` or `/AnyOff`.
    private static func invertsVisibility(_ oc: CGPDFDictionaryRef, in groups: [Int: Int]) -> Bool {
        guard groups[Self.address(oc)] == nil else { return false }
        var namePointer: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(oc, "P", &namePointer), let namePointer else { return false }
        let policy = String(cString: namePointer)
        return policy == "AllOff" || policy == "AnyOff"
    }

    /// The annotation's `/NM` name, when it has one.
    private static func name(of annotation: CGPDFDictionaryRef) -> String? {
        var string: CGPDFStringRef?
        guard CGPDFDictionaryGetString(annotation, "NM", &string), let string,
              let text = CGPDFStringCopyTextString(string) as String? else { return nil }
        return text.isEmpty ? nil : text
    }

    /// The annotation's `/Subtype`, e.g. `Line`.
    private static func subtype(of annotation: CGPDFDictionaryRef) -> String? {
        var namePointer: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(annotation, "Subtype", &namePointer), let namePointer else {
            return nil
        }
        return String(cString: namePointer)
    }

    /// The annotation's `/Rect`, normalised so `origin` is the lower-left corner regardless of
    /// the order the file stored the two corners in.
    private static func rect(of annotation: CGPDFDictionaryRef) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(annotation, "Rect", &array), let array,
              CGPDFArrayGetCount(array) >= 4 else { return nil }
        var values = [CGPDFReal](repeating: 0, count: 4)
        for index in 0..<4 {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
            values[index] = value
        }
        let minX = Swift.min(values[0], values[2])
        let minY = Swift.min(values[1], values[3])
        let width = Swift.abs(values[2] - values[0])
        let height = Swift.abs(values[3] - values[1])
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    /// One CGPDF object has one in-memory dictionary for the lifetime of its document, so the
    /// address is the identity. `CGPDFDictionaryRef`'s imported pointer type varies by SDK;
    /// `unsafeBitCast` to a raw pointer sidesteps that without changing the meaning.
    private static func address(_ dictionary: CGPDFDictionaryRef) -> Int {
        Int(bitPattern: unsafeBitCast(dictionary, to: UnsafeRawPointer.self))
    }

    /// `/OC` is either the group itself or an `/OCMD` naming one or more groups.
    private static func resolveGroupIndex(
        of oc: CGPDFDictionaryRef,
        in groups: [Int: Int]
    ) -> Int? {
        if let direct = groups[Self.address(oc)] { return direct }

        // /OCMD: /OCGs is a single group or an array of them.
        var single: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(oc, "OCGs", &single), let single {
            return groups[Self.address(single)]
        }
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(oc, "OCGs", &array), let array {
            for index in 0..<CGPDFArrayGetCount(array) {
                var member: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(array, index, &member), let member,
                   let found = groups[Self.address(member)] {
                    return found
                }
            }
        }
        return nil
    }
}
