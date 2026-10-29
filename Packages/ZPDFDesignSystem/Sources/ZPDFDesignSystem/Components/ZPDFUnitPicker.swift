import SwiftUI

/// One entry in a unit picker.
///
/// The design system stays out of the unit-conversion business: it renders whatever list the
/// measurement layer hands it, keyed by a stable identifier.
public struct ZPDFUnitOption: Identifiable, Hashable, Sendable {
    /// Stable identifier, e.g. "mm" or "sqm". Never localised.
    public let id: String
    /// The spoken, localised name, e.g. "Millimetres".
    public let name: String
    /// The compact display form, e.g. "mm".
    public let abbreviation: String

    public init(id: String, name: String, abbreviation: String) {
        self.id = id
        self.name = name
        self.abbreviation = abbreviation
    }
}

/// A compact unit chooser for inspector rows and the status bar.
public struct ZPDFUnitPicker: View {
    @Binding private var selection: String
    private let options: [ZPDFUnitOption]
    private let accessibilityTitle: String

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    public init(
        selection: Binding<String>,
        options: [ZPDFUnitOption],
        accessibilityTitle: String
    ) {
        self._selection = selection
        self.options = options
        self.accessibilityTitle = accessibilityTitle
    }

    public var body: some View {
        // IM-060: the closed control shows the compact abbreviation; the open menu lists the
        // full names, so a precision menu reads "0 decimal places (1)" instead of a bare "1".
        Menu {
            Picker(selection: $selection) {
                ForEach(options) { option in
                    Text(Self.menuTitle(for: option))
                        .accessibilityLabel(option.name)
                        .tag(option.id)
                }
            } label: {
                Text(accessibilityTitle)
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            Text(selectedAbbreviation)
        }
        .menuStyle(.button)
        .fixedSize()
        .controlSize(.small)
        .zpdfFont(.control)
        .frame(minHeight: ZPDFSpacing.Control.inspectorControl)
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.small)
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(Text(selectedName))
    }

    /// What one row of the open menu says: the full name, with the abbreviation when it adds
    /// something.
    static func menuTitle(for option: ZPDFUnitOption) -> String {
        guard !option.abbreviation.isEmpty, option.abbreviation != option.name else { return option.name }
        return String(
            format: NSLocalizedString("%1$@ (%2$@)", comment: "Unit menu row: full name, then its abbreviation"),
            option.name, option.abbreviation
        )
    }

    private var selectedAbbreviation: String {
        options.first { $0.id == selection }?.abbreviation ?? "\u{2014}"
    }

    private var selectedName: String {
        options.first { $0.id == selection }?.name
            ?? NSLocalizedString("No unit selected", comment: "Accessibility value when no unit is chosen")
    }
}

public extension ZPDFUnitOption {
    /// A small sample list used by previews only. Real unit catalogues live in the
    /// measurement layer, not in the design system.
    static let previewLengthUnits: [ZPDFUnitOption] = [
        ZPDFUnitOption(id: "mm", name: NSLocalizedString("Millimetres", comment: "Unit name"), abbreviation: "mm"),
        ZPDFUnitOption(id: "cm", name: NSLocalizedString("Centimetres", comment: "Unit name"), abbreviation: "cm"),
        ZPDFUnitOption(id: "m", name: NSLocalizedString("Metres", comment: "Unit name"), abbreviation: "m"),
        ZPDFUnitOption(id: "ft", name: NSLocalizedString("Feet", comment: "Unit name"), abbreviation: "ft")
    ]
}

#if DEBUG
struct ZPDFUnitPicker_Previews: PreviewProvider {
    private struct Demo: View {
        @State private var unit = "mm"

        var body: some View {
            ZPDFPreviewPanel("Unit picker") {
                VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                    ZPDFUnitPicker(
                        selection: $unit,
                        options: ZPDFUnitOption.previewLengthUnits,
                        accessibilityTitle: NSLocalizedString("Output unit", comment: "Preview label")
                    )
                    ZPDFUnitPicker(
                        selection: .constant("m"),
                        options: ZPDFUnitOption.previewLengthUnits,
                        accessibilityTitle: NSLocalizedString("Output unit", comment: "Preview label")
                    )
                    .disabled(true)
                }
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFUnitPicker - dark and light")
    }
}
#endif
