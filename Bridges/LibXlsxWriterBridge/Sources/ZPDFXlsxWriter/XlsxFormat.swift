import Foundation
import CXlsxWriter

/// A cell colour as libxlsxwriter wants it: 0xRRGGBB.
public struct XlsxColor: Hashable, Sendable {
    public let rgb: UInt32
    public init(rgb: UInt32) { self.rgb = rgb & 0x00FF_FFFF }
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.rgb = (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
    }
    public static let black = XlsxColor(rgb: 0x0000_00)
    public static let white = XlsxColor(rgb: 0xFFFF_FF)

    /// The value handed to libxlsxwriter. `0x000000` is the library's `LXW_COLOR_UNSET`
    /// sentinel, so real black must travel as `LXW_COLOR_BLACK` (`0x1000000`), or a black font
    /// becomes the theme colour and a black fill becomes no fill (BH-401).
    var libraryValue: lxw_color_t {
        rgb == 0 ? lxw_color_t(LXW_COLOR_BLACK.rawValue) : lxw_color_t(rgb)
    }
}

public enum XlsxAlignment: UInt8, Hashable, Sendable {
    case left = 1        // LXW_ALIGN_LEFT
    case center = 2      // LXW_ALIGN_CENTER
    case right = 3       // LXW_ALIGN_RIGHT
    case verticalTop = 8 // LXW_ALIGN_VERTICAL_TOP
    case verticalCenter = 10

    /// The value for the vertical axis: vertical cases pass through, `.center` means vertically
    /// centred, and `.left` / `.right` have no vertical meaning and set nothing.
    var verticalRawValue: UInt8? {
        switch self {
        case .verticalTop, .verticalCenter: rawValue
        case .center: XlsxAlignment.verticalCenter.rawValue
        case .left, .right: nil
        }
    }
}

public enum XlsxBorderStyle: UInt8, Hashable, Sendable {
    case none = 0
    case thin = 1
    case medium = 2
    case thick = 5
}

/// A declarative description of one cell format.
///
/// A value, not a handle: two equal specs resolve to the same `lxw_format *`, so a 10 000-row
/// sheet with three styles allocates three formats and not thirty thousand.
public struct XlsxFormatSpec: Hashable, Sendable {
    public var bold: Bool
    public var italic: Bool
    public var fontName: String?
    public var fontSize: Double?
    public var fontColor: XlsxColor?
    public var backgroundColor: XlsxColor?
    /// An Excel number-format code, for example `0.000` or `#,##0.00`. `nil` leaves the cell
    /// General.
    public var numberFormat: String?
    public var alignment: XlsxAlignment?
    public var verticalAlignment: XlsxAlignment?
    public var textWrap: Bool
    public var border: XlsxBorderStyle
    public var topBorder: XlsxBorderStyle
    public var bottomBorder: XlsxBorderStyle
    /// Excel silently turns a leading `=`, `+`, `-` or `@` in a *string* cell into a formula.
    /// Setting the quote prefix makes it stay text.
    public var quotePrefix: Bool

    public init(
        bold: Bool = false,
        italic: Bool = false,
        fontName: String? = nil,
        fontSize: Double? = nil,
        fontColor: XlsxColor? = nil,
        backgroundColor: XlsxColor? = nil,
        numberFormat: String? = nil,
        alignment: XlsxAlignment? = nil,
        verticalAlignment: XlsxAlignment? = nil,
        textWrap: Bool = false,
        border: XlsxBorderStyle = .none,
        topBorder: XlsxBorderStyle = .none,
        bottomBorder: XlsxBorderStyle = .none,
        quotePrefix: Bool = false
    ) {
        self.bold = bold
        self.italic = italic
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontColor = fontColor
        self.backgroundColor = backgroundColor
        self.numberFormat = numberFormat
        self.alignment = alignment
        self.verticalAlignment = verticalAlignment
        self.textWrap = textWrap
        self.border = border
        self.topBorder = topBorder
        self.bottomBorder = bottomBorder
        self.quotePrefix = quotePrefix
    }

    func apply(to format: UnsafeMutablePointer<lxw_format>) {
        if bold { format_set_bold(format) }
        if italic { format_set_italic(format) }
        if let fontName { fontName.withCString { format_set_font_name(format, $0) } }
        if let fontSize { format_set_font_size(format, fontSize) }
        if let fontColor { format_set_font_color(format, fontColor.libraryValue) }
        if let backgroundColor {
            // Pattern 1 is LXW_PATTERN_SOLID; without it the background colour is ignored.
            format_set_pattern(format, 1)
            format_set_bg_color(format, backgroundColor.libraryValue)
        }
        if let numberFormat { numberFormat.withCString { format_set_num_format(format, $0) } }
        if let alignment { format_set_align(format, alignment.rawValue) }
        // `format_set_align` routes by value (1-7 horizontal, 8-12 vertical), so a horizontal
        // case given as the *vertical* alignment used to overwrite the horizontal one and set
        // no vertical alignment at all (BH-402). Translate it onto the vertical axis instead.
        if let vertical = verticalAlignment?.verticalRawValue { format_set_align(format, vertical) }
        if textWrap { format_set_text_wrap(format) }
        if border != .none { format_set_border(format, border.rawValue) }
        if topBorder != .none { format_set_top(format, topBorder.rawValue) }
        if bottomBorder != .none { format_set_bottom(format, bottomBorder.rawValue) }
        if quotePrefix { format_set_quote_prefix(format) }
    }
}

/// An opaque handle on a format that belongs to one workbook.
///
/// Deliberately not `Sendable` and deliberately not storable past ``XlsxWriter/write(to:options:properties:_:)``:
/// `workbook_close()` frees every format it allocated.
public struct XlsxFormatHandle {
    let pointer: UnsafeMutablePointer<lxw_format>
}
