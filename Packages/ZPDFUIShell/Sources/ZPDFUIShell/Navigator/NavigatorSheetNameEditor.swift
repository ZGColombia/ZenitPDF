import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The page card's inline sheet-name editor (NL-DOCS-05): a number field and a title field under
/// the card, committed with Return or Name, abandoned with Escape or Cancel. Inline rather than a
/// sheet, so naming thirty sheets is thirty short edits in the column, and no modal is involved.
struct NavigatorSheetNameEditor: View {

    let page: PageDescriptor
    let onCommit: (_ number: String?, _ title: String?) -> Void
    let onCancel: () -> Void

    @State private var number: String
    @State private var title: String
    @FocusState private var focused: Field?

    enum Field { case number, title }

    init(page: PageDescriptor, onCommit: @escaping (String?, String?) -> Void, onCancel: @escaping () -> Void) {
        self.page = page
        self.onCommit = onCommit
        self.onCancel = onCancel
        let seed = Self.seed(for: page)
        _number = State(initialValue: seed.number)
        _title = State(initialValue: seed.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            HStack(spacing: ZPDFSpacing.xs) {
                TextField(Self.numberPlaceholder, text: $number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .focused($focused, equals: .number)
                    .accessibilityLabel(Text(Self.numberPlaceholder))
                TextField(Self.titlePlaceholder, text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .title)
                    .accessibilityLabel(Text(Self.titlePlaceholder))
            }
            .onSubmit(commit)
            HStack(spacing: ZPDFSpacing.s) {
                Spacer(minLength: 0)
                Button(NSLocalizedString("Cancel", comment: "Sheet name editor: abandon the edit"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("Save Name", comment: "Sheet name editor: save the sheet number and title"), action: commit)
                    .keyboardShortcut(.defaultAction)
            }
            .zpdfFont(.control)
        }
        .padding(ZPDFSpacing.s)
        .onAppear { focused = .number }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Self.menuTitle))
    }

    private func commit() {
        let parts = Self.committed(number: number, title: title)
        onCommit(parts.number, parts.title)
    }

    /// What the fields start with: the sheet's own number and title when it has been named, else
    /// the PDF's label when it is a name, and an empty title.
    static func seed(for page: PageDescriptor) -> (number: String, title: String) {
        if let identity = splitSheetIdentity(page) { return identity }
        let label = page.label.trimmingCharacters(in: .whitespaces)
        return (label.allSatisfy(\.isNumber) ? "" : label, "")
    }

    /// A named sheet's number and title as two parts — the title without a leading
    /// "number · ", and empty when it only repeats the number — or `nil` for a sheet the set has
    /// not named. The one rule the editor's prefill and the sheet index's row share (R-091).
    static func splitSheetIdentity(_ page: PageDescriptor) -> (number: String, title: String)? {
        guard page.hasSheetIdentity else { return nil }
        let number = page.sheetNumber ?? ""
        var title = page.sheetTitle ?? ""
        if !number.isEmpty, title.hasPrefix(number + " · ") {
            title.removeFirst(number.count + 3)
        } else if title == number {
            title = ""
        }
        return (number, title)
    }

    /// Trimmed values, empty as `nil`.
    static func committed(number: String, title: String) -> (number: String?, title: String?) {
        let n = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (n.isEmpty ? nil : n, t.isEmpty ? nil : t)
    }

    static var menuTitle: String {
        NSLocalizedString("Name Sheet…", comment: "Navigator page menu: type this sheet's number and title")
    }
    static var numberPlaceholder: String {
        NSLocalizedString("Number", comment: "Sheet name editor: the sheet number field, e.g. A-101")
    }
    static var titlePlaceholder: String {
        NSLocalizedString("Title", comment: "Sheet name editor: the sheet title field, e.g. Floor Plan")
    }
}
