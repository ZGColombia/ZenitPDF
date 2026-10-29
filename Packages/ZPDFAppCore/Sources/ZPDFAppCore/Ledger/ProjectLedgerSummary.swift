import Foundation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

extension TakeoffSession {

    /// This drawing's primary-quantity totals by subject and unit (NL-QTY-15).
    ///
    /// A subject whose rows share one unit is read from the core's own grouped projection, the
    /// heading the ledger shows. A subject whose `Value` heading has no total — rows in two
    /// units ("Mixed units"), or a Slope or Rise/Drop row among them — used to vanish from the
    /// whole-project and closed-project summaries without a word (S-026). Such a subject is
    /// folded per unit through the ledger's own ``LedgerBridge/PrimaryQuantityReader``, adding
    /// only the contributions the ledger itself would add, in exact `Decimal`: one line per unit.
    public func subjectTotals() throws -> [LedgerSubjectTotal] {
        let projection = try ledgerProjection(LedgerRequest(grouping: [LedgerColumnID(StandardLedgerColumn.subject.rawValue)]))
        let valueID = LedgerDefaultColumns.valueColumnID
        let reader = LedgerBridge.PrimaryQuantityReader(view: projection.view, formatter: projection.formatter)
        var totals: [LedgerSubjectTotal] = []
        for (node, group) in zip(projection.view.tree.roots, projection.rootGroups) {
            if let quantity = group.totals.quantities[valueID] {
                totals.append(LedgerSubjectTotal(
                    subject: group.title, quantity: quantity, rowCount: group.totals.rowCount,
                    text: group.totals.displayValues[valueID] ?? ""
                ))
            } else {
                totals += Self.perUnitTotals(subject: group.title, node: node, reader: reader, formatter: projection.formatter)
            }
        }
        return totals
    }

    /// One subject's additive `Value` contributions, one exact total per unit, smallest power
    /// of length first. A unit whose sum overflows `Decimal` is refused, as the ledger refuses it.
    static func perUnitTotals(
        subject: String,
        node: ZPDFQuantityLedger.LedgerGroupNode,
        reader: LedgerBridge.PrimaryQuantityReader,
        formatter: QuantityFormatter
    ) -> [LedgerSubjectTotal] {
        var sums: [Shown.Dimension: (value: Decimal, rows: Int, failed: Bool)] = [:]
        func visit(_ node: ZPDFQuantityLedger.LedgerGroupNode) {
            guard node.isLeaf else { node.children.forEach(visit); return }
            for index in node.rowIndices {
                guard let contribution = reader.contribution(atStoreIndex: index), contribution.isAdditive else { continue }
                let quantity = contribution.quantity
                guard !quantity.dimension.ratio, !quantity.dimension.angle else { continue }
                var entry = sums[quantity.dimension] ?? (0, 0, false)
                var left = entry.value
                var right = quantity.value
                var sum = Decimal()
                if NSDecimalAdd(&sum, &left, &right, .plain) == .noError { entry.value = sum } else { entry.failed = true }
                entry.rows += 1
                sums[quantity.dimension] = entry
            }
        }
        visit(node)
        return sums.filter { !$0.value.failed }
            .sorted {
                $0.key.lengthPower == $1.key.lengthPower
                    ? String(describing: $0.key) < String(describing: $1.key)
                    : $0.key.lengthPower < $1.key.lengthPower
            }
            .map { dimension, entry in
                let quantity = Shown.Quantity(value: entry.value, dimension: dimension)
                return LedgerSubjectTotal(subject: subject, quantity: quantity, rowCount: entry.rows, text: formatter.text(quantity))
            }
    }
}

/// Combines drawings' subject totals exactly (QUALITY_BAR A36): the same subject in the same
/// unit adds, in `Decimal`; the same subject in two units stays two lines — it is never
/// converted by guess or dropped.
enum ProjectLedgerCombiner {

    static func combine(_ drawings: [LedgerProjectSummary.Drawing], formatter: QuantityFormatter) -> [LedgerSubjectTotal] {
        struct Key: Hashable { let subject: String; let dimension: ZPDFUIPresentation.QuantityDimension }
        var sums: [Key: (value: Decimal, rows: Int)] = [:]
        var order: [Key] = []
        for drawing in drawings {
            for total in drawing.totals {
                let key = Key(subject: total.subject, dimension: total.quantity.dimension)
                if sums[key] == nil { order.append(key) }
                sums[key, default: (0, 0)].value += total.quantity.value
                sums[key, default: (0, 0)].rows += total.rowCount
            }
        }
        return order.sorted {
            $0.subject == $1.subject ? $0.dimension.lengthPower < $1.dimension.lengthPower : $0.subject < $1.subject
        }.map { key in
            let quantity = ZPDFUIPresentation.DecimalQuantity(value: sums[key]!.value, dimension: key.dimension)
            return LedgerSubjectTotal(
                subject: key.subject, quantity: quantity, rowCount: sums[key]!.rows, text: formatter.text(quantity)
            )
        }
    }
}

extension AppLedgerPresenter: LedgerProjectSummarizing {

    public var hasProjectSources: Bool { !projectSources.isEmpty }

    public func projectSummary() async -> LedgerProjectSummary {
        var drawings: [LedgerProjectSummary.Drawing] = []
        if let own = ownProjectPart { drawings.append(await own()) }
        for source in projectSources {
            drawings.append(.init(documentID: source.documentID, title: source.title, totals: await source.totals()))
        }
        return LedgerProjectSummary(drawings: drawings, combined: ProjectLedgerCombiner.combine(drawings, formatter: projectionFormatter))
    }
}

extension AppCoreEnvironment {

    /// This drawing's part of a whole-project summary.
    public func projectSummaryPart(documentID: UUID, title: String) async -> LedgerProjectSummary.Drawing {
        let totals = (try? await session.subjectTotals()) ?? []
        return .init(documentID: documentID, title: title, totals: totals)
    }

    /// This drawing as a source for the other drawings' whole-project summary.
    public func projectLedgerSource(documentID: UUID, title: String) -> ProjectLedgerSource {
        let session = self.session
        return ProjectLedgerSource(documentID: documentID, title: title, totals: {
            (try? await session.subjectTotals()) ?? []
        })
    }

    /// Installs the other open drawings, and names this one, for the whole-project summary.
    public func installProjectLedgerSources(_ sources: [ProjectLedgerSource], ownDocumentID: UUID, ownTitle: String) {
        ledger.projectSources = sources
        ledger.ownProjectPart = { [weak self] in
            await self?.projectSummaryPart(documentID: ownDocumentID, title: ownTitle)
                ?? .init(documentID: ownDocumentID, title: ownTitle, totals: [])
        }
    }
}
