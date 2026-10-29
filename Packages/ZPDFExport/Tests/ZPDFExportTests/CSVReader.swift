import Foundation

/// A strict RFC 4180 reader, written for the tests only.
///
/// It exists so the CSV assertions read the file the way a conforming parser would, rather than
/// by `split(separator: ",")`, which would pass on files that are not CSV at all.
enum CSVReader {

    static func records(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        func endField() {
            fields.append(field)
            field = ""
        }
        func endRecord() {
            endField()
            records.append(fields)
            fields = []
        }

        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"" where field.isEmpty:
                    inQuotes = true
                case delimiter:
                    endField()
                // Swift folds CRLF into a single `Character`, so all three spellings of a line
                // break have to be matched here or a CRLF file parses as one enormous field.
                case "\r\n", "\r", "\n":
                    endRecord()
                default:
                    field.append(character)
                }
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !fields.isEmpty { endRecord() }
        return records
    }
}
