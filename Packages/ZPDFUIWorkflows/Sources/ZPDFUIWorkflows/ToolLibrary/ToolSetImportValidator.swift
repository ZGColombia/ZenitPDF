import Foundation
import ZPDFUIPresentation

/// Reads a `.zpdftools` file and describes it, without believing a word of it.
///
/// The validator is the whole security posture of tool set import, and it rests on one rule:
/// **imported content is data.** Nothing in a tool set is executed, no address inside it is
/// followed, no image inside it is decoded during the review, and every value is bounded before
/// it reaches the Tool Library. Anything the validator cannot represent honestly it leaves out
/// and says so, rather than approximating it silently.
public struct ToolSetImportValidator: Sendable {

    /// The bounds a tool set has to stay inside.
    public struct Limits: Hashable, Sendable {

        /// Largest file the validator will parse at all.
        public var maximumFileByteCount: Int
        /// Largest number of tools one set may hold.
        public var maximumPresetCount: Int
        /// Largest number of embedded images one set may hold.
        public var maximumEmbeddedImageCount: Int
        /// Largest single embedded image, decoded.
        public var maximumEmbeddedImageByteCount: Int
        /// Largest pixel dimension of an embedded image.
        public var maximumImagePixelSide: Int
        /// Longest name, category or default value.
        public var maximumTextLength: Int
        /// Largest number of custom column defaults on one tool.
        public var maximumCustomDefaultCount: Int
        /// Longest assembly default (`zenit.assembly`, NL-QTY-07), in characters. An assignment is
        /// structured text — a recipe id and its parameters, and for an office recipe the recipe
        /// itself — so it is validated as a whole rather than shortened to
        /// ``maximumTextLength``, which would leave half a JSON object behind.
        public var maximumAssemblyDefaultLength: Int
        /// Schema versions this build can read.
        public var supportedSchemaVersions: ClosedRange<Int>

        /// Creates a set of limits.
        public init(
            maximumFileByteCount: Int = 8 * 1024 * 1024,
            maximumPresetCount: Int = 2_000,
            maximumEmbeddedImageCount: Int = 200,
            maximumEmbeddedImageByteCount: Int = 512 * 1024,
            maximumImagePixelSide: Int = 1_024,
            maximumTextLength: Int = 120,
            maximumCustomDefaultCount: Int = 64,
            maximumAssemblyDefaultLength: Int = 16_384,
            supportedSchemaVersions: ClosedRange<Int> = 1...1
        ) {
            self.maximumFileByteCount = maximumFileByteCount
            self.maximumPresetCount = maximumPresetCount
            self.maximumEmbeddedImageCount = maximumEmbeddedImageCount
            self.maximumEmbeddedImageByteCount = maximumEmbeddedImageByteCount
            self.maximumImagePixelSide = maximumImagePixelSide
            self.maximumTextLength = maximumTextLength
            self.maximumCustomDefaultCount = maximumCustomDefaultCount
            self.maximumAssemblyDefaultLength = maximumAssemblyDefaultLength
            self.supportedSchemaVersions = supportedSchemaVersions
        }

        /// The limits Zenit ships with.
        public static let standard = Limits()
    }

    /// The bounds this validator enforces.
    public var limits: Limits
    /// The panel imported tools are filed under. Imported libraries are read-only by design.
    public var destinationPanel: ToolLibraryPanel

    /// Creates a validator.
    public init(
        limits: Limits = .standard,
        destinationPanel: ToolLibraryPanel = .importedLibraries
    ) {
        self.limits = limits
        self.destinationPanel = destinationPanel
    }

    // MARK: - Entry point

    /// Describes a candidate tool set file.
    ///
    /// Returns a review whenever the bytes can be understood as a tool set at all, even when the
    /// review's verdict is "do not import" — the person is entitled to see what was in the file
    /// before deciding. Returns a failure only when there is nothing truthful to show.
    /// - Parameters:
    ///   - data: the candidate file's bytes.
    ///   - fileName: what to call it in the review.
    ///   - existingIdentifiers: the identities already in the destination library. A preset
    ///     claiming one of them is re-minted and reported, exactly as a preset claiming another
    ///     preset's identity inside the same file already was. Without this, importing the same
    ///     `.zpdftools` twice put two presets with one `UUID` into the library and broke
    ///     `ForEach` identity: delete, favourite and edit all hit the same one of them.
    ///     Finding CR-172.
    public func review(
        data: Data,
        fileName: String,
        existingIdentifiers: Set<UUID> = []
    ) -> Result<ToolSetImportReview, ZPDFUserFacingError> {
        guard data.count <= limits.maximumFileByteCount else {
            return .failure(oversizeRefusal(
                fileName: fileName,
                technicalDetail: "File is \(data.count) bytes; the limit is \(limits.maximumFileByteCount)."
            ))
        }
        let root: ToolSetJSONValue
        do {
            root = try ToolSetJSONValue.parse(data)
        } catch {
            return .failure(ZPDFUserFacingError(
                kind: .toolSetFileUnreadable,
                subject: fileName,
                technicalDetail: "The file is not valid JSON: \(error)"
            ))
        }
        guard root.objectValue != nil else {
            return .failure(ZPDFUserFacingError(
                kind: .toolSetFileUnreadable,
                subject: fileName,
                technicalDetail: "The top level of the file is not a JSON object."
            ))
        }
        return .success(review(
            root: root,
            fileName: fileName,
            byteCount: data.count,
            existingIdentifiers: existingIdentifiers
        ))
    }

    /// Reads a chosen file's bytes without ever holding more than the size limit (R-134).
    ///
    /// The file's size is asked of the file system first, and a file over the limit is refused
    /// with ``ZPDFErrorKind/toolSetFileTooLarge`` without a byte being read. The read that follows
    /// stops one byte past the limit, so a file that grows, or a volume that does not report a
    /// size, still cannot make the review hold an oversized file in memory. The old path read
    /// the whole file with `Data(contentsOf:)` on the main actor before the validator refused it.
    ///
    /// The caller holds any security-scoped access for the duration of the call.
    public func readCandidate(at url: URL) -> Result<Data, ZPDFUserFacingError> {
        let fileName = url.lastPathComponent
        let limit = limits.maximumFileByteCount
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit {
            return .failure(oversizeRefusal(
                fileName: fileName,
                technicalDetail: "File is \(size) bytes; the limit is \(limit). It was not read."
            ))
        }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            return .failure(ZPDFUserFacingError(
                kind: .toolSetFileUnreadable,
                subject: fileName,
                technicalDetail: "The file could not be read from disk: \(error)"
            ))
        }
        guard data.count <= limit else {
            return .failure(oversizeRefusal(
                fileName: fileName,
                technicalDetail: "File is more than \(limit) bytes; reading stopped at the limit."
            ))
        }
        return .success(data)
    }

    /// The one refusal for a file over the size limit, whichever path found it.
    private func oversizeRefusal(fileName: String, technicalDetail: String) -> ZPDFUserFacingError {
        ZPDFUserFacingError(
            kind: .toolSetFileTooLarge,
            subject: fileName,
            secondarySubject: ByteCountFormatter.string(
                fromByteCount: Int64(limits.maximumFileByteCount), countStyle: .file
            ),
            technicalDetail: technicalDetail
        )
    }

    /// Describes a tool set Zenit itself produced. Used by the export round-trip test and by
    /// previews, and it takes exactly the same path as an imported file.
    public func review(document: ToolSetDocument, fileName: String) -> ToolSetImportReview {
        guard let data = try? document.jsonData(),
              case let .success(result) = review(data: data, fileName: fileName) else {
            return ToolSetImportReview(
                fileName: fileName,
                setName: document.name,
                schemaVersion: document.schemaVersion,
                byteCount: 0,
                declaredPresetCount: document.presets.count,
                presets: [],
                markupKindCounts: [:],
                measurementKindCounts: [:],
                countSymbolNames: [],
                customDefaultKeys: [],
                embeddedImages: [],
                findings: [ToolSetImportFinding(
                    id: "emptySet#0",
                    code: .emptySet,
                    message: NSLocalizedString(
                        "This set could not be written out and read back, so Zenit will not add it.",
                        comment: "Import finding: round trip failed"
                    )
                )]
            )
        }
        return result
    }

    // MARK: - Review

    private func review(
        root: ToolSetJSONValue,
        fileName: String,
        byteCount: Int,
        existingIdentifiers: Set<UUID> = []
    ) -> ToolSetImportReview {
        var findings = FindingCollector()

        let schemaVersion = root["schemaVersion"]?.intValue ?? 0
        let setName = boundedText(
            root["name"]?.stringValue ?? fileName,
            fieldName: "name",
            presetName: nil,
            findings: &findings
        )
        let author = root["author"]?.stringValue.map {
            boundedText($0, fieldName: "author", presetName: nil, findings: &findings)
        }
        let exportedAt = root["exportedAt"]?.stringValue.flatMap {
            ISO8601DateFormatter().date(from: $0)
        }

        if !limits.supportedSchemaVersions.contains(schemaVersion) {
            findings.add(
                .unsupportedSchemaVersion,
                message: String(
                    format: NSLocalizedString(
                        "This set was written for tool set format %1$d. This version of Zenit reads format %2$d, so it cannot add the tools without guessing at what they mean.",
                        comment: "Import finding: unsupported schema version. %1$d is the file's version, %2$d the supported one"
                    ),
                    schemaVersion,
                    limits.supportedSchemaVersions.upperBound
                )
            )
        }

        reportUnknownFields(
            in: root,
            known: ToolSetDocument.knownFieldNames,
            presetName: nil,
            findings: &findings
        )

        let rawPresets = root["presets"]?.arrayValue ?? []
        if rawPresets.isEmpty {
            findings.add(
                .emptySet,
                message: NSLocalizedString(
                    "This file does not describe any tools, so there is nothing to add.",
                    comment: "Import finding: the set is empty"
                )
            )
        }
        if rawPresets.count > limits.maximumPresetCount {
            findings.add(
                .tooManyPresets,
                message: String(
                    format: NSLocalizedString(
                        "This file describes %1$@. A tool set may hold at most %2$lld, so Zenit will not read it.",
                        comment: "Import finding: too many presets. 1: the file's count as '600 tools', 2: the limit"
                    ),
                    WorkflowPlurals.tools(rawPresets.count),
                    limits.maximumPresetCount
                )
            )
        }

        var presets: [ToolPresetSummary] = []
        var images: [ToolSetEmbeddedImageReview] = []
        // Seeded with the destination library's identities, so a file imported twice collides
        // with itself and is re-minted on the second pass instead of arriving as a duplicate.
        var seenIdentifiers = existingIdentifiers
        var acceptedImageCount = 0
        var libraryMatches: [UUID: UUID] = [:]

        let readablePresets = rawPresets.count <= limits.maximumPresetCount ? rawPresets : []
        for (index, rawPreset) in readablePresets.enumerated() {
            guard let outcome = reviewPreset(
                rawPreset,
                index: index,
                fileName: fileName,
                alreadyInLibrary: existingIdentifiers,
                seenIdentifiers: &seenIdentifiers,
                acceptedImageCount: &acceptedImageCount,
                findings: &findings
            ) else { continue }
            presets.append(outcome.preset)
            if let original = outcome.matchedLibraryIdentifier {
                libraryMatches[outcome.preset.id] = original
            }
            if let image = outcome.image {
                images.append(image)
            }
        }

        var markupCounts: [MarkupKind: Int] = [:]
        var measurementCounts: [MeasurementKind: Int] = [:]
        var symbolNames: Set<String> = []
        var customKeys: Set<String> = []
        for preset in presets {
            markupCounts[preset.markupKind, default: 0] += 1
            if let kind = preset.measurementKind {
                measurementCounts[kind, default: 0] += 1
            }
            if let symbol = preset.countSymbolName {
                symbolNames.insert(symbol)
            }
            customKeys.formUnion(preset.customDefaults.keys)
        }

        return ToolSetImportReview(
            fileName: fileName,
            setName: setName,
            declaredAuthor: author,
            declaredExportDate: exportedAt,
            schemaVersion: schemaVersion,
            byteCount: byteCount,
            declaredPresetCount: rawPresets.count,
            presets: presets,
            markupKindCounts: markupCounts,
            measurementKindCounts: measurementCounts,
            countSymbolNames: symbolNames.sorted(),
            customDefaultKeys: customKeys.sorted(),
            embeddedImages: images,
            findings: findings.sorted(),
            libraryMatches: libraryMatches
        )
    }

    private struct PresetOutcome {
        var preset: ToolPresetSummary
        var image: ToolSetEmbeddedImageReview?
        /// The library identity this tool's own identity collided with, before the re-mint.
        var matchedLibraryIdentifier: UUID?
    }

    private func reviewPreset(
        _ raw: ToolSetJSONValue,
        index: Int,
        fileName: String,
        alreadyInLibrary: Set<UUID> = [],
        seenIdentifiers: inout Set<UUID>,
        acceptedImageCount: inout Int,
        findings: inout FindingCollector
    ) -> PresetOutcome? {
        guard raw.objectValue != nil else {
            findings.add(
                .missingRequiredField,
                message: String(
                    format: NSLocalizedString(
                        "Entry %d in this file is not a tool description, so it was left out.",
                        comment: "Import finding: a presets array element is not an object"
                    ),
                    index + 1
                )
            )
            return nil
        }

        let rawName = raw["name"]?.stringValue ?? ""
        let fallbackName = String(
            format: NSLocalizedString("Tool %d", comment: "Fallback name for an unnamed imported tool"),
            index + 1
        )
        // Blank is judged on the text as it will be stored, after control characters become
        // spaces and the ends are trimmed. The old test trimmed only whitespace, so a name of
        // "\u{0007}" passed it and was then cleaned down to "" by `boundedText`: a blank tile
        // that, being imported, could not even be renamed (R-132).
        let nameIsBlank = Self.cleanedText(rawName).isEmpty
        let displayName = nameIsBlank ? fallbackName : rawName
        if nameIsBlank, raw["name"]?.stringValue != nil {
            findings.add(
                .missingRequiredField,
                presetName: displayName,
                message: String(
                    format: NSLocalizedString(
                        "This tool's name is blank, so it was named \"%@\".",
                        comment: "Import finding: a tool's name is empty or only invisible characters. %@ is the name it was given"
                    ),
                    fallbackName
                )
            )
        }

        reportUnknownFields(
            in: raw,
            known: ToolSetPresetRecord.knownFieldNames,
            presetName: displayName,
            findings: &findings
        )

        guard let markupRaw = raw["markupType"]?.stringValue else {
            findings.add(
                .missingRequiredField,
                presetName: displayName,
                message: NSLocalizedString(
                    "This tool does not say what kind of markup it places, so Zenit cannot add it.",
                    comment: "Import finding: preset has no markup type"
                )
            )
            return nil
        }
        guard let markupKind = MarkupKind(rawValue: markupRaw) else {
            findings.add(
                .unknownMarkupType,
                presetName: displayName,
                message: String(
                    format: NSLocalizedString(
                        "This tool places a kind of markup this version of Zenit does not have (\"%@\"), so it was left out rather than turned into something else.",
                        comment: "Import finding: unknown markup type. %@ is the raw value from the file"
                    ),
                    sanitizedForDisplay(markupRaw)
                )
            )
            return nil
        }

        var measurementKind: MeasurementKind?
        if let toolRaw = raw["measurementTool"]?.stringValue {
            measurementKind = MeasurementKind(rawValue: toolRaw)
            if measurementKind == nil {
                findings.add(
                    .unknownMeasurementTool,
                    presetName: displayName,
                    message: String(
                        format: NSLocalizedString(
                            "This tool asks for a measurement tool this version of Zenit does not have (\"%@\"). The preset was kept, but it will not measure. Imported tools cannot be edited: duplicate it into My Tools and pick a tool for the copy.",
                            comment: "Import finding: unknown measurement tool. %@ is the raw value from the file"
                        ),
                        sanitizedForDisplay(toolRaw)
                    )
                )
            }
        }

        var displayUnit = LengthUnit.metre
        if let unitRaw = raw["displayLengthUnit"]?.stringValue {
            if let parsed = LengthUnit(rawValue: unitRaw) {
                displayUnit = parsed
            } else {
                findings.add(
                    .unknownDisplayUnit,
                    presetName: displayName,
                    message: String(
                        format: NSLocalizedString(
                            "This tool asks to display lengths in a unit Zenit does not know (\"%@\"). It will use metres. Imported tools cannot be edited: duplicate it into My Tools to choose another unit for the copy.",
                            comment: "Import finding: unknown display unit. %@ is the raw value from the file"
                        ),
                        sanitizedForDisplay(unitRaw)
                    )
                )
            }
        }

        let color = parseColor(
            raw["color"]?.stringValue,
            presetName: displayName,
            findings: &findings
        )

        var identifier = raw["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
        var matchedLibraryIdentifier: UUID?
        if seenIdentifiers.contains(identifier) {
            if alreadyInLibrary.contains(identifier) { matchedLibraryIdentifier = identifier }
            findings.add(
                .duplicateIdentifier,
                presetName: displayName,
                message: alreadyInLibrary.contains(identifier)
                    ? NSLocalizedString(
                        "A tool already in your Tool Library claims this identity. This one was given a fresh identity, so importing the same file twice adds a second tool instead of two tools that cannot be told apart.",
                        comment: "Import finding: the preset's identity is already in the library"
                    )
                    : NSLocalizedString(
                        "Two tools in this file claim the same identity. The second one was given a fresh identity so neither overwrites the other.",
                        comment: "Import finding: duplicate preset identifier"
                    )
            )
            identifier = UUID()
        }
        seenIdentifiers.insert(identifier)

        let name = boundedText(displayName, fieldName: "name", presetName: displayName, findings: &findings)
        let defaultCategory = NSLocalizedString("Imported", comment: "Default category for imported tools")
        var category = boundedText(
            raw["category"]?.stringValue ?? defaultCategory,
            fieldName: "category",
            presetName: displayName,
            findings: &findings
        )
        // The default used to apply only when the key was missing, so `"category": "  "` filed
        // the tool under a blank section header (R-132).
        if category.isEmpty {
            category = defaultCategory
            findings.add(
                .missingRequiredField,
                presetName: displayName,
                message: String(
                    format: NSLocalizedString(
                        "This tool's category is blank, so it was filed under \"%@\".",
                        comment: "Import finding: a tool's category is empty or only invisible characters. %@ is the category it was given"
                    ),
                    defaultCategory
                )
            )
        }
        let subject = boundedText(
            raw["defaultSubject"]?.stringValue ?? "",
            fieldName: "defaultSubject",
            presetName: displayName,
            findings: &findings
        )

        let customDefaults = boundedDefaults(
            raw["customDefaults"],
            presetName: displayName,
            findings: &findings
        )

        let symbolName = sanitizedSymbolName(
            raw["countSymbolName"]?.stringValue,
            presetName: displayName,
            findings: &findings
        )

        var image = reviewEmbeddedImage(
            raw["embeddedImage"],
            presetName: displayName,
            index: index,
            acceptedImageCount: &acceptedImageCount,
            findings: &findings
        )
        image?.presetID = identifier

        let stamp = reviewStamp(
            raw["stamp"],
            identifier: identifier,
            markupKind: markupKind,
            image: image,
            presetName: displayName,
            findings: &findings
        )

        let measurementDefaults = reviewMeasurementDefaults(
            raw["measurementDefaults"],
            presetName: displayName,
            findings: &findings
        )
        let labelPattern = boundedText(
            raw["labelPattern"]?.stringValue ?? "",
            fieldName: "labelPattern",
            presetName: displayName,
            findings: &findings
        )
        let defaultStatus = raw["defaultStatus"]?.stringValue
            .flatMap(MarkupStatus.init(storedValue:)) ?? .none
        let style = reviewStyle(
            raw["style"],
            stroke: color,
            presetName: displayName,
            findings: &findings
        )

        let preset = ToolPresetSummary(
            id: identifier,
            schemaVersion: ToolSetDocument.currentSchemaVersion,
            name: name,
            category: category,
            panel: destinationPanel,
            markupKind: markupKind,
            measurementKind: measurementKind,
            colorRGBA: color,
            defaultSubject: subject,
            measurementDefaults: measurementDefaults,
            labelPattern: labelPattern,
            defaultStatus: defaultStatus,
            displayLengthUnit: displayUnit,
            customDefaults: customDefaults,
            countSymbolName: symbolName,
            stamp: stamp,
            provenance: ToolPresetProvenance(
                origin: .imported, sourceFileName: fileName, recordedAt: Date()
            ),
            isFavorite: false,
            isReadOnly: !destinationPanel.isEditable,
            shortcutDisplayString: nil,
            sortIndex: index,
            style: style
        )
        return PresetOutcome(preset: preset, image: image, matchedLibraryIdentifier: matchedLibraryIdentifier)
    }

    /// Reads one preset's measurement block out of an untrusted file.
    ///
    /// Every number is bounded and every enumeration is matched against the cases this build
    /// has. Nothing here can make the import fail: a slope of `1e300` or a policy Zenit has
    /// never heard of costs that one field and is reported, because refusing a whole tool set
    /// over a bad depth would make the review useless for the case it exists to serve — a set
    /// that is mostly fine and partly wrong.
    ///
    /// A non-finite or absurd number is dropped rather than clamped. Clamping would invent a
    /// value the exporter never wrote and store it as if the estimator had typed it.
    private func reviewMeasurementDefaults(
        _ value: ToolSetJSONValue?,
        presetName: String,
        findings: inout FindingCollector
    ) -> ToolPresetMeasurementDefaults {
        guard let value, let members = value.objectValue else { return .none }
        reportUnknownFields(
            in: value,
            known: ToolSetMeasurementRecord.knownFieldNames,
            presetName: presetName,
            findings: &findings
        )

        /// A field that is present but is not a number used to be dropped with nothing said:
        /// `"depthMetres": "0.2"` (the record's own doc comment says quantities travel as
        /// display strings) or `true` left the tool without a depth and the review silent.
        /// Finding BH-854. It is now reported like every other value the import will not store.
        func number(_ key: String) -> Double? {
            guard let member = members[key] else { return nil }
            if case .null = member { return nil }
            guard let raw = member.doubleValue else {
                findings.add(
                    .valueOutOfRange,
                    presetName: presetName,
                    message: String(
                        format: NSLocalizedString(
                            "The value in \"%@\" is not a number, so this tool arrives without it.",
                            comment: "Import finding: a measurement parameter was text or true/false rather than a number. %@ is the field name"
                        ),
                        sanitizedForDisplay(key)
                    )
                )
                return nil
            }
            return raw
        }

        /// The range check is ``ToolPresetParameterRule``, the rule the editor applies, so a
        /// tool the editor saves is a tool the importer accepts back (IM-036). It used to be
        /// `raw != 0` for every length, which refused a wall height *at the far end* of zero —
        /// a retaining wall tapering to grade, which the engine accepts — so such a tool came
        /// back from its own export as a constant-height wall with twice the area. Finding
        /// BH-321. A negative length, which `abs(raw)` used to let through, is refused too.
        func length(_ key: String, _ field: ToolPresetParameterRule.Field) -> DecimalQuantity? {
            guard let raw = number(key) else { return nil }
            guard ToolPresetParameterRule.isStorableLength(raw, in: field) else {
                findings.add(
                    .valueOutOfRange,
                    presetName: presetName,
                    message: String(
                        format: NSLocalizedString(
                            "The value in \"%@\" is not a length Zenit will store, so this tool arrives without it.",
                            comment: "Import finding: a measurement parameter was out of range. %@ is the field name"
                        ),
                        sanitizedForDisplay(key)
                    )
                )
                return nil
            }
            // `?? 0` used to stand here, and it is the one thing this whole function exists to
            // prevent: a length that clears the finite and range guards but does not survive
            // `Double` -> `String` -> `Decimal` — `1e-300` writes as "1e-300", which
            // `Decimal(string:)` does not read — became a depth of exactly ZERO, stored as if
            // the exporter had written it, and a volume computed from it comes out as nothing.
            // A value that will not convert is dropped and reported, like every other value
            // this function will not store. Finding CR-186.
            guard let value = Decimal(
                string: String(raw),
                locale: Locale(identifier: "en_US_POSIX")
            ), !value.isNaN else {
                findings.add(
                    .valueOutOfRange,
                    presetName: presetName,
                    message: String(
                        format: NSLocalizedString(
                            "The value in \"%@\" is not a length Zenit can store exactly, so this tool arrives without it.",
                            comment: "Import finding: a measurement parameter would not convert. %@ is the field name"
                        ),
                        sanitizedForDisplay(key)
                    )
                )
                return nil
            }
            return DecimalQuantity(value: value, dimension: .length)
        }

        func bounded(_ key: String) -> Double? {
            guard let raw = number(key) else { return nil }
            guard ToolPresetParameterRule.isStorableMagnitude(raw) else {
                findings.add(
                    .valueOutOfRange,
                    presetName: presetName,
                    message: String(
                        format: NSLocalizedString(
                            "The value in \"%@\" is outside the range Zenit accepts, so this tool arrives without it.",
                            comment: "Import finding: a numeric parameter was out of range. %@ is the field name"
                        ),
                        sanitizedForDisplay(key)
                    )
                )
                return nil
            }
            return raw
        }

        func enumeration<Value: RawRepresentable>(
            _ key: String,
            _ type: Value.Type
        ) -> Value? where Value.RawValue == String {
            guard let raw = members[key]?.stringValue else { return nil }
            guard let parsed = Value(rawValue: raw) else {
                findings.add(
                    .unknownField,
                    presetName: presetName,
                    message: String(
                        format: NSLocalizedString(
                            "This tool asks for a setting this version of Zenit does not have (\"%@\"). Zenit's own default is used instead.",
                            comment: "Import finding: unknown enumeration value. %@ is the raw value from the file"
                        ),
                        sanitizedForDisplay(raw)
                    )
                )
                return nil
            }
            return parsed
        }

        return ToolPresetMeasurementDefaults(
            depth: length("depthMetres", .depth),
            wallHeight: length("wallHeightMetres", .wallHeight),
            wallHeightAtEnd: length("wallHeightAtEndMetres", .wallHeightAtEnd),
            // A slope above 100 % is accepted with a warning by ADR-0004 §5, so the import bound
            // is generous rather than opinionated: it is here to refuse nonsense, not to have a
            // second opinion about roofs.
            slopePercent: bounded("slopePercent"),
            slopeAzimuthDegrees: bounded("slopeAzimuthDegrees"),
            volumeDepthReference: enumeration("volumeDepthReference", ToolPresetVolumeDepthReference.self),
            cutoutPolicy: enumeration("cutoutPolicy", ToolPresetCutoutPolicy.self) ?? .subtractFromArea,
            perimeterPolicy: enumeration("perimeterPolicy", ToolPresetPerimeterPolicy.self) ?? .outerOnly
        )
    }

    /// Reads one preset's style block out of an untrusted file (V-060).
    ///
    /// The same rules as the measurement block: every number is bounded
    /// (``ToolSetStyleRecord``'s ranges), every enumeration matched against this build's cases,
    /// every colour a six-digit hex value, the font name plain text. A value that fails costs
    /// that one field — it takes the style's default — and is reported; nothing is clamped
    /// into range and nothing here can refuse the tool. `nil` when the file carries no style,
    /// so the tool places its colour over the defaults, as a preset saved before round 2 does.
    private func reviewStyle(
        _ value: ToolSetJSONValue?,
        stroke: ColorRGBA,
        presetName: String,
        findings: inout FindingCollector
    ) -> ToolStyleSelection? {
        guard let value, let members = value.objectValue else { return nil }
        reportUnknownFields(
            in: value,
            known: ToolSetStyleRecord.knownFieldNames,
            presetName: presetName,
            findings: &findings
        )
        let defaults = ToolStyleSelection(stroke: stroke)

        func leaveOut(_ key: String) {
            findings.add(
                .valueOutOfRange,
                presetName: presetName,
                message: String(
                    format: NSLocalizedString(
                        "The style's \"%@\" is not something Zenit will store, so this tool arrives without it.",
                        comment: "Import finding: part of a tool's style was out of range or unreadable. %@ is the field name"
                    ),
                    sanitizedForDisplay(key)
                )
            )
        }
        func present(_ key: String) -> ToolSetJSONValue? {
            guard let member = members[key] else { return nil }
            if case .null = member { return nil }
            return member
        }
        func number(_ key: String, in range: ClosedRange<Double>) -> Double? {
            guard let member = present(key) else { return nil }
            guard let raw = member.doubleValue, raw.isFinite, range.contains(raw) else {
                leaveOut(key)
                return nil
            }
            return raw
        }
        func flag(_ key: String) -> Bool? {
            guard let member = present(key) else { return nil }
            guard case .bool(let raw) = member else {
                leaveOut(key)
                return nil
            }
            return raw
        }
        func enumeration<Value: RawRepresentable>(
            _ key: String,
            _ type: Value.Type
        ) -> Value? where Value.RawValue == String {
            guard let member = present(key) else { return nil }
            guard let raw = member.stringValue, let parsed = Value(rawValue: raw) else {
                leaveOut(key)
                return nil
            }
            return parsed
        }
        func colour(_ key: String) -> ColorRGBA? {
            guard let member = present(key) else { return nil }
            guard let text = member.stringValue, let packed = Self.packedHexColour(text) else {
                leaveOut(key)
                return nil
            }
            return ColorRGBA(hex: packed)
        }

        var fontName = defaults.fontName
        if let member = present("fontName") {
            if let raw = member.stringValue, Self.isPlainFontName(raw) {
                fontName = raw
            } else {
                leaveOut("fontName")
            }
        }
        let fillOpacity = number("fillOpacity", in: ToolSetStyleRecord.unitRange)
        return ToolStyleSelection(
            stroke: stroke,
            fill: colour("fill").map { fillOpacity.map($0.withAlpha) ?? $0 },
            lineWidth: number("lineWidth", in: ToolSetStyleRecord.lineWidthRange) ?? defaults.lineWidth,
            fontName: fontName,
            fontSize: number("fontSize", in: ToolSetStyleRecord.fontSizeRange) ?? defaults.fontSize,
            lineStyle: enumeration("lineStyle", MarkupLineStyle.self),
            opacity: number("opacity", in: ToolSetStyleRecord.unitRange) ?? defaults.opacity,
            startCap: enumeration("startCap", MarkupLineCap.self),
            endCap: enumeration("endCap", MarkupLineCap.self),
            textAlignment: enumeration("textAlignment", MarkupTextAlignment.self),
            multiplyBlend: flag("multiplyBlend") ?? defaults.multiplyBlend,
            cloudArcSize: number("cloudArcSize", in: ToolSetStyleRecord.cloudArcSizeRange),
            bold: flag("bold") ?? defaults.bold,
            italic: flag("italic") ?? defaults.italic,
            textColor: colour("textColor"),
            boxBorder: flag("boxBorder") ?? defaults.boxBorder
        )
    }

    /// A font family name as a person or the font panel writes it: letters, digits, spaces,
    /// hyphens, dots and underscores, at most ``ToolSetStyleRecord/maximumFontNameLength``.
    /// Anything else is not a font name and is not stored.
    static func isPlainFontName(_ text: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -._"))
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && text.count <= ToolSetStyleRecord.maximumFontNameLength
            && text.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// `#RRGGBB` (or `RRGGBB`) as its packed value, or `nil` for anything else. The one colour
    /// grammar of a tool set: the preset colour and the style's colours read through it.
    static func packedHexColour(_ text: String) -> UInt32? {
        let trimmed = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard trimmed.count == 6, trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(trimmed, radix: 16)
    }

    // MARK: - Field checks

    private func reportUnknownFields(
        in value: ToolSetJSONValue,
        known: Set<String>,
        presetName: String?,
        findings: inout FindingCollector
    ) {
        guard let members = value.objectValue else { return }
        for key in members.keys.sorted() where !known.contains(key) {
            findings.add(
                .unknownField,
                presetName: presetName,
                message: String(
                    format: NSLocalizedString(
                        "This file carries a field Zenit does not use (\"%@\"). It was read as plain text, changed nothing, and will not be written back.",
                        comment: "Import finding: unknown field. %@ is the field name from the file"
                    ),
                    sanitizedForDisplay(key)
                )
            )
        }
    }

    /// Text as it is stored: NULs removed, every other control character a space, the ends
    /// trimmed. ``boundedText(_:fieldName:presetName:findings:)`` stores this, and the blank
    /// checks for a name and a category test it, so a value cannot pass as present and then
    /// be cleaned down to nothing (R-132).
    static func cleanedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{0000}", with: "")
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func boundedText(
        _ text: String,
        fieldName: String,
        presetName: String?,
        findings: inout FindingCollector
    ) -> String {
        var value = Self.cleanedText(text)
        reportSuspiciousText(value, fieldName: fieldName, presetName: presetName, findings: &findings)
        if value.count > limits.maximumTextLength {
            findings.add(
                .overlongText,
                presetName: presetName,
                message: String(
                    format: NSLocalizedString(
                        "The text in \"%1$@\" was longer than %2$d characters and was shortened so it fits on screen.",
                        comment: "Import finding: overlong text. %1$@ is the field name, %2$d the limit"
                    ),
                    fieldName,
                    limits.maximumTextLength
                )
            )
            value = String(value.prefix(limits.maximumTextLength))
        }
        return value
    }

    /// Tells the person about text written like code or pointing outside the file. Reporting
    /// only: the text is stored and shown as written, never run and never followed.
    private func reportSuspiciousText(
        _ value: String,
        fieldName: String,
        presetName: String?,
        findings: inout FindingCollector
    ) {
        if looksLikeMarkupOrScript(value) {
            findings.add(
                .markupLikeText,
                presetName: presetName,
                message: String(
                    format: NSLocalizedString(
                        "The text in \"%@\" is written like code. Zenit stores it and shows it exactly as it is written, and never runs it.",
                        comment: "Import finding: script-like text. %@ is the field name"
                    ),
                    fieldName
                )
            )
        }
        if looksLikeExternalReference(value) {
            findings.add(
                .externalReference,
                presetName: presetName,
                message: String(
                    format: NSLocalizedString(
                        "The text in \"%@\" points at somewhere outside this file. Zenit shows it as text and does not go and fetch it.",
                        comment: "Import finding: external reference. %@ is the field name"
                    ),
                    fieldName
                )
            )
        }
    }

    private func boundedDefaults(
        _ value: ToolSetJSONValue?,
        presetName: String,
        findings: inout FindingCollector
    ) -> [String: String] {
        guard let members = value?.objectValue, !members.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for key in members.keys.sorted() {
            if result.count >= limits.maximumCustomDefaultCount {
                findings.add(
                    .tooManyDefaults,
                    presetName: presetName,
                    message: WorkflowPlurals.tooManyCustomValues(limits.maximumCustomDefaultCount)
                )
                break
            }
            guard let text = members[key]?.stringValue else { continue }
            let boundedKey = boundedText(key, fieldName: "customDefaults", presetName: presetName, findings: &findings)
            guard !boundedKey.isEmpty else { continue }
            // NL-QTY-07 / ADR-0035 §4: a tool's assembly is structured text of a couple of
            // hundred characters. Cut to the 120 every other default is cut to, it became invalid
            // JSON and the tool arrived without its assembly behind nothing but an "overlong
            // text" notice. It is checked whole instead, and kept or left out whole.
            if boundedKey == ToolPresetAssemblyCatalog.defaultKey {
                if let assembly = boundedAssembly(text, presetName: presetName, findings: &findings) {
                    result[boundedKey] = assembly
                }
                continue
            }
            let boundedValue = boundedText(text, fieldName: "customDefaults", presetName: presetName, findings: &findings)
            result[boundedKey] = boundedValue
        }
        return result
    }

    /// A tool's `zenit.assembly` default as it is stored, or `nil` when it is left out.
    ///
    /// Kept only when it is, whole, the shape an assignment has: a JSON object whose
    /// `assemblyID` is a UUID, whose `parameters` (when present) is an object of objects, and
    /// whose `definition` (an office recipe carried along, when present) is an object — within
    /// ``Limits/maximumAssemblyDefaultLength``. Whether the recipe exists is not this
    /// validator's question: an assignment naming a recipe the receiving copy lacks is kept, and
    /// the ledger derives nothing from it until the recipe is there, exactly as for a ledger row.
    private func boundedAssembly(
        _ text: String,
        presetName: String,
        findings: inout FindingCollector
    ) -> String? {
        func leaveOut(_ reason: String) -> String? {
            findings.add(
                .invalidAssembly,
                presetName: presetName,
                message: String(
                    format: NSLocalizedString(
                        "This tool's assembly %@, so the tool arrives without an assembly.",
                        comment: "Import finding: a tool's assembly was left out. %@ says why"
                    ),
                    reason
                )
            )
            return nil
        }
        let value = Self.cleanedText(text)
        guard value.count <= limits.maximumAssemblyDefaultLength else {
            return leaveOut(String(
                format: NSLocalizedString(
                    "is longer than %d characters",
                    comment: "Import finding reason: the assembly text is over the limit. %d is the limit"
                ),
                limits.maximumAssemblyDefaultLength
            ))
        }
        guard let root = try? ToolSetJSONValue.parse(Data(value.utf8)),
              let object = root.objectValue,
              let id = object["assemblyID"]?.stringValue, UUID(uuidString: id) != nil,
              object["parameters"].map({ parameters in
                  parameters.objectValue?.values.allSatisfy { $0.objectValue != nil } ?? false
              }) ?? true,
              object["definition"].map({ $0.objectValue != nil }) ?? true
        else {
            return leaveOut(NSLocalizedString(
                "is not an assembly Zenit PDF can read",
                comment: "Import finding reason: the assembly text is not an assignment"
            ))
        }
        reportSuspiciousText(value, fieldName: "customDefaults", presetName: presetName, findings: &findings)
        return value
    }

    private func sanitizedSymbolName(
        _ name: String?,
        presetName: String,
        findings: inout FindingCollector
    ) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.")
        let isPlain = name.unicodeScalars.allSatisfy(allowed.contains)
            && name.count <= 64
            && !name.hasPrefix(".")
            && !name.hasSuffix(".")
            && !name.contains("..")
        guard isPlain else {
            findings.add(
                .suspiciousSymbolName,
                presetName: presetName,
                message: NSLocalizedString(
                    "This tool asks for a symbol by a name that is not a plain symbol name. Zenit used a neutral circle instead, so nothing in the file decides what to load.",
                    comment: "Import finding: suspicious symbol name"
                )
            )
            return "circle"
        }
        return name
    }

    private func parseColor(
        _ text: String?,
        presetName: String,
        findings: inout FindingCollector
    ) -> ColorRGBA {
        let fallback = ColorRGBA.Zenit.Dark.cyan
        guard let text else { return fallback }
        guard let packed = Self.packedHexColour(text) else {
            findings.add(
                .invalidColor,
                presetName: presetName,
                message: NSLocalizedString(
                    "This tool's colour was not written as a six-digit hex value. Zenit used the default measurement colour instead.",
                    comment: "Import finding: invalid colour"
                )
            )
            return fallback
        }
        return ColorRGBA(hex: packed)
    }

    /// Reads a stamp template out of an untrusted file (BH-319).
    ///
    /// Only a `.stamp` preset keeps one — a Count preset's template exists only to carry a
    /// picture and is rebuilt when an accepted picture is attached. The box, rotation and every
    /// field are bounded one at a time; a field that is not something Zenit will store is left
    /// out and reported, and a template whose box is not a plausible size is left out whole.
    /// When the exporter's template had a picture and no acceptable picture travelled with it,
    /// the review says so instead of letting the tool arrive silently imageless.
    private func reviewStamp(
        _ value: ToolSetJSONValue?,
        identifier: UUID,
        markupKind: MarkupKind,
        image: ToolSetEmbeddedImageReview?,
        presetName: String,
        findings: inout FindingCollector
    ) -> StampTemplate? {
        guard let value, let members = value.objectValue else { return nil }
        reportUnknownFields(in: value, known: ToolSetStampRecord.knownFieldNames, presetName: presetName, findings: &findings)

        let declaredArtwork = members["artworkKind"]?.stringValue.flatMap(StampArtworkKind.init(rawValue:)) ?? .none
        if declaredArtwork != .none, image?.isAccepted != true {
            let source = members["artworkSourceName"]?.stringValue.map { sanitizedForDisplay($0) } ?? ""
            findings.add(
                .artworkNotIncluded,
                presetName: presetName,
                message: source.isEmpty
                    ? NSLocalizedString(
                        "This tool was exported with a picture that is not in this file. The tool arrives without it.",
                        comment: "Import finding: a stamp's picture did not travel with the file"
                    )
                    : String(
                        format: NSLocalizedString(
                            "This tool was exported with a picture (\"%@\") that is not in this file. The tool arrives without it.",
                            comment: "Import finding: a stamp's picture did not travel with the file. %@ is the picture's source file name"
                        ),
                        source
                    )
            )
        }
        guard markupKind == .stamp else { return nil }

        func invalid(_ key: String) {
            findings.add(
                .invalidStamp,
                presetName: presetName,
                message: String(
                    format: NSLocalizedString(
                        "The stamp's \"%@\" is not something Zenit will store, so it was left out.",
                        comment: "Import finding: part of a stamp template was out of range. %@ is the field name"
                    ),
                    sanitizedForDisplay(key)
                )
            )
        }
        let maximumSide = 14_400.0   // 200 inches, the largest page PDF allows
        guard let width = members["widthPoints"]?.doubleValue, width.isFinite, width >= 1, width <= maximumSide else {
            invalid("widthPoints"); return nil
        }
        guard let height = members["heightPoints"]?.doubleValue, height.isFinite, height >= 1, height <= maximumSide else {
            invalid("heightPoints"); return nil
        }
        var rotation = 0.0
        if let raw = members["rotationDegrees"] {
            if let degrees = raw.doubleValue, degrees.isFinite, abs(degrees) <= 360 {
                rotation = degrees
            } else {
                invalid("rotationDegrees")
            }
        }

        var fields: [StampFieldDefinition] = []
        let rawFields = members["fields"]?.arrayValue ?? []
        let maximumFields = 16
        if rawFields.count > maximumFields { invalid("fields") }
        for rawField in rawFields.prefix(maximumFields) {
            guard let field = rawField.objectValue else { invalid("fields"); continue }
            reportUnknownFields(in: rawField, known: ToolSetStampFieldRecord.knownFieldNames, presetName: presetName, findings: &findings)
            guard let kind = field["kind"]?.stringValue.flatMap(StampFieldKind.init(rawValue:)) else {
                invalid("kind"); continue
            }
            let slot = field["slot"]?.intValue ?? 0
            guard (0...63).contains(slot) else { invalid("slot"); continue }
            func fraction(_ key: String) -> Double? {
                guard let number = field[key]?.doubleValue, number.isFinite, number >= 0, number <= 1 else { return nil }
                return number
            }
            guard let x = fraction("frameX"), let y = fraction("frameY"),
                  let w = fraction("frameWidth"), let h = fraction("frameHeight"),
                  w > 0, h > 0, x + w <= 1.000_001, y + h <= 1.000_001 else {
                invalid("frame"); continue
            }
            guard let size = field["fontSizeFraction"]?.doubleValue, size.isFinite, size > 0, size <= 1 else {
                invalid("fontSizeFraction"); continue
            }
            let alignment = field["alignment"]?.stringValue.flatMap(StampFieldAlignment.init(rawValue:)) ?? .leading
            func text(_ key: String) -> String {
                boundedText(field[key]?.stringValue ?? "", fieldName: key, presetName: presetName, findings: &findings)
            }
            let fontName = text("fontName")
            fields.append(StampFieldDefinition(
                kind: kind,
                slot: slot,
                prompt: text("prompt"),
                dateFormat: text("dateFormat"),
                textPrefix: text("textPrefix"),
                normalizedFrame: PDFRectValue(x: x, y: y, width: w, height: h),
                fontName: fontName.isEmpty ? "Helvetica" : fontName,
                fontSizeFraction: size,
                alignment: alignment,
                colorRGBA: parseColor(field["color"]?.stringValue, presetName: presetName, findings: &findings)
            ))
        }
        return StampTemplate(
            id: identifier,
            widthPoints: width,
            heightPoints: height,
            rotationDegrees: rotation,
            artwork: nil,
            fields: fields
        )
    }

    private func reviewEmbeddedImage(
        _ value: ToolSetJSONValue?,
        presetName: String,
        index: Int,
        acceptedImageCount: inout Int,
        findings: inout FindingCollector
    ) -> ToolSetEmbeddedImageReview? {
        guard let value, value.objectValue != nil else { return nil }

        reportUnknownFields(
            in: value,
            known: ToolSetEmbeddedImageRecord.knownFieldNames,
            presetName: presetName,
            findings: &findings
        )

        let fileName = boundedText(
            value["fileName"]?.stringValue ?? NSLocalizedString("Symbol", comment: "Fallback name for an embedded image"),
            fieldName: "fileName",
            presetName: presetName,
            findings: &findings
        )
        let format = (value["format"]?.stringValue ?? "").lowercased()
        let pixelWidth = value["pixelWidth"]?.intValue ?? 0
        let pixelHeight = value["pixelHeight"]?.intValue ?? 0
        // A declared size that is present but not a whole number used to become 0 through
        // `?? 0` and pass every pixel check. Finding BH-854. The picture is left out and the
        // review says why.
        let sizeIsUnreadable = ["pixelWidth", "pixelHeight"].contains { key in
            guard let member = value[key] else { return false }
            return member.intValue == nil
        }
        let base64 = value["base64Data"]?.stringValue ?? ""
        let padding = base64.suffix(2).filter { $0 == "=" }.count
        let declaredBytes = max(0, base64.count / 4 * 3 - padding)

        var isAccepted = true

        if sizeIsUnreadable {
            isAccepted = false
            findings.add(
                .valueOutOfRange,
                presetName: presetName,
                message: NSLocalizedString(
                    "This tool carries a picture whose size in pixels is not a whole number. The tool was kept and the picture was left out.",
                    comment: "Import finding: embedded image pixel size is not a whole number"
                )
            )
        }

        if !ToolSetEmbeddedImageRecord.acceptedFormats.contains(format) {
            isAccepted = false
            findings.add(
                .unsupportedImageFormat,
                presetName: presetName,
                message: String(
                    format: NSLocalizedString(
                        "This tool carries a picture in a format Zenit does not read (\"%@\"). The tool was kept and the picture was left out.",
                        comment: "Import finding: unsupported image format. %@ is the declared format"
                    ),
                    sanitizedForDisplay(format.isEmpty ? "unknown" : format)
                )
            )
        }
        if declaredBytes > limits.maximumEmbeddedImageByteCount {
            isAccepted = false
            findings.add(
                .embeddedImageTooLarge,
                presetName: presetName,
                message: String(
                    format: NSLocalizedString(
                        "This tool carries a picture of about %1$@, and the limit for a tool symbol is %2$@. The tool was kept and the picture was left out.",
                        comment: "Import finding: embedded image too large. %1$@ is the size, %2$@ the limit"
                    ),
                    ByteCountFormatter.string(fromByteCount: Int64(declaredBytes), countStyle: .file),
                    ByteCountFormatter.string(fromByteCount: Int64(limits.maximumEmbeddedImageByteCount), countStyle: .file)
                )
            )
        }
        if pixelWidth > limits.maximumImagePixelSide || pixelHeight > limits.maximumImagePixelSide {
            isAccepted = false
            findings.add(
                .embeddedImageTooManyPixels,
                presetName: presetName,
                message: String(
                    format: NSLocalizedString(
                        "This tool carries a picture of %1$ld × %2$ld pixels, and a tool symbol may be at most %3$ld on a side. The tool was kept and the picture was left out.",
                        comment: "Import finding: embedded image too many pixels"
                    ),
                    pixelWidth,
                    pixelHeight,
                    limits.maximumImagePixelSide
                )
            )
        }
        if isAccepted && acceptedImageCount >= limits.maximumEmbeddedImageCount {
            isAccepted = false
            findings.add(
                .tooManyEmbeddedImages,
                presetName: presetName,
                message: WorkflowPlurals.tooManyPictures(limits.maximumEmbeddedImageCount)
            )
        }
        if isAccepted {
            acceptedImageCount += 1
        }

        return ToolSetEmbeddedImageReview(
            id: "image#\(index)",
            presetName: presetName,
            fileName: fileName,
            declaredFormat: format.isEmpty ? "unknown" : format,
            declaredByteCount: declaredBytes,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            isAccepted: isAccepted,
            base64Data: isAccepted ? base64 : ""
        )
    }

    // MARK: - Text inspection

    /// Whether a value is written the way code is written. Zenit does not run it either way;
    /// this only decides whether the person is told about it.
    public static func looksLikeMarkupOrScript(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = ["<script", "</script", "javascript:", "vbscript:", "data:text/html", "<?", "#!/", "<iframe", "onerror=", "onload="]
        return markers.contains { lowered.contains($0) }
    }

    /// Whether a value points outside the file. Zenit never follows it.
    public static func looksLikeExternalReference(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.hasPrefix("/") || lowered.hasPrefix("~/") || lowered.hasPrefix("\\\\") { return true }
        let schemes = ["http://", "https://", "ftp://", "file://", "smb://", "afp://"]
        return schemes.contains { lowered.contains($0) }
    }

    private func looksLikeMarkupOrScript(_ text: String) -> Bool {
        ToolSetImportValidator.looksLikeMarkupOrScript(text)
    }

    private func looksLikeExternalReference(_ text: String) -> Bool {
        ToolSetImportValidator.looksLikeExternalReference(text)
    }

    /// Renders an untrusted value for inclusion in a message: shortened, single line, quoted by
    /// the caller. It is never interpreted.
    private func sanitizedForDisplay(_ text: String) -> String {
        let flattened = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.count > 40 ? String(flattened.prefix(40)) + "…" : flattened
    }
}

// MARK: - Finding collection

/// Accumulates findings with deterministic identities, so the same file always reviews the same.
private struct FindingCollector {

    private var findings: [ToolSetImportFinding] = []
    private var counts: [ToolSetImportFindingCode: Int] = [:]

    mutating func add(
        _ code: ToolSetImportFindingCode,
        presetName: String? = nil,
        message: String
    ) {
        let index = counts[code, default: 0]
        counts[code] = index + 1
        findings.append(ToolSetImportFinding(
            id: "\(code.rawValue)#\(index)",
            code: code,
            presetName: presetName,
            message: message
        ))
    }

    func sorted() -> [ToolSetImportFinding] {
        findings.sorted { lhs, rhs in
            lhs.severity == rhs.severity ? lhs.id < rhs.id : lhs.severity > rhs.severity
        }
    }
}
