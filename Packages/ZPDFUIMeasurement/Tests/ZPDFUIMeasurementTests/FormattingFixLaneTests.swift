import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Bug hunt 2, the value formatter at the view boundary.
@Suite("Formatting fixes (bug hunt 2)")
struct FormattingFixLaneTests {

    private let separator = Locale.current.decimalSeparator ?? "."

    /// Old output: `unitSymbol` returned `ft` beside a value already reading `12' 6 1/2"`, and
    /// the caption headline composed them into `12' 6 1/2" ft` (BH-744 is the same seam). The
    /// loupe composes its readout the same way, so the rule still ships there.
    @Test("BH-262 / BH-744: a feet-and-inches value gets no second unit suffix")
    func imperialValueHasNoSuffix() {
        let feet = MeasurementValueFormatter(lengthUnit: .foot)
        let length = Decimal(string: "3.8227")!
        #expect(feet.lengthSuffix == "")
        #expect(!feet.lengthString(metres: length).hasSuffix("ft"))
        #expect(MeasurementValueFormatter(lengthUnit: .inch).lengthSuffix == "")
        #expect(MeasurementValueFormatter(lengthUnit: .yard).lengthSuffix == "yd")
        #expect(MeasurementValueFormatter(lengthUnit: .metre).lengthSuffix == "m")
        // 12.5 m with the metre suffix: "12.5 m".
        #expect(MeasurementValueFormatter().lengthString(metres: 12.5) == "12\(separator)5 m")
    }

    /// IM-210: padded decimals for live readouts, trimmed for everything else.
    @Test("IM-210: the live readout keeps a fixed number of decimals")
    func liveReadoutIsPadded() {
        let formatter = MeasurementValueFormatter()
        let a = Decimal(string: "12.5")!
        let b = Decimal(string: "12.513")!
        #expect(formatter.lengthValueString(metres: a) == "12\(separator)5")
        #expect(formatter.forLiveReadout.lengthValueString(metres: a) == "12\(separator)500")
        #expect(
            formatter.forLiveReadout.lengthValueString(metres: a).count
                == formatter.forLiveReadout.lengthValueString(metres: b).count
        )
        // Millimetres print whole: 12.5 m = 12 500 mm, grouped by the locale.
        let millimetres = MeasurementValueFormatter(lengthUnit: .millimetre).lengthValueString(metres: a)
        #expect(millimetres.filter(\.isNumber) == "12500")
    }

    /// IM-113: the per-call `NumberFormatter` is gone. Same strings, measured faster.
    @Test("IM-113: formatting without a formatter per value is identical and faster")
    func cachedFormattingIsFaster() {
        func oldDecimalString(_ value: Double) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = .current
            formatter.usesGroupingSeparator = true
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 3
            return formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
        let formatter = MeasurementValueFormatter()
        let quantities = (0..<10_000).map { Decimal(Double($0) * 1.2345 + 0.0003) }
        // The exact doubles the formatter sees after the Decimal round trip.
        let values = quantities.map { NSDecimalNumber(decimal: $0).doubleValue }

        for (value, quantity) in zip(values.prefix(500), quantities.prefix(500)) {
            #expect(formatter.lengthValueString(metres: quantity) == oldDecimalString(value), "\(value)")
        }

        let clock = ContinuousClock()
        let old = clock.measure { for value in values { _ = oldDecimalString(value) } }
        let new = clock.measure { for quantity in quantities { _ = formatter.lengthValueString(metres: quantity) } }
        print("IM-113: 10 000 values, per-call NumberFormatter \(old), FormatStyle \(new)")
        #expect(new < old)
    }
}
