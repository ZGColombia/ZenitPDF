import Foundation

/// How both redaction methods look for the words that stood under their boxes (R-098, R-099).
///
/// # Whole words
///
/// A word is found only where it stands on its own — not preceded or followed by a letter or a
/// digit. A plain substring test refused a box over "Smith and Partners" on a set whose next sheet
/// said "standard", and told the person to black out "and" there. A secret such as `BIDAMOUNT` or
/// `4820000` is still found wherever it is written as itself.
///
/// # Only where text lives
///
/// The file is searched in its strings — literal or hex, in object bodies and in the operands of
/// content streams, forms, tiling-pattern cells and Type 3 glyph procedures, decoded — and never in
/// its raw bytes, names, operators, picture samples or font programs. Every PDF carries `/Type
/// /Page`, `/Length`, `/Filter` and a creation date; searching the bytes refused every box over a
/// title block's "Date", "Page", "Type" or "Size". The producer and the dates the writer itself
/// puts in the document information are not the drawing's text and are not searched either.
enum RedactionWordSearch {

    /// Keys of the trailer's `/Info` that the writer fills itself.
    static let writerInformationKeys: Set<String> = ["Producer", "CreationDate", "ModDate"]

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// How many times `word` stands in `text` as a whole word.
    static func occurrences(of word: String, in text: String, caseInsensitive: Bool = false) -> Int {
        guard !word.isEmpty, !text.isEmpty else { return 0 }
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive, .diacriticInsensitive] : []
        // A boundary matters only on a side where the word itself ends in a letter or digit:
        // "$4,820" preceded by a space or by "Total" is the same figure.
        let boundedStart = word.first.map(isWordCharacter) ?? false
        let boundedEnd = word.last.map(isWordCharacter) ?? false
        var count = 0
        var cursor = text.startIndex
        while cursor < text.endIndex, let found = text.range(of: word, options: options, range: cursor..<text.endIndex) {
            let startsWord = !boundedStart || found.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: found.lowerBound)])
            let endsWord = !boundedEnd || found.upperBound >= text.endIndex || !isWordCharacter(text[found.upperBound])
            if startsWord && endsWord {
                count += 1
                cursor = found.upperBound
            } else {
                cursor = text.index(after: found.lowerBound)
            }
        }
        return count
    }

    static func contains(_ word: String, in text: String, caseInsensitive: Bool = false) -> Bool {
        occurrences(of: word, in: text, caseInsensitive: caseInsensitive) > 0
    }

    /// Every string in the file as text — literal or hex, in object bodies and in content-stream
    /// operands — decoded as UTF-16 when it says so and byte for byte otherwise. A string of even
    /// length without a byte-order mark is also read as UTF-16BE: a two-byte font's codes are
    /// often Unicode itself, and the removed word must not hide there.
    static func fileStrings(_ scan: PDFDocumentScan) -> [String] {
        var strings: [String] = []
        func add(_ bytes: [UInt8]) {
            strings.append(VectorRedactor.text(bytes))
            if !bytes.starts(with: [0xFE, 0xFF]), bytes.count >= 2, bytes.count % 2 == 0 {
                strings.append(RedactionCMap.utf16(bytes))
            }
        }
        func collect(_ object: PDFObject, depth: Int) {
            guard depth < 64 else { return }
            switch object {
            case let .string(value), let .hexString(value):
                add(value)
            case let .array(values):
                for value in values { collect(value, depth: depth + 1) }
            case let .dictionary(entries), let .stream(entries, _):
                for value in entries.values { collect(value, depth: depth + 1) }
            default:
                break
            }
        }
        var contentStreams: Set<Int> = []
        for entry in (try? scan.pages()) ?? [] {
            switch entry.dictionary["Contents"] {
            case let .reference(number, _)?: contentStreams.insert(number)
            case let .array(items)?: for item in items { if let number = item.referenceValue?.number { contentStreams.insert(number) } }
            default: break
            }
        }
        for entry in scan.objects.values {
            if let procs = scan.dictionary(entry.object.dictionaryValue?["CharProcs"]) {
                for proc in procs.values { if let number = proc.referenceValue?.number { contentStreams.insert(number) } }
            }
        }
        let information = scan.trailer["Info"]?.referenceValue?.number
        for (number, entry) in scan.objects {
            if number == information, let dictionary = entry.object.dictionaryValue {
                for (key, value) in dictionary where !writerInformationKeys.contains(key) { collect(value, depth: 1) }
                continue
            }
            collect(entry.object, depth: 0)
            guard case let .stream(dictionary, raw) = entry.object else { continue }
            let isContent = contentStreams.contains(number) || dictionary["Subtype"]?.nameValue == "Form"
                || dictionary["PatternType"]?.integerValue == 1
            guard isContent, let decoded = try? RedactionStreamFilters.decode(dictionary: dictionary, data: raw).data,
                  let operations = try? RedactionContentLexer.parse(decoded) else { continue }
            for operation in operations { for operand in operation.operands { collect(operand, depth: 0) } }
        }
        // A direct /Info dictionary in the trailer.
        if case let .dictionary(dictionary)? = scan.trailer["Info"] {
            for (key, value) in dictionary where !writerInformationKeys.contains(key) { collect(value, depth: 1) }
        }
        return strings
    }
}
