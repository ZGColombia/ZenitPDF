import Foundation
import ZPDFContracts

/// Where the text a Text or Callout **draws** lives, separate from its review note
/// (NL-COLLAB-18).
///
/// Until 2026-09-23 the typed string of a text box was stored in `comment` — the same field the
/// Inspector edits as Notes and the Comments tab lists. A reviewer's note on a text box therefore
/// rewrote the words drawn on the sheet, and every text box showed up as a "comment".
///
/// The drawn text now lives in `MarkupRecord.caption`, the contract's existing "text drawn with
/// the markup" field, which the archive already round-trips (`markup_extra.caption`), and
/// `comment` goes back to meaning the note. No frozen contract field and no schema column is
/// added.
///
/// ### Migration
///
/// A Text or Callout written by an earlier build has `caption == nil` and its words in
/// `comment`. ``migratingLegacy(_:)`` moves them across once, on hydration: the words become the
/// caption and the note starts empty. The next save writes the migrated record, and a record that
/// has a caption — even an empty one — is never touched again, so a note added later can never be
/// mistaken for drawn text.
public enum MarkupVisibleText {

    /// Whether a markup kind draws text of its own.
    public static func carriesVisibleText(_ kind: MarkupKind) -> Bool {
        kind == .text || kind == .callout
    }

    /// Whether this record draws text of its own: a Text, a Callout, or a clouded callout — a
    /// cloud that carries callout points (ADR-0029 §2.4). A plain cloud draws none, and its
    /// comment is never migrated into drawn text.
    public static func carriesVisibleText(_ record: MarkupRecord) -> Bool {
        carriesVisibleText(record.kind) || isCloudedCallout(record)
    }

    /// Whether a record is a clouded callout (ADR-0029 §2.4).
    public static func isCloudedCallout(_ record: MarkupRecord) -> Bool {
        record.kind == .cloud && (record.geometry?.points.count ?? 0) >= 3
    }

    /// The text a record draws: the caption, or for a record not yet migrated its comment.
    /// Empty for kinds that draw no text.
    public static func text(of record: MarkupRecord) -> String {
        if isCloudedCallout(record) { return record.caption ?? "" }
        guard carriesVisibleText(record.kind) else { return "" }
        return record.caption ?? record.comment
    }

    /// The text a record draws, or `nil` when there is none — what the canvas asks.
    public static func drawnText(of record: MarkupRecord) -> String? {
        let text = text(of: record)
        return text.isEmpty ? nil : text
    }

    /// The record with a legacy text box's words moved from `comment` into `caption`.
    /// Every other record comes back unchanged.
    public static func migratingLegacy(_ record: MarkupRecord) -> MarkupRecord {
        guard carriesVisibleText(record.kind), record.caption == nil else { return record }
        var migrated = record
        migrated.caption = record.comment
        migrated.comment = ""
        return migrated
    }
}
