import Foundation
import CXlsxWriter

/// Everything the XLSX bridge can refuse to do, as a typed error.
///
/// libxlsxwriter reports failures as an `lxw_error` enum and, in a handful of places, as a
/// `NULL` return. Neither is allowed to travel further than this file: the Swift API either
/// produced a workbook or threw one of these.
public enum XlsxError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A `NULL` return from `workbook_new_opt()` — almost always an unopenable output path.
    case workbookCreationFailed(path: String)
    /// A `NULL` return from `workbook_add_worksheet()`; the name is invalid or a duplicate.
    case worksheetCreationFailed(name: String)
    /// A `NULL` return from `workbook_add_format()`.
    case formatCreationFailed
    /// The builder was used after the workbook was closed.
    case workbookAlreadyClosed
    /// A row or column index outside the XLSX grid (1 048 576 × 16 384).
    case cellOutOfRange(row: Int, column: Int)
    /// A NaN or infinite number. libxlsxwriter would write `<v>NAN</v>` / `<v>INF</v>`, which
    /// Excel refuses to open without a repair that drops the cell (BH-081).
    case nonFiniteNumber(row: Int, column: Int)
    /// A date that is not finite or lies outside what a 64-bit Unix time can hold (BH-404).
    case dateOutOfRange(row: Int, column: Int)

    /// libxlsxwriter could not create or read a temporary file.
    ///
    /// This bridge is built with `USE_STANDARD_TMPFILE`, so the temporary file comes from the C
    /// standard `tmpfile()` rather than from the MPL-2.0 `tmpfileplus` component that upstream
    /// uses by default (see `VENDORED.md` and conflict 3 in `Docs/Licences/LICENSE_EVIDENCE.md`).
    /// If this error ever appears in the field it is the *first* thing to suspect, so it is its
    /// own case with its own message rather than being folded into
    /// ``libraryError(code:name:message:)``.
    case temporaryFileUnavailable(code: Int32, message: String)

    /// Any other `lxw_error`.
    case libraryError(code: Int32, name: String, message: String)

    public var description: String {
        switch self {
        case .workbookCreationFailed(let path):
            "libxlsxwriter could not create a workbook at \(path)"
        case .worksheetCreationFailed(let name):
            "libxlsxwriter refused the worksheet name \"\(name)\""
        case .formatCreationFailed:
            "libxlsxwriter could not allocate a cell format"
        case .workbookAlreadyClosed:
            "the workbook was used after it was closed"
        case .cellOutOfRange(let row, let column):
            "cell (\(row), \(column)) is outside the XLSX grid"
        case .nonFiniteNumber(let row, let column):
            "cell (\(row), \(column)) was given a number that is not finite"
        case .dateOutOfRange(let row, let column):
            "cell (\(row), \(column)) was given a date outside the representable range"
        case .temporaryFileUnavailable(let code, let message):
            """
            libxlsxwriter could not use a temporary file (lxw_error \(code): \(message)). \
            This bridge is built with USE_STANDARD_TMPFILE, so the temporary file comes from the \
            C standard tmpfile() and not from the MPL-2.0 tmpfileplus component. If this is \
            reproducible under the App Sandbox, the USE_STANDARD_TMPFILE decision \
            (Docs/Licences/LICENSE_EVIDENCE.md, conflict 3) must be revisited — do not work \
            around it here.
            """
        case .libraryError(let code, let name, let message):
            "libxlsxwriter error \(name) (\(code)): \(message)"
        }
    }
}

/// Maps an `lxw_error` onto ``XlsxError``, or returns for `LXW_NO_ERROR`.
@inline(__always)
func check(_ status: lxw_error) throws {
    guard status != LXW_NO_ERROR else { return }
    let code = Int32(status.rawValue)
    let message = String(cString: lxw_strerror(status))
    switch status {
    case LXW_ERROR_CREATING_TMPFILE, LXW_ERROR_READING_TMPFILE:
        throw XlsxError.temporaryFileUnavailable(code: code, message: message)
    default:
        throw XlsxError.libraryError(code: code, name: lxwErrorName(status), message: message)
    }
}

/// The symbolic name of an `lxw_error`. The C enum imports as a `RawRepresentable` struct, so
/// `"\(status)"` printed `lxw_error(rawValue: 24)` instead of a name (BH-400).
func lxwErrorName(_ status: lxw_error) -> String {
    let names: [(lxw_error, String)] = [
        (LXW_NO_ERROR, "LXW_NO_ERROR"),
        (LXW_ERROR_MEMORY_MALLOC_FAILED, "LXW_ERROR_MEMORY_MALLOC_FAILED"),
        (LXW_ERROR_CREATING_XLSX_FILE, "LXW_ERROR_CREATING_XLSX_FILE"),
        (LXW_ERROR_CREATING_TMPFILE, "LXW_ERROR_CREATING_TMPFILE"),
        (LXW_ERROR_READING_TMPFILE, "LXW_ERROR_READING_TMPFILE"),
        (LXW_ERROR_ZIP_FILE_OPERATION, "LXW_ERROR_ZIP_FILE_OPERATION"),
        (LXW_ERROR_ZIP_PARAMETER_ERROR, "LXW_ERROR_ZIP_PARAMETER_ERROR"),
        (LXW_ERROR_ZIP_BAD_ZIP_FILE, "LXW_ERROR_ZIP_BAD_ZIP_FILE"),
        (LXW_ERROR_ZIP_INTERNAL_ERROR, "LXW_ERROR_ZIP_INTERNAL_ERROR"),
        (LXW_ERROR_ZIP_FILE_ADD, "LXW_ERROR_ZIP_FILE_ADD"),
        (LXW_ERROR_ZIP_CLOSE, "LXW_ERROR_ZIP_CLOSE"),
        (LXW_ERROR_FEATURE_NOT_SUPPORTED, "LXW_ERROR_FEATURE_NOT_SUPPORTED"),
        (LXW_ERROR_NULL_PARAMETER_IGNORED, "LXW_ERROR_NULL_PARAMETER_IGNORED"),
        (LXW_ERROR_PARAMETER_VALIDATION, "LXW_ERROR_PARAMETER_VALIDATION"),
        (LXW_ERROR_PARAMETER_IS_EMPTY, "LXW_ERROR_PARAMETER_IS_EMPTY"),
        (LXW_ERROR_DATETIME_VALIDATION, "LXW_ERROR_DATETIME_VALIDATION"),
        (LXW_ERROR_SHEETNAME_LENGTH_EXCEEDED, "LXW_ERROR_SHEETNAME_LENGTH_EXCEEDED"),
        (LXW_ERROR_INVALID_SHEETNAME_CHARACTER, "LXW_ERROR_INVALID_SHEETNAME_CHARACTER"),
        (LXW_ERROR_SHEETNAME_START_END_APOSTROPHE, "LXW_ERROR_SHEETNAME_START_END_APOSTROPHE"),
        (LXW_ERROR_SHEETNAME_ALREADY_USED, "LXW_ERROR_SHEETNAME_ALREADY_USED"),
        (LXW_ERROR_32_STRING_LENGTH_EXCEEDED, "LXW_ERROR_32_STRING_LENGTH_EXCEEDED"),
        (LXW_ERROR_128_STRING_LENGTH_EXCEEDED, "LXW_ERROR_128_STRING_LENGTH_EXCEEDED"),
        (LXW_ERROR_255_STRING_LENGTH_EXCEEDED, "LXW_ERROR_255_STRING_LENGTH_EXCEEDED"),
        (LXW_ERROR_MAX_STRING_LENGTH_EXCEEDED, "LXW_ERROR_MAX_STRING_LENGTH_EXCEEDED"),
        (LXW_ERROR_SHARED_STRING_INDEX_NOT_FOUND, "LXW_ERROR_SHARED_STRING_INDEX_NOT_FOUND"),
        (LXW_ERROR_WORKSHEET_INDEX_OUT_OF_RANGE, "LXW_ERROR_WORKSHEET_INDEX_OUT_OF_RANGE"),
        (LXW_ERROR_WORKSHEET_MAX_URL_LENGTH_EXCEEDED, "LXW_ERROR_WORKSHEET_MAX_URL_LENGTH_EXCEEDED"),
        (LXW_ERROR_WORKSHEET_MAX_NUMBER_URLS_EXCEEDED, "LXW_ERROR_WORKSHEET_MAX_NUMBER_URLS_EXCEEDED"),
        (LXW_ERROR_IMAGE_DIMENSIONS, "LXW_ERROR_IMAGE_DIMENSIONS"),
    ]
    return names.first { $0.0 == status }?.1 ?? "LXW_ERROR_\(status.rawValue)"
}
