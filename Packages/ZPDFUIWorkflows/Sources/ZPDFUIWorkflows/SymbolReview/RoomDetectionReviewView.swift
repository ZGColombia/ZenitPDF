import SwiftUI
import ZPDFDesignSystem

/// The room review (NL-AUTO-08).
public struct RoomDetectionReviewView: View {

    @Bindable private var model: RoomDetectionReviewModel

    public init(model: RoomDetectionReviewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(NSLocalizedString("Review the rooms found", comment: "Title of the room detection review"))
                .zpdfText(.windowTitle, .textPrimary)
            Text(model.summaryText).zpdfText(.caption, .textSecondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach($model.rows) { $row in
                    HStack(spacing: ZPDFSpacing.s) {
                        Toggle(isOn: Binding(
                            get: { model.includedIDs.contains(row.id) },
                            set: { model.setIncluded($0, id: row.id) }
                        )) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel(Text(String(
                            format: NSLocalizedString("Add room %@", comment: "Accessibility label for a room row checkbox; the room"),
                            row.name.isEmpty ? row.areaText : row.name
                        )))
                        TextField(NSLocalizedString("Room name", comment: "Room name field placeholder"), text: $row.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .accessibilityLabel(Text(NSLocalizedString("Room name", comment: "Room name field placeholder")))
                        Text(row.areaText).zpdfText(.monoNumeric, .textPrimary).frame(width: 90, alignment: .trailing)
                        Text(row.notes.joined(separator: " · ")).zpdfText(.caption, .textSecondary)
                        Spacer(minLength: 0)
                        Button(NSLocalizedString("Show", comment: "Symbol review: show this place on the sheet")) { model.reveal(row) }
                            .accessibilityLabel(Text(NSLocalizedString("Show this room on the sheet", comment: "Accessibility label for the room row Show button")))
                    }
                }
            }
            .listStyle(.inset)
            HStack(spacing: ZPDFSpacing.s) {
                Spacer(minLength: 0)
                Button(NSLocalizedString("Cancel", comment: "Close the room review without measuring")) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(WorkflowPlurals.addAreas(model.includedIDs.count)) { model.accept() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAccept)
            }
        }
        .padding(ZPDFSpacing.l)
        .frame(minWidth: 620, minHeight: 400)
        .background(ZPDFColor.background)
        .accessibilityElement(children: .contain)
    }
}
