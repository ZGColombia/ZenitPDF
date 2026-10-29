import CoreGraphics
import Foundation

/// Reads the `/OCProperties` layer catalogue straight out of the PDF catalog with
/// CoreGraphics.
///
/// PDFKit is deliberately not involved: `PDFDocument` exposes no optional-content API
/// at all, and everything here — the `/OCGs` list, the `/D` default configuration,
/// `/Order`, `/RBGroups`, `/Locked`, `/Usage` — exists only as raw catalog dictionaries.
/// Like ``CatalogInspector``, every traversal is bounded, because the order tree and
/// the membership dictionaries are attacker-controlled and can be cyclic.
///
/// The rules:
/// - **No `/OCProperties`** is a perfectly normal document (most are) and reads as
///   `nil` — not an error, not an empty tree.
/// - **A broken catalogue** — `/OCProperties` present but `/OCGs` missing, not an
///   array, or containing a reference that does not resolve to a dictionary — is a
///   typed ``PDFBridgeError/layerCatalogUnreadable(reason:)``. A phantom or silently
///   dropped layer would make "hide this layer" lie about what is hidden.
/// - **Duplicate names are legal** and preserved; identity is positional
///   (``PDFLayerID/ocg(atIndex:)``), never name-based.
enum LayerCatalogReader {

    /// Reads the layer tree of `document`, or `nil` when the catalog declares none.
    static func read(
        document: CGPDFDocument?,
        limits: DocumentLimits
    ) throws -> PDFLayerTree? {
        guard let document, let catalog = document.catalog else { return nil }
        var properties: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties),
              let properties else {
            // Also treat a non-dictionary /OCProperties as absent only when the key is
            // truly missing; a present-but-wrong-typed entry is a broken catalogue.
            var anything: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, "OCProperties", &anything), anything != nil {
                throw PDFBridgeError.layerCatalogUnreadable(
                    reason: "/OCProperties is present but is not a dictionary"
                )
            }
            return nil
        }

        var budget = CatalogInspector.Budget(remaining: limits.maximumHazardScanNodes)

        // MARK: /OCGs — the canonical list; defines identity.
        var groupsArray: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(properties, "OCGs", &groupsArray), let groupsArray else {
            throw PDFBridgeError.layerCatalogUnreadable(
                reason: "/OCProperties has no /OCGs array"
            )
        }
        let groupCount = CGPDFArrayGetCount(groupsArray)
        var groupDictionaries: [CGPDFDictionaryRef] = []
        groupDictionaries.reserveCapacity(groupCount)
        var indexByIdentity: [UInt: Int] = [:]
        for index in 0..<groupCount {
            guard budget.spend() else { break }
            var group: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(groupsArray, index, &group), let group else {
                throw PDFBridgeError.layerCatalogUnreadable(
                    reason: "/OCGs[\(index)] does not resolve to a dictionary "
                        + "(missing object or wrong type)"
                )
            }
            groupDictionaries.append(group)
            // First occurrence wins if the same dictionary is listed twice.
            let key = identity(group)
            if indexByIdentity[key] == nil { indexByIdentity[key] = index }
        }

        // MARK: /D — the default configuration.
        var defaultConfiguration: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(properties, "D", &defaultConfiguration)

        // /BaseState defaults to /ON (PDF 32000-1, 8.11.4.3).
        var baseStateIsOn = true
        if let configuration = defaultConfiguration,
           let base = name(in: configuration, key: "BaseState") {
            baseStateIsOn = base != "OFF"
        }
        let onSet = identitySet(ofArray: "ON", in: defaultConfiguration, budget: &budget)
        let offSet = identitySet(ofArray: "OFF", in: defaultConfiguration, budget: &budget)
        let lockedSet = identitySet(ofArray: "Locked", in: defaultConfiguration, budget: &budget)

        var layers: [PDFLayer] = []
        layers.reserveCapacity(groupDictionaries.count)
        for (index, group) in groupDictionaries.enumerated() {
            let key = identity(group)
            var visible = baseStateIsOn
            if onSet.contains(key) { visible = true }
            if offSet.contains(key) { visible = false }
            layers.append(
                PDFLayer(
                    id: .ocg(atIndex: index),
                    name: displayName(of: group, fallbackIndex: index),
                    isVisibleByDefault: visible,
                    isLockedByDefault: lockedSet.contains(key),
                    usage: usageHints(of: group)
                )
            )
        }

        // MARK: /D /Order — the presentation tree.
        var outline: [PDFLayerNode] = []
        var mentioned: Set<Int> = []
        if let configuration = defaultConfiguration {
            var order: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(configuration, "Order", &order), let order {
                outline = orderNodes(
                    of: order,
                    indexByIdentity: indexByIdentity,
                    layers: layers,
                    mentioned: &mentioned,
                    depth: 0,
                    budget: &budget
                )
            }
        }
        // Every layer stays reachable: append the ones /Order never mentioned.
        for (index, layer) in layers.enumerated() where !mentioned.contains(index) {
            outline.append(PDFLayerNode(layerID: layer.id, title: layer.name))
        }

        // MARK: /RBGroups
        //
        // PDF 32000-1 Table 101 places /RBGroups in the optional-content *configuration*
        // dictionary — /D here — not in /OCProperties (BH-221). Reading only
        // /OCProperties missed every conforming file's radio groups. A file that puts it at
        // the /OCProperties level anyway is still honoured as a fallback, since that is
        // where earlier fixtures and some producers wrote it.
        var radioGroups: [[PDFLayerID]] = []
        var radio: CGPDFArrayRef?
        let radioFound: Bool = {
            if let configuration = defaultConfiguration,
               CGPDFDictionaryGetArray(configuration, "RBGroups", &radio), radio != nil {
                return true
            }
            return CGPDFDictionaryGetArray(properties, "RBGroups", &radio) && radio != nil
        }()
        if radioFound, let radio {
            let radioCount = CGPDFArrayGetCount(radio)
            for index in 0..<radioCount {
                guard budget.spend() else { break }
                var members: CGPDFArrayRef?
                guard CGPDFArrayGetArray(radio, index, &members), let members else { continue }
                var group: [PDFLayerID] = []
                for memberIndex in 0..<CGPDFArrayGetCount(members) {
                    guard budget.spend() else { break }
                    var member: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(members, memberIndex, &member), let member,
                          let layerIndex = indexByIdentity[identity(member)] else { continue }
                    group.append(.ocg(atIndex: layerIndex))
                }
                if !group.isEmpty { radioGroups.append(group) }
            }
        }

        // MARK: Per-page marked-content name bindings.
        let bindings = pageBindings(
            document: document,
            indexByIdentity: indexByIdentity,
            limits: limits,
            budget: &budget
        )

        return PDFLayerTree(
            layers: layers,
            outline: outline,
            radioGroups: radioGroups,
            pageBindings: bindings,
            scanWasTruncated: budget.exhausted
        )
    }

    // MARK: - Pieces

    private static func identity(_ dictionary: CGPDFDictionaryRef) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(dictionary.rawValue))
    }

    private static func name(in dictionary: CGPDFDictionaryRef, key: String) -> String? {
        var pointer: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(dictionary, key, &pointer), let pointer else { return nil }
        return String(cString: pointer)
    }

    private static func displayName(of group: CGPDFDictionaryRef, fallbackIndex: Int) -> String {
        var string: CGPDFStringRef?
        if CGPDFDictionaryGetString(group, "Name", &string), let string,
           let text = CGPDFStringCopyTextString(string) {
            return text as String
        }
        // /Name is required by the spec; a group without one still needs *something*
        // for the UI, and the positional id keeps it distinct.
        return "Layer \(fallbackIndex + 1)"
    }

    /// The pointer identities of the dictionaries in `configuration[key]`.
    private static func identitySet(
        ofArray key: String,
        in configuration: CGPDFDictionaryRef?,
        budget: inout CatalogInspector.Budget
    ) -> Set<UInt> {
        guard let configuration else { return [] }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(configuration, key, &array), let array else { return [] }
        var out: Set<UInt> = []
        for index in 0..<CGPDFArrayGetCount(array) {
            guard budget.spend() else { break }
            var member: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, index, &member), let member else { continue }
            out.insert(identity(member))
        }
        return out
    }

    private static func usageHints(of group: CGPDFDictionaryRef) -> PDFLayerUsageHints {
        var usage: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(group, "Usage", &usage), let usage else {
            return PDFLayerUsageHints()
        }
        func state(_ category: String, _ stateKey: String) -> Bool? {
            var inner: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(usage, category, &inner), let inner,
                  let value = name(in: inner, key: stateKey) else { return nil }
            return value == "ON"
        }
        return PDFLayerUsageHints(
            view: state("View", "ViewState"),
            print: state("Print", "PrintState"),
            export: state("Export", "ExportState")
        )
    }

    /// Recursively converts one `/Order` array level into nodes.
    ///
    /// Grammar (PDF 32000-1, 8.11.4.3): an element is an OCG reference, a nested array
    /// (children of the preceding OCG node), or — as a nested array's first element —
    /// a text string labelling a grouping that has no OCG of its own. Cycles cannot
    /// recurse forever: depth is capped by ``DocumentLimits/maximumOutlineDepth`` and
    /// every element costs budget.
    private static func orderNodes(
        of array: CGPDFArrayRef,
        indexByIdentity: [UInt: Int],
        layers: [PDFLayer],
        mentioned: inout Set<Int>,
        depth: Int,
        budget: inout CatalogInspector.Budget,
        startIndex: Int = 0
    ) -> [PDFLayerNode] {
        guard depth < 64 else { return [] }
        var nodes: [PDFLayerNode] = []
        let count = CGPDFArrayGetCount(array)
        var index = startIndex
        while index < count {
            guard budget.spend() else { break }
            defer { index += 1 }

            var group: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(array, index, &group), let group {
                guard let layerIndex = indexByIdentity[identity(group)] else {
                    // A dictionary /Order names but /OCGs does not list. It cannot be
                    // toggled (no identity), so it is presented as a label-only node.
                    nodes.append(
                        PDFLayerNode(
                            layerID: nil,
                            title: displayName(of: group, fallbackIndex: index)
                        )
                    )
                    continue
                }
                mentioned.insert(layerIndex)
                // An array immediately after an OCG holds that OCG's children.
                var children: [PDFLayerNode] = []
                if index + 1 < count {
                    var childArray: CGPDFArrayRef?
                    if CGPDFArrayGetArray(array, index + 1, &childArray), let childArray {
                        children = orderNodes(
                            of: childArray,
                            indexByIdentity: indexByIdentity,
                            layers: layers,
                            mentioned: &mentioned,
                            depth: depth + 1,
                            budget: &budget
                        )
                        index += 1
                    }
                }
                nodes.append(
                    PDFLayerNode(
                        layerID: layers[layerIndex].id,
                        title: layers[layerIndex].name,
                        children: children
                    )
                )
                continue
            }

            var nested: CGPDFArrayRef?
            if CGPDFArrayGetArray(array, index, &nested), let nested {
                // A bare nested array: if its first element is a string, it is a
                // label-only grouping; otherwise it is an anonymous grouping level.
                var title = ""
                var startIndex = 0
                var label: CGPDFStringRef?
                if CGPDFArrayGetCount(nested) > 0,
                   CGPDFArrayGetString(nested, 0, &label), let label,
                   let text = CGPDFStringCopyTextString(label) {
                    title = text as String
                    startIndex = 1
                }
                var children: [PDFLayerNode] = []
                if startIndex == 0 {
                    children = orderNodes(
                        of: nested,
                        indexByIdentity: indexByIdentity,
                        layers: layers,
                        mentioned: &mentioned,
                        depth: depth + 1,
                        budget: &budget
                    )
                } else {
                    // The tail after the label has the full grammar of any level: OCGs, the
                    // child arrays that follow them, and nested labelled groups. Walking it
                    // with a dictionary-only loop dropped every nested array, so sub-groups
                    // fell out of the hierarchy and were appended flat at the root (BH-588).
                    children = orderNodes(
                        of: nested,
                        indexByIdentity: indexByIdentity,
                        layers: layers,
                        mentioned: &mentioned,
                        depth: depth + 1,
                        budget: &budget,
                        startIndex: startIndex
                    )
                }
                nodes.append(PDFLayerNode(layerID: nil, title: title, children: children))
                continue
            }
            // Strings and anything else at this level: label-only node when readable.
            var label: CGPDFStringRef?
            if CGPDFArrayGetString(array, index, &label), let label,
               let text = CGPDFStringCopyTextString(label) {
                nodes.append(PDFLayerNode(layerID: nil, title: text as String))
            }
        }
        return nodes
    }

    /// Walks each page's `/Resources /Properties` and records which property names
    /// switch which layer, so extraction results (which carry the property *name*)
    /// can be joined back to layer identity. OCMD properties map to every group they
    /// reference.
    private static func pageBindings(
        document: CGPDFDocument,
        indexByIdentity: [UInt: Int],
        limits: DocumentLimits,
        budget: inout CatalogInspector.Budget
    ) -> [PDFLayerPageBinding] {
        var bindings: [PDFLayerPageBinding] = []
        let pageCount = min(document.numberOfPages, limits.maximumPageCount)
        var pageNumber = 1
        while pageNumber <= pageCount {
            guard budget.spend() else { break }
            defer { pageNumber += 1 }
            guard let page = document.page(at: pageNumber),
                  let pageDictionary = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources),
                  let resources else { continue }
            var propertiesDictionary: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "Properties", &propertiesDictionary),
                  let propertiesDictionary else { continue }

            var namesByLayer: [PDFLayerID: [String]] = [:]
            withUnsafeMutablePointer(to: &namesByLayer) { collected in
                CGPDFDictionaryApplyBlock(propertiesDictionary, { key, value, info in
                    guard let info else { return true }
                    let out = info.assumingMemoryBound(to: [PDFLayerID: [String]].self)
                    let propertyName = String(cString: key)
                    var target: CGPDFDictionaryRef?
                    guard CGPDFObjectGetValue(value, .dictionary, &target), let target else {
                        return true
                    }
                    for layerIndex in layerIndices(
                        of: target, indexByIdentity: indexByIdentity
                    ) {
                        out.pointee[.ocg(atIndex: layerIndex), default: []].append(propertyName)
                    }
                    return true
                }, UnsafeMutableRawPointer(collected))
            }
            guard !namesByLayer.isEmpty else { continue }
            // CGPDFDictionaryApplyBlock order is unspecified; sort for determinism.
            for (key, value) in namesByLayer { namesByLayer[key] = value.sorted() }
            bindings.append(
                PDFLayerPageBinding(pageIndex: pageNumber - 1, propertyNamesByLayer: namesByLayer)
            )
        }
        return bindings.sorted { $0.pageIndex < $1.pageIndex }
    }

    /// The `/OCGs` indices a property dictionary controls: the group itself, or every
    /// group an `/OCMD` lists.
    private static func layerIndices(
        of dictionary: CGPDFDictionaryRef,
        indexByIdentity: [UInt: Int]
    ) -> [Int] {
        if let direct = indexByIdentity[identity(dictionary)] { return [direct] }
        // An /OCMD whose lax producer omitted /Type is still an /OCMD: the annotation reader
        // accepts it, and requiring /Type here bound the layer's annotations but not its
        // marked content (BH-589). A dictionary typed as something else is not one.
        let type = name(in: dictionary, key: "Type")
        guard type == nil || type == "OCMD" else { return [] }
        var single: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "OCGs", &single), let single {
            return indexByIdentity[identity(single)].map { [$0] } ?? []
        }
        var many: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "OCGs", &many), let many else { return [] }
        var out: [Int] = []
        for index in 0..<CGPDFArrayGetCount(many) {
            var member: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(many, index, &member), let member,
                  let layerIndex = indexByIdentity[identity(member)] else { continue }
            out.append(layerIndex)
        }
        return out
    }
}
