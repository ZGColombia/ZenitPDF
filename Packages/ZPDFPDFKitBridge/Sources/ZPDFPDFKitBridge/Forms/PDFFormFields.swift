import CoreGraphics
import Foundation
import PDFKit

/// The fillable fields of a PDF form, read and filled into a copy (NL-PDF-17).
///
/// RFI, transmittal and daily-report templates arrive as PDF forms. This reads their fields —
/// text, check boxes, radio groups, lists and combo boxes — with PDFKit, and writes the values a
/// person entered into a **new file**, where PDFKit generates each filled widget's appearance.
/// The drawing a takeoff was measured on is never written. Field values are never part of the
/// Quantity Ledger.
///
/// XFA forms are refused: an XFA form is a second document format carried inside the PDF, and
/// filling its AcroForm shadow would give a file whose two halves disagree.
public enum PDFFormFields {

    /// One field, as a person fills it.
    public struct Field: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            case text(multiline: Bool)
            case checkBox
            /// The group's options (each widget's on-state name), in page order.
            case radio(options: [String])
            case choice(options: [String], editable: Bool)
        }
        /// The fully qualified field name, the key a value is written under.
        public let name: String
        public let kind: Kind
        /// The current value: text or chosen option; "Yes"/"Off" style for a check box is
        /// reported through ``isOn``.
        public let value: String?
        public let isOn: Bool
        public let isReadOnly: Bool
        /// The first widget's page and box, for ordering and for pointing at it.
        public let pageIndex: Int
        public let bounds: CGRect
        public var id: String { name }
    }

    /// A value to write.
    public enum Value: Sendable, Hashable {
        case text(String)
        case checked(Bool)
        /// A radio group's or a list's chosen option.
        case option(String)
    }

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case unreadable
        case locked
        case xfa
        case noFields
        case writeFailed
        /// The chosen file is the drawing the copy is made from (R-103).
        case destinationIsSource

        public var description: String {
            switch self {
            case .unreadable: "the file could not be read as a PDF"
            case .locked: "the file is locked and the password did not open it"
            case .xfa: "this is an XFA form — a second document format inside the PDF that only a program made for XFA fills correctly"
            case .noFields: "the file has no form fields to fill"
            case .writeFailed: "the filled copy could not be written"
            case .destinationIsSource: "the filled copy cannot replace the drawing it is made from; choose another name or folder"
            }
        }
    }

    /// Whether the catalog's `/AcroForm` carries `/XFA`.
    public static func isXFA(_ document: PDFDocument) -> Bool {
        guard let catalog = document.documentRef?.catalog else { return false }
        var form: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form else { return false }
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(form, "XFA", &object)
    }

    static func open(_ url: URL, password: String?) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw Refusal.unreadable }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password), !document.isLocked else { throw Refusal.locked }
        }
        guard !isXFA(document) else { throw Refusal.xfa }
        return document
    }

    /// The fields of the file at `url`, in page order.
    public static func fields(ofFileAt url: URL, password: String? = nil) throws -> [Field] {
        let document = try open(url, password: password)
        var order: [String] = []
        var widgets: [String: [(page: Int, annotation: PDFAnnotation)]] = [:]
        for index in 0..<min(document.pageCount, 5_000) {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                guard let name = annotation.fieldName, !name.isEmpty,
                      annotation.widgetFieldType != .signature else { continue }
                if widgets[name] == nil { order.append(name) }
                widgets[name, default: []].append((index, annotation))
                guard order.count < 5_000 else { break }
            }
        }
        return order.compactMap { name -> Field? in
            guard let group = widgets[name], let first = group.first else { return nil }
            let widget = first.annotation
            let kind: Field.Kind
            var value = widget.widgetStringValue
            var isOn = false
            switch widget.widgetFieldType {
            case .text:
                kind = .text(multiline: widget.isMultiline)
            case .button:
                switch widget.widgetControlType {
                case .radioButtonControl:
                    let options = group.compactMap { $0.annotation.buttonWidgetStateString.isEmpty ? nil : $0.annotation.buttonWidgetStateString }
                    kind = .radio(options: options)
                    value = group.first { $0.annotation.buttonWidgetState == .onState }?.annotation.buttonWidgetStateString
                    isOn = value != nil
                case .checkBoxControl:
                    kind = .checkBox
                    isOn = widget.buttonWidgetState == .onState
                default:
                    return nil // a push button carries no value
                }
            case .choice:
                kind = .choice(options: widget.choices ?? [], editable: !widget.isListChoice)
            default:
                return nil
            }
            return Field(name: name, kind: kind, value: value, isOn: isOn, isReadOnly: widget.isReadOnly,
                         pageIndex: first.page, bounds: widget.bounds)
        }
    }

    /// Writes `values` into a copy of `source` at `destination`. Fields not named keep their
    /// values; read-only fields are never changed. Returns how many fields were changed.
    @discardableResult
    public static func fill(source: URL, password: String? = nil, values: [String: Value], to destination: URL) throws -> Int {
        let document = try open(source, password: password)
        var changed = Set<String>()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for widget in page.annotations where widget.type == "Widget" {
                guard let name = widget.fieldName, let value = values[name], !widget.isReadOnly else { continue }
                switch (widget.widgetFieldType, value) {
                case let (.text, .text(text)):
                    widget.widgetStringValue = text
                    changed.insert(name)
                case let (.choice, .option(option)), let (.choice, .text(option)):
                    widget.widgetStringValue = option
                    changed.insert(name)
                case let (.button, .checked(on)) where widget.widgetControlType == .checkBoxControl:
                    widget.buttonWidgetState = on ? .onState : .offState
                    changed.insert(name)
                case let (.button, .option(option)) where widget.widgetControlType == .radioButtonControl:
                    widget.buttonWidgetState = widget.buttonWidgetStateString == option ? .onState : .offState
                    changed.insert(name)
                default:
                    continue
                }
            }
        }
        try StagedFileReplacement.write(
            to: destination, protecting: [source], refusal: Refusal.destinationIsSource, stagingPrefix: ".zpdf-form-"
        ) { staging in
            guard document.write(to: staging) else { throw Refusal.writeFailed }
        }
        return changed.count
    }
}

extension PDFFormFields.Refusal: LocalizedError {
    public var errorDescription: String? { description }
}
