import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What one piece of title-block text is (NL-AUTO-22).
public enum TitleBlockField: String, Sendable, Hashable, CaseIterable {
    case sheetNumber
    case sheetTitle
    case scale
    case date
    case revision
    case other
}

/// Labels title-block text by field. **Classification only**: the answer is one of
/// ``TitleBlockField``'s cases and never a number — a sheet's scale is always read by the scale
/// parser from the text itself, never produced by a model.
public protocol TitleBlockFieldClassifying: Sendable {
    /// One label per text, in order.
    func classify(_ texts: [String]) async -> [TitleBlockField]
    /// Whether an on-device language model produced the labels, so the interface can say which
    /// method it used.
    var isModelBacked: Bool { get }
}

/// The rules every Mac runs, and the fallback whenever the model is absent: macOS 14 and 15,
/// a Mac without the on-device model, the model switched off, or a language it does not support.
public struct RuleBasedTitleBlockClassifier: TitleBlockFieldClassifying {

    public init() {}

    public var isModelBacked: Bool { false }

    public func classify(_ texts: [String]) async -> [TitleBlockField] {
        texts.map(Self.label)
    }

    /// One text's label by pattern.
    public static func label(_ text: String) -> TitleBlockField {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .other }
        func matches(_ pattern: String) -> Bool {
            trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if !ScaleNotationParser().candidates(inLine: trimmed).isEmpty { return .scale }
        if matches(#"^\d{4}-\d{2}-\d{2}$"#) || matches(#"^\d{1,2}[./]\d{1,2}[./]\d{2,4}$"#) { return .date }
        if matches(#"^(rev(ision)?|ändring|ä)\.?\s*[A-Z0-9]{1,3}$"#) { return .revision }
        if matches(#"^[A-Z]{1,3}[-\u{2011} ]?\d{1,4}(\.\d{1,3})?[A-Z]?$"#) { return .sheetNumber }
        if trimmed.count >= 3, trimmed.rangeOfCharacter(from: .letters) != nil { return .sheetTitle }
        return .other
    }
}

/// Picks the classifier this Mac can run, and says which.
public enum OnDeviceLanguage {

    /// Why the model is or is not in use, for the status line and for tests.
    public enum Availability: Sendable, Hashable {
        /// The on-device model will classify.
        case available
        /// The framework is not in this build or this macOS predates it.
        case frameworkMissing
        /// The model reported itself unavailable (not enabled, not downloaded, unsupported Mac).
        case modelUnavailable(String)
    }

    /// The current availability. Never touches the network: the system model runs on the Mac.
    public static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .modelUnavailable(String(describing: reason))
            }
        }
        #endif
        return .frameworkMissing
    }

    /// The classifier to use: the on-device model when available, the rules otherwise.
    /// `preferModel: false` forces the rules — what tests and a person who switched the model
    /// off get.
    public static func titleBlockClassifier(preferModel: Bool = true) -> any TitleBlockFieldClassifying {
        #if canImport(FoundationModels)
        if preferModel, #available(macOS 26.0, iOS 26.0, *), case .available = availability {
            return ModelTitleBlockClassifier()
        }
        #endif
        return RuleBasedTitleBlockClassifier()
    }
}

#if canImport(FoundationModels)
/// The on-device model, constrained by a generation schema to answer with one field name per
/// text. Only `SystemLanguageModel` — the model on this Mac — is ever used; nothing here names
/// a server-side model, and no drawing text leaves the machine.
@available(macOS 26.0, iOS 26.0, *)
struct ModelTitleBlockClassifier: TitleBlockFieldClassifying {

    var isModelBacked: Bool { true }

    func classify(_ texts: [String]) async -> [TitleBlockField] {
        let fallback = RuleBasedTitleBlockClassifier()
        guard let schema = try? GenerationSchema(
            root: DynamicGenerationSchema(
                name: "TitleBlockField",
                description: "Which title-block field a piece of text is",
                anyOf: TitleBlockField.allCases.map(\.rawValue)
            ),
            dependencies: []
        ) else { return await fallback.classify(texts) }
        var labels: [TitleBlockField] = []
        for text in texts {
            let session = LanguageModelSession(
                model: .default,
                instructions: "You label text from the title block of a construction drawing. Answer with exactly one field name."
            )
            do {
                let response = try await session.respond(to: "Text: \(text)", schema: schema)
                let name = try response.content.value(String.self)
                labels.append(TitleBlockField(rawValue: name) ?? RuleBasedTitleBlockClassifier.label(text))
            } catch {
                // Anything the model cannot answer falls back to the rules, text by text.
                labels.append(RuleBasedTitleBlockClassifier.label(text))
            }
        }
        return labels
    }
}
#endif
