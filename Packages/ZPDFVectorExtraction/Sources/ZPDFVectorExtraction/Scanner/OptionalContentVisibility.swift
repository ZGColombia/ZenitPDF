import CoreGraphics
import Foundation

/// The visibility rule for optional-content membership dictionaries
/// (PDF 32000-1 8.11.2.2), kept apart from the `CGPDF` reading so the rule can be tested
/// on values and the reading stays a thin transcription.
///
/// A membership dictionary (`/Type /OCMD`) is visible or not as a function of the groups it
/// names. When it carries a `/VE` visibility expression that expression decides; otherwise
/// the groups in `/OCGs` combine under the `/P` policy, `/AnyOn` by default. The previous
/// reading honoured `/AnyOn` only, so a membership that a producer had written as
/// `/P /AllOn` with one group off — the common "show only when both layers are on" — was
/// extracted as visible and became a snap target while the drawing did not show it (CR-48).
enum OptionalContentVisibility {

    /// `/P`: how the groups in `/OCGs` combine.
    enum Policy: String, Sendable, Hashable {
        /// Visible when any group is on. The default.
        case anyOn = "AnyOn"
        /// Visible only when every group is on.
        case allOn = "AllOn"
        /// Visible when any group is off.
        case anyOff = "AnyOff"
        /// Visible only when every group is off.
        case allOff = "AllOff"
    }

    /// A `/VE` visibility expression: groups combined by `/And`, `/Or` and `/Not`.
    indirect enum Expression: Sendable, Hashable {
        case group(isHidden: Bool)
        case and([Expression])
        case or([Expression])
        case not(Expression)
    }

    /// What one membership dictionary says about itself, read once.
    struct Membership: Sendable, Hashable {
        /// The `/VE` expression when the dictionary has a well-formed one. It takes
        /// precedence over ``groupsHidden`` and ``policy``.
        var expression: Expression?
        /// One flag per group in `/OCGs`, in array order: `true` when that group is off.
        var groupsHidden: [Bool]
        var policy: Policy

        init(expression: Expression? = nil, groupsHidden: [Bool], policy: Policy = .anyOn) {
            self.expression = expression
            self.groupsHidden = groupsHidden
            self.policy = policy
        }
    }

    /// Terms read from one `/OCGs` array or one `/VE` level. A file may claim any length.
    static let maximumTerms = 4096
    /// Nesting of `/VE` arrays. A file may nest as deep as it likes; the rule does not.
    static let maximumExpressionDepth = 32

    // MARK: - The rule

    static func isHidden(_ membership: Membership) -> Bool {
        if let expression = membership.expression {
            return !isVisible(expression)
        }
        return !isVisible(groupsHidden: membership.groupsHidden, policy: membership.policy)
    }

    /// The `/OCGs` + `/P` half of the rule.
    ///
    /// A membership naming no group is visible: 8.11.2.2 says an absent or empty `/OCGs`
    /// makes the dictionary visible regardless of `/P`.
    static func isVisible(groupsHidden: [Bool], policy: Policy) -> Bool {
        guard !groupsHidden.isEmpty else { return true }
        switch policy {
        case .anyOn: return groupsHidden.contains(false)
        case .allOn: return !groupsHidden.contains(true)
        case .anyOff: return groupsHidden.contains(true)
        case .allOff: return !groupsHidden.contains(false)
        }
    }

    /// The `/VE` half of the rule. An empty `/And` is true and an empty `/Or` is false,
    /// the usual identities.
    static func isVisible(_ expression: Expression) -> Bool {
        switch expression {
        case .group(let isHidden): return !isHidden
        case .and(let terms): return terms.allSatisfy(isVisible)
        case .or(let terms): return terms.contains(where: isVisible)
        case .not(let term): return !isVisible(term)
        }
    }

    // MARK: - Reading the dictionary

    /// Transcribes an `/OCMD` into a ``Membership``.
    ///
    /// - Parameter isGroupHidden: whether the group with a given dictionary identity is off
    ///   in the document's default configuration.
    ///
    /// A `/VE` that is malformed — an unknown operator, a term that is neither a group nor
    /// an array, a `/Not` with other than one operand, nesting past the cap — is dropped and
    /// the `/OCGs` + `/P` reading is used instead, which is what a viewer that does not
    /// implement `/VE` shows.
    static func membership(
        of dictionary: CGPDFDictionaryRef,
        isGroupHidden: (UInt) -> Bool
    ) -> Membership {
        var groups: [Bool] = []
        if let single = PDFObject.dictionaryEntry(dictionary, "OCGs") {
            groups = [isGroupHidden(PDFObject.identity(dictionary: single))]
        } else if let array = PDFObject.arrayEntry(dictionary, "OCGs") {
            let count = CGPDFArrayGetCount(array)
            for index in 0..<Swift.min(count, maximumTerms) {
                var member: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(array, index, &member), let member else { continue }
                groups.append(isGroupHidden(PDFObject.identity(dictionary: member)))
            }
        }

        let policy = PDFObject.nameEntry(dictionary, "P").flatMap(Policy.init(rawValue:)) ?? .anyOn

        var expression: Expression?
        if let array = PDFObject.arrayEntry(dictionary, "VE") {
            expression = parseExpression(array, depth: 0, isGroupHidden: isGroupHidden)
        }
        return Membership(expression: expression, groupsHidden: groups, policy: policy)
    }

    private static func parseExpression(
        _ array: CGPDFArrayRef,
        depth: Int,
        isGroupHidden: (UInt) -> Bool
    ) -> Expression? {
        guard depth < maximumExpressionDepth else { return nil }
        let count = CGPDFArrayGetCount(array)
        guard count >= 1 else { return nil }

        var operatorPointer: UnsafePointer<Int8>?
        guard CGPDFArrayGetName(array, 0, &operatorPointer),
              let operatorName = PDFObject.name(operatorPointer)
        else { return nil }

        var terms: [Expression] = []
        for index in 1..<Swift.max(1, Swift.min(count, maximumTerms)) {
            var member: CGPDFDictionaryRef?
            var nested: CGPDFArrayRef?
            if CGPDFArrayGetDictionary(array, index, &member), let member {
                terms.append(.group(isHidden: isGroupHidden(PDFObject.identity(dictionary: member))))
            } else if CGPDFArrayGetArray(array, index, &nested), let nested {
                guard let term = parseExpression(nested, depth: depth + 1, isGroupHidden: isGroupHidden)
                else { return nil }
                terms.append(term)
            } else {
                return nil
            }
        }

        switch operatorName {
        case "And": return .and(terms)
        case "Or": return .or(terms)
        case "Not":
            guard terms.count == 1 else { return nil }
            return .not(terms[0])
        default: return nil
        }
    }
}
