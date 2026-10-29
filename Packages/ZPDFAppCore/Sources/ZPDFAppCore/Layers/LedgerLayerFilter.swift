import Foundation
import ZPDFUIPresentation

/// The Quantity Ledger's filter by markup layer (ADR-0032): one top-level rule, *Layer is any of
/// …*, on the ledger's Layer column, installed beside whatever else the person filters by.
///
/// This is the only way a layer narrows the ledger. Hiding, locking or keeping a layer off paper
/// never removes a row or changes a total; a person who wants the totals of one layer says so
/// here, and the pane shows the filter as it shows every other one ("n of m rows").
public enum LedgerLayerFilter {

    /// The filter group with the layer rule replaced: `layers` names the layers to keep (by the
    /// names the Layer column shows), `nil` removes the rule. Every other rule and group is kept
    /// as it was, in its place.
    public static func applying(layers: [String]?, to group: LedgerFilterGroup) -> LedgerFilterGroup {
        var updated = group
        let existing = updated.rules.firstIndex(where: isLayerRule)
        guard let layers else {
            if let existing { updated.rules.remove(at: existing) }
            return updated
        }
        let rule = LedgerFilterRule(
            id: existing.map { updated.rules[$0].id } ?? UUID(),
            column: .layer,
            comparison: .isAnyOf,
            operand: .choices(layers)
        )
        if let existing {
            updated.rules[existing] = rule
        } else {
            updated.rules.append(rule)
        }
        // The layer rule narrows alongside the others; under "match any" it would widen instead.
        if updated.rules.count > 1 || !updated.groups.isEmpty, updated.conjunction == .any, existing == nil {
            return LedgerFilterGroup(id: UUID(), conjunction: .all, rules: [rule], groups: [group])
        }
        return updated
    }

    /// The layers the filter keeps, or `nil` when it has no layer rule.
    public static func layers(in group: LedgerFilterGroup) -> [String]? {
        // Also the wrapped form `applying` builds over a group that matched "any": the rule is
        // still at the top level.
        guard let rule = group.rules.first(where: isLayerRule), case .choices(let names) = rule.operand else {
            return nil
        }
        return names
    }

    /// Whether a rule is the layer filter's.
    static func isLayerRule(_ rule: LedgerFilterRule) -> Bool {
        rule.column == .layer && rule.comparison == .isAnyOf && rule.isEnabled
    }
}
