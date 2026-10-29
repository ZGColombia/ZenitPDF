import CoreGraphics
import Foundation

/// Everything read straight out of the PDF catalog with CoreGraphics rather than PDFKit.
///
/// PDFKit does not expose page labels, named destinations, embedded-file lists or
/// document-level actions, and those are exactly the things a takeoff app needs: sheet
/// numbers like `A-102`, detail cross-references, and the constructs in spec 7.4 that
/// must be *seen* and never *acted on*.
///
/// Every traversal here is bounded by ``DocumentLimits``. The trees involved — name
/// trees, number trees, the page tree — are attacker-controlled and can be cyclic.
struct CatalogReport: Sendable {
    var coreGraphicsPageCount: Int
    var hazards: DocumentHazards
    var embeddedFiles: [EmbeddedFileEntry]
    /// `nil` when the document declares no `/PageLabels`.
    var pageLabelRanges: [PageLabelRange]?
    var namedDestinations: [NamedDestination]
    var catalogReadable: Bool
    var scanWasTruncated: Bool

    static let unavailable = CatalogReport(
        coreGraphicsPageCount: 0,
        hazards: [],
        embeddedFiles: [],
        pageLabelRanges: nil,
        namedDestinations: [],
        catalogReadable: false,
        scanWasTruncated: false
    )
}

enum CatalogInspector {

    /// Reads a document with CoreGraphics and reports what the catalog contains.
    ///
    /// Returns ``CatalogReport/unavailable`` rather than throwing when CoreGraphics
    /// refuses the file: PDFKit may still have opened it, and the disagreement is itself
    /// an ``IntegrityFinding``.
    static func inspect(document: CGPDFDocument?, limits: DocumentLimits) -> CatalogReport {
        guard let document else { return .unavailable }
        let pageCount = document.numberOfPages
        guard let catalog = document.catalog else {
            return CatalogReport(
                coreGraphicsPageCount: pageCount,
                hazards: [],
                embeddedFiles: [],
                pageLabelRanges: nil,
                namedDestinations: [],
                catalogReadable: false,
                scanWasTruncated: false
            )
        }

        var budget = Budget(remaining: limits.maximumHazardScanNodes)
        var hazards: DocumentHazards = []
        var embeddedFiles: [EmbeddedFileEntry] = []

        // MARK: /OpenAction
        var openActionDictionary: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "OpenAction", &openActionDictionary),
           let openAction = openActionDictionary {
            hazards.insert(.openAction)
            hazards.formUnion(hazardsOfAction(openAction))
        } else {
            var openActionArray: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(catalog, "OpenAction", &openActionArray) {
                hazards.insert(.openAction)
            }
        }

        // MARK: /AA, /AcroForm
        var additionalActions: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "AA", &additionalActions) {
            hazards.insert(.documentAdditionalActions)
        }
        var acroForm: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm {
            hazards.insert(.acroForm)
            var xfa: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(acroForm, "XFA", &xfa) { hazards.insert(.xfaForm) }
            if hasSignatureValue(acroForm, budget: &budget) { hazards.insert(.signedDocument) }
        }
        var permissions: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Perms", &permissions) {
            hazards.insert(.signedDocument)
        }

        // MARK: /Names
        var names: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
            var javaScript: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(names, "JavaScript", &javaScript) {
                hazards.insert(.documentJavaScript)
            }
            var embedded: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &embedded), let embedded {
                hazards.insert(.embeddedFiles)
                embeddedFiles = readEmbeddedFileNames(embedded, budget: &budget)
            }
        }

        // MARK: page-level actions
        let pageDictionaries = pageDictionaryIndex(document: document, limits: limits)
        hazards.formUnion(scanPages(document: document, limits: limits, budget: &budget))

        // MARK: /PageLabels
        let labelRanges = readPageLabels(catalog: catalog, limits: limits, budget: &budget)

        // MARK: named destinations
        let destinations = readNamedDestinations(
            catalog: catalog,
            pageIndexByDictionary: pageDictionaries,
            limits: limits,
            budget: &budget
        )

        return CatalogReport(
            coreGraphicsPageCount: pageCount,
            hazards: hazards,
            embeddedFiles: embeddedFiles,
            pageLabelRanges: labelRanges,
            namedDestinations: destinations,
            catalogReadable: true,
            scanWasTruncated: budget.exhausted
        )
    }

    // MARK: - Signatures

    /// Whether any field in the form's `/Fields` tree is a signature field with a value
    /// (`/FT /Sig`, `/V` a dictionary). An empty signature field is a place to sign, not a
    /// signature. Bounded by the budget and a depth limit: `/Kids` is attacker-controlled.
    static func hasSignatureValue(_ acroForm: CGPDFDictionaryRef, budget: inout Budget) -> Bool {
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(acroForm, "Fields", &fields), let fields else { return false }
        return containsSignature(fields, inheritedType: nil, depth: 0, budget: &budget)
    }

    private static func containsSignature(
        _ fields: CGPDFArrayRef,
        inheritedType: String?,
        depth: Int,
        budget: inout Budget
    ) -> Bool {
        guard depth < 32 else { return false }
        for index in 0..<CGPDFArrayGetCount(fields) {
            guard budget.spend() else { return false }
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(fields, index, &field), let field else { continue }
            var type = inheritedType
            var name: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(field, "FT", &name), let name { type = String(cString: name) }
            var value: CGPDFDictionaryRef?
            if type == "Sig", CGPDFDictionaryGetDictionary(field, "V", &value) { return true }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(field, "Kids", &kids), let kids,
               containsSignature(kids, inheritedType: type, depth: depth + 1, budget: &budget) {
                return true
            }
        }
        return false
    }

    // MARK: - Budget

    /// A hard ceiling on how many PDF objects one inspection may touch.
    struct Budget {
        var remaining: Int
        private(set) var exhausted = false

        /// Consumes one unit. Returns `false` once the budget is gone, and every loop in
        /// this file exits on `false`.
        mutating func spend() -> Bool {
            guard remaining > 0 else {
                exhausted = true
                return false
            }
            remaining -= 1
            return true
        }
    }

    // MARK: - Actions

    /// The most actions one `/Next` chain is followed through. A chain is a tree (`/Next` may
    /// be an array) and may be cyclic, so it is bounded by count and by identity.
    static let maximumActionChainLength = 256

    /// The hazards of an action **and every action chained after it through `/Next`**.
    ///
    /// `/Next` is the standard way to chain actions, so `/S /GoTo … /Next << /S /JavaScript >>`
    /// runs a script after an innocent-looking jump. Reading only the leading `/S` reported
    /// such a file as carrying no script (BH-582, BH-583).
    static func hazardsOfAction(_ action: CGPDFDictionaryRef) -> DocumentHazards {
        var hazards: DocumentHazards = []
        var pending: [CGPDFDictionaryRef] = [action]
        var visited: Set<UInt> = []
        while let current = pending.popLast(), visited.count < maximumActionChainLength {
            guard visited.insert(identity(of: current)).inserted else { continue }
            switch name(in: current, key: "S") {
            case "JavaScript": hazards.insert(.javaScriptAction)
            case "Launch": hazards.insert(.launchAction)
            case "URI": hazards.insert(.externalURIAction)
            case "GoToR": hazards.insert(.remoteGoToAction)
            default: break
            }
            var next: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Next", &next), let next {
                pending.append(next)
            }
            var nextArray: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(current, "Next", &nextArray), let nextArray {
                let count = min(CGPDFArrayGetCount(nextArray), maximumActionChainLength)
                for index in 0..<count {
                    var element: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(nextArray, index, &element), let element {
                        pending.append(element)
                    }
                }
            }
        }
        return hazards
    }

    /// Walks every page's `/AA` and every annotation's `/A`, bounded by the budget.
    private static func scanPages(
        document: CGPDFDocument,
        limits: DocumentLimits,
        budget: inout Budget
    ) -> DocumentHazards {
        var hazards: DocumentHazards = []
        let pageCount = min(document.numberOfPages, limits.maximumPageCount)
        var pageNumber = 1
        while pageNumber <= pageCount {
            guard budget.spend() else { return hazards }
            defer { pageNumber += 1 }
            guard let page = document.page(at: pageNumber), let dictionary = page.dictionary else {
                continue
            }
            var pageActions: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "AA", &pageActions) {
                hazards.insert(.documentAdditionalActions)
            }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations),
                  let annotations else { continue }
            let annotationCount = min(CGPDFArrayGetCount(annotations), limits.maximumAnnotationsPerPage)
            var index = 0
            while index < annotationCount {
                guard budget.spend() else { return hazards }
                defer { index += 1 }
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation),
                      let annotation else { continue }
                var action: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(annotation, "A", &action), let action {
                    hazards.formUnion(hazardsOfAction(action))
                }
                var annotationActions: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(annotation, "AA", &annotationActions) {
                    hazards.insert(.documentAdditionalActions)
                }
            }
        }
        return hazards
    }

    // MARK: - Embedded files

    /// The uncompressed size an embedded-file stream declares.
    ///
    /// `/Params /Size` is that size (PDF 32000-1, table 45). `/Length` is the **encoded** byte
    /// count, so it is the uncompressed size only when the stream has no `/Filter`; reporting
    /// it for a `/FlateDecode` attachment called a 12 MB spreadsheet 1.3 MB (BH-584). With
    /// neither, the size is unknown and `nil`. Declared by the file, never verified.
    static func declaredUncompressedSize(of streamDictionary: CGPDFDictionaryRef) -> Int? {
        var params: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(streamDictionary, "Params", &params), let params {
            var size: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(params, "Size", &size), size >= 0 { return Int(size) }
        }
        var filter: CGPDFObjectRef?
        guard !CGPDFDictionaryGetObject(streamDictionary, "Filter", &filter) else { return nil }
        var length: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(streamDictionary, "Length", &length), length >= 0 else { return nil }
        return Int(length)
    }

    private static func readEmbeddedFileNames(
        _ tree: CGPDFDictionaryRef,
        budget: inout Budget
    ) -> [EmbeddedFileEntry] {
        var entries: [EmbeddedFileEntry] = []
        walkNameTree(tree, budget: &budget) { treeKey, object in
            var specification: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &specification),
                  let specification else {
                entries.append(EmbeddedFileEntry(name: treeKey, declaredByteCount: nil, mimeType: nil))
                return
            }
            // The stream is never dereferenced, decompressed, or written anywhere: the
            // point of listing an embedded file is to be able to show the user that the
            // PDF is carrying one (spec 7.4).
            var embeddedFiles: CGPDFDictionaryRef?
            var declaredSize: Int?  // declared by the file, never verified
            var mimeType: String?
            if CGPDFDictionaryGetDictionary(specification, "EF", &embeddedFiles), let embeddedFiles {
                var stream: CGPDFStreamRef?
                if CGPDFDictionaryGetStream(embeddedFiles, "F", &stream), let stream,
                   let streamDictionary = CGPDFStreamGetDictionary(stream) {
                    declaredSize = Self.declaredUncompressedSize(of: streamDictionary)
                    mimeType = Self.name(in: streamDictionary, key: "Subtype")
                }
            }
            let fileName = Self.string(in: specification, key: "UF")
                ?? Self.string(in: specification, key: "F")
                ?? treeKey
            entries.append(
                EmbeddedFileEntry(name: fileName, declaredByteCount: declaredSize, mimeType: mimeType)
            )
        }
        return entries
    }

    // MARK: - Page labels

    private static func readPageLabels(
        catalog: CGPDFDictionaryRef,
        limits: DocumentLimits,
        budget: inout Budget
    ) -> [PageLabelRange]? {
        var tree: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "PageLabels", &tree), let tree else {
            return nil
        }
        var ranges: [PageLabelRange] = []
        walkNumberTree(tree, budget: &budget) { key, object in
            guard ranges.count < limits.maximumPageLabelRanges else { return }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary),
                  let dictionary else { return }
            let styleName = name(in: dictionary, key: "S")
            let style = styleName.flatMap(PageLabelStyle.init(rawValue:))
            let prefix = string(in: dictionary, key: "P") ?? ""
            var start: CGPDFInteger = 1
            if !CGPDFDictionaryGetInteger(dictionary, "St", &start) { start = 1 }
            ranges.append(
                PageLabelRange(
                    startPageIndex: key,
                    style: style,
                    prefix: prefix,
                    firstNumber: Int(start)
                )
            )
        }
        return ranges
    }

    // MARK: - Named destinations

    private static func readNamedDestinations(
        catalog: CGPDFDictionaryRef,
        pageIndexByDictionary: [UInt: Int],
        limits: DocumentLimits,
        budget: inout Budget
    ) -> [NamedDestination] {
        var destinations: [NamedDestination] = []

        func appendDestination(name: String, object: CGPDFObjectRef) {
            guard destinations.count < limits.maximumNamedDestinations else { return }
            guard let target = resolveDestination(object, pageIndexByDictionary: pageIndexByDictionary)
            else { return }
            destinations.append(NamedDestination(name: name, target: target))
        }

        // PDF 1.2 and later: /Names /Dests, a name tree.
        var names: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
            var destinationTree: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(names, "Dests", &destinationTree), let destinationTree {
                walkNameTree(destinationTree, budget: &budget, visit: appendDestination)
            }
        }

        // PDF 1.1: a flat /Dests dictionary in the catalog.
        var legacy: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Dests", &legacy), let legacy {
            // Collection is bounded by the budget rather than materialising the whole dictionary
            // first: a hostile `/Dests` with millions of keys must not balloon into an array
            // before a single unit of budget is spent (CR-89). The block returns `false` to stop
            // the walk as soon as the budget (or the destination cap) is reached.
            var collected: [(String, CGPDFObjectRef)] = []
            let cap = min(budget.remaining, limits.maximumNamedDestinations)
            var stoppedShort = false
            CGPDFDictionaryApplyBlock(legacy, { key, object, _ in
                guard collected.count < cap else {
                    stoppedShort = true
                    return false
                }
                collected.append((String(cString: key), object))
                return true
            }, nil)
            for (name, object) in collected {
                guard budget.spend() else { break }
                appendDestination(name: name, object: object)
            }
            // Stopping at the budget's edge spends exactly the remaining units and never trips
            // `exhausted`, so the entries left unread would go unreported: they are a truncation
            // and the report must say so, as it does for every other walk that runs out.
            if stoppedShort, budget.remaining == 0 {
                _ = budget.spend()
            }
        }
        return destinations
    }

    private static func resolveDestination(
        _ object: CGPDFObjectRef,
        pageIndexByDictionary: [UInt: Int]
    ) -> DestinationTarget? {
        var array: CGPDFArrayRef?
        if !CGPDFObjectGetValue(object, .array, &array) {
            // `<< /D [ … ] >>` form.
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary),
                  let dictionary,
                  CGPDFDictionaryGetArray(dictionary, "D", &array) else { return nil }
        }
        guard let array, CGPDFArrayGetCount(array) >= 1 else { return nil }

        var pageDictionary: CGPDFDictionaryRef?
        var pageIndex: Int?
        if CGPDFArrayGetDictionary(array, 0, &pageDictionary), let pageDictionary {
            pageIndex = pageIndexByDictionary[identity(of: pageDictionary)]
        } else {
            // A remote destination stores a page *number* instead of a reference.
            var number: CGPDFInteger = 0
            if CGPDFArrayGetInteger(array, 0, &number), number >= 0 {
                pageIndex = Int(number)
            }
        }

        // Slot 1 is the fit type, and it decides where the coordinates live: reading slots 2/3
        // as (left, top) is correct only for `/XYZ`. A `/FitR left bottom right top` read that
        // way navigates to (bottom, right) — the wrong corner (CR-85). Parse per type.
        let (left, top, zoom) = Self.axesAndZoom(in: array)
        return DestinationTarget(pageIndex: pageIndex, pageLabel: nil, left: left, top: top, zoom: zoom)
    }

    /// The scroll coordinates and zoom a destination array specifies, according to its fit type.
    ///
    /// The PDF destination syntaxes (§12.3.2.2): `/XYZ left top zoom`, `/Fit`, `/FitH top`,
    /// `/FitV left`, `/FitR left bottom right top`, `/FitB`, `/FitBH top`, `/FitBV left`. `null`
    /// in a slot means "leave that coordinate unchanged" and is reported as that axis being
    /// `nil` — ``DestinationTarget/left`` and ``DestinationTarget/top`` carry each axis on its
    /// own, where a `CGPoint` had to fabricate a `0` for the missing one (BH-586). A `0` zoom
    /// means "keep the current zoom" and is reported as `nil`.
    static func axesAndZoom(in array: CGPDFArrayRef) -> (left: CGFloat?, top: CGFloat?, zoom: CGFloat?) {
        let count = CGPDFArrayGetCount(array)
        guard count >= 2 else { return (nil, nil, nil) }

        var namePointer: UnsafePointer<Int8>?
        guard CGPDFArrayGetName(array, 1, &namePointer), let namePointer else { return (nil, nil, nil) }
        let fit = String(cString: namePointer)

        func number(_ index: Int) -> CGFloat? {
            guard index < count else { return nil }
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value), value.isFinite else { return nil }
            return value
        }

        switch fit {
        case "XYZ":
            let zoom = number(4).flatMap { $0 > 0 ? $0 : nil }
            return (number(2), number(3), zoom)
        case "FitR":
            // left bottom right top → the top-left corner is (left, top).
            return (number(2), number(5), nil)
        case "FitH", "FitBH":
            // A vertical coordinate only: `top`.
            return (nil, number(2), nil)
        case "FitV", "FitBV":
            // A horizontal coordinate only: `left`.
            return (number(2), nil, nil)
        default:
            // `/Fit`, `/FitB`, or an unknown fit type: whole-page, no specific point.
            return (nil, nil, nil)
        }
    }

    // MARK: - Page identity

    /// Maps every page dictionary's address to its zero-based index, so a destination
    /// that points at a page object can be turned into a page number.
    static func pageDictionaryIndex(
        document: CGPDFDocument,
        limits: DocumentLimits
    ) -> [UInt: Int] {
        var map: [UInt: Int] = [:]
        let pageCount = min(document.numberOfPages, limits.maximumPageCount)
        map.reserveCapacity(pageCount)
        var pageNumber = 1
        while pageNumber <= pageCount {
            defer { pageNumber += 1 }
            guard let dictionary = document.page(at: pageNumber)?.dictionary else { continue }
            map[identity(of: dictionary)] = pageNumber - 1
        }
        return map
    }

    private static func identity(of dictionary: CGPDFDictionaryRef) -> UInt {
        unsafeBitCast(dictionary, to: UInt.self)
    }

    // MARK: - Tree walking

    /// Depth-first walk of a PDF *name* tree (`/Names` + `/Kids`), bounded.
    private static func walkNameTree(
        _ root: CGPDFDictionaryRef,
        budget: inout Budget,
        visit: (String, CGPDFObjectRef) -> Void
    ) {
        var stack: [CGPDFDictionaryRef] = [root]
        var visited = Set<UInt>()
        while let node = stack.popLast() {
            guard budget.spend() else { return }
            // A `/Kids` array that names an ancestor is a legal-looking cyclic tree.
            guard visited.insert(identity(of: node)).inserted else { continue }

            var pairs: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Names", &pairs), let pairs {
                let count = CGPDFArrayGetCount(pairs)
                var index = 0
                while index + 1 < count {
                    guard budget.spend() else { return }
                    defer { index += 2 }
                    var keyString: CGPDFStringRef?
                    guard CGPDFArrayGetString(pairs, index, &keyString),
                          let keyString,
                          let key = CGPDFStringCopyTextString(keyString) as String? else { continue }
                    var value: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(pairs, index + 1, &value), let value else { continue }
                    visit(key, value)
                }
            }

            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
                let count = CGPDFArrayGetCount(kids)
                var index = 0
                while index < count {
                    guard budget.spend() else { return }
                    defer { index += 1 }
                    var kid: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(kids, index, &kid), let kid { stack.append(kid) }
                }
            }
        }
    }

    /// Depth-first walk of a PDF *number* tree (`/Nums` + `/Kids`), bounded.
    private static func walkNumberTree(
        _ root: CGPDFDictionaryRef,
        budget: inout Budget,
        visit: (Int, CGPDFObjectRef) -> Void
    ) {
        var stack: [CGPDFDictionaryRef] = [root]
        var visited = Set<UInt>()
        while let node = stack.popLast() {
            guard budget.spend() else { return }
            guard visited.insert(identity(of: node)).inserted else { continue }

            var pairs: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Nums", &pairs), let pairs {
                let count = CGPDFArrayGetCount(pairs)
                var index = 0
                while index + 1 < count {
                    guard budget.spend() else { return }
                    defer { index += 2 }
                    var key: CGPDFInteger = 0
                    guard CGPDFArrayGetInteger(pairs, index, &key), key >= 0 else { continue }
                    var value: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(pairs, index + 1, &value), let value else { continue }
                    visit(Int(key), value)
                }
            }

            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
                let count = CGPDFArrayGetCount(kids)
                var index = 0
                while index < count {
                    guard budget.spend() else { return }
                    defer { index += 1 }
                    var kid: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(kids, index, &kid), let kid { stack.append(kid) }
                }
            }
        }
    }

    // MARK: - Scalars

    static func name(in dictionary: CGPDFDictionaryRef, key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    static func string(in dictionary: CGPDFDictionaryRef, key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }

    // MARK: - /Info

    /// Longest `/Info` string kept. A hostile document can declare a megabyte-long
    /// `/Title`; nothing downstream displays more than a window title's worth of it.
    static let maximumInfoValueLength = 4096
    /// Most `/Keywords` entries kept after splitting.
    static let maximumKeywordCount = 256

    /// Reads `/Info` with CoreGraphics.
    ///
    /// Deliberately **not** `PDFDocument.documentAttributes`: that getter enumerates the
    /// info dictionary into an `NSMutableDictionary` and inserts without checking, so an
    /// `/Info` entry whose key CoreGraphics reports but whose value PDFKit cannot map
    /// raises `NSInvalidArgumentException` ("key cannot be nil") from inside PDFKit. An
    /// Objective-C exception cannot be caught in Swift, so that is a process kill from a
    /// malformed file — found by byte-level fuzzing, seed 372734462224352. Reading the
    /// same six fields through CoreGraphics is bounded, typed, and cannot raise.
    static func documentInfo(document: CGPDFDocument?) -> DocumentAttributes {
        guard let document, let info = document.info else { return .empty }

        func text(_ key: String) -> String? {
            guard let value = string(in: info, key: key), !value.isEmpty else { return nil }
            return value.count <= maximumInfoValueLength
                ? value
                : String(value.prefix(maximumInfoValueLength))
        }

        let keywords: [String]
        if let raw = text("Keywords") {
            // Split on Unicode scalars, not Characters: "\r\n" is one grapheme cluster that
            // equals neither "\n" nor "\r", so a Windows producer's CRLF-separated keywords
            // came back as one keyword with an embedded CRLF (BH-587).
            let separators = CharacterSet(charactersIn: ",;\n\r")
            keywords = raw.unicodeScalars
                .split(whereSeparator: { separators.contains($0) })
                .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(maximumKeywordCount)
                .map { $0 }
        } else {
            keywords = []
        }

        return DocumentAttributes(
            title: text("Title"),
            author: text("Author"),
            subject: text("Subject"),
            creator: text("Creator"),
            producer: text("Producer"),
            keywords: keywords
        )
    }
}
