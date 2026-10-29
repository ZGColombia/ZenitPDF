import Foundation
import ZPDFAppCore
import ZPDFUIPresentation
import ZPDFUIShell

/// The status strip's Unit menu, the application half (NL-UX-19): a choice becomes the
/// session's display units, the same setter the precision popup uses.
enum OutputUnitsMenu {

    /// The display units after a choice. A length in the other unit system also moves area and
    /// volume to that system, so "ft" never sits beside "m²".
    static func units(applying choice: StatusUnitChoice, to current: DisplayUnitSelection) -> DisplayUnitSelection {
        switch choice {
        case .metric:
            var next = DisplayUnitSelection.metric
            next.metricDecimalPlaces = current.metricDecimalPlaces
            return next
        case .imperial:
            var next = DisplayUnitSelection.imperial
            next.imperialPrecision = current.imperialPrecision
            next.metricDecimalPlaces = current.metricDecimalPlaces
            return next
        case .decimalFeet, .decimalInches:
            // NL-MEASURE-10: a decimal foot or inch length; area and volume move to imperial
            // with it, as any other change of unit system does.
            var next = current.withImperialLengthStyle(choice == .decimalFeet ? .decimalFeet : .decimalInches)
            if current.length.isMetric {
                next.area = DisplayUnitSelection.imperial.area
                next.volume = DisplayUnitSelection.imperial.volume
                next.slope = DisplayUnitSelection.imperial.slope
            }
            return next
        case .length(let unit):
            var next = current
            next.length = unit
            // Choosing a length unit from the list writes it the ordinary way.
            next.imperialLengthStyle = .feetInches
            if unit.isMetric != current.length.isMetric {
                let preset = unit.isMetric ? DisplayUnitSelection.metric : DisplayUnitSelection.imperial
                next.area = preset.area
                next.volume = preset.volume
                next.slope = preset.slope
            }
            return next
        case .divider:
            return current
        }
    }

    /// Wires the menu to a document's session.
    @MainActor
    static func wire(shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) {
        shell.onSetOutputUnits = { [weak document] choice in
            guard let core = document?.core else { return }
            Task { @MainActor in
                let current = await core.session.displayUnits
                let next = units(applying: choice, to: current)
                guard next != current else { return }
                try? await core.session.setUnits(next)
                await core.refresh()
            }
        }
    }
}
