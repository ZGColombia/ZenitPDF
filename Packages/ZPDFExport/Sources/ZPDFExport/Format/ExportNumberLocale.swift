import Foundation
import ZPDFQuantityLedger

/// How a rounded `Decimal` becomes digits on a page — see ``ZPDFQuantityLedger/LedgerNumberLocale``.
///
/// The type moved into ZPDFQuantityLedger (IM-012) so the screen, the aggregation layer and every
/// exporter can share one hermetic formatter; this alias keeps every existing export call site,
/// preset (`.invariant`, `.enUS`, `.svSE`, `.arEG`) and test source-compatible.
public typealias ExportNumberLocale = LedgerNumberLocale
