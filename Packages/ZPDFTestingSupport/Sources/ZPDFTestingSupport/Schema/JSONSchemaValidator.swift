import Foundation

/// A small JSON Schema validator for the draft 2020-12 subset Zenit's published format schemas
/// use (NL-PLAT-14): `type` (one or several), `properties`, `required`,
/// `additionalProperties` (boolean or schema), `items`, `minItems`, `maxItems`, `enum`, `const`,
/// `minimum`, `maximum`, `minLength`, `maxLength`, `pattern`, `oneOf`, `anyOf`, `allOf` and local
/// `$ref`s into `$defs` (`#/$defs/name`). Anything else in a schema is ignored, so a schema must
/// not rely on a keyword this does not list.
///
/// In the repository so the conformance tests add no dependency. It answers with every violation
/// and the JSON path where it happened, so a failing test says what drifted.
public struct JSONSchemaValidator {

    public struct Violation: Sendable, Equatable, CustomStringConvertible {
        public let path: String
        public let message: String
        public var description: String { "\(path): \(message)" }
    }

    public enum SchemaError: Error, Equatable, CustomStringConvertible {
        case notAnObject
        case unresolvedReference(String)
        public var description: String {
            switch self {
            case .notAnObject: return "the schema is not a JSON object"
            case let .unresolvedReference(ref): return "the schema refers to \(ref), which it does not define"
            }
        }
    }

    private let root: [String: Any]

    public init(schema data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SchemaError.notAnObject }
        root = object
    }

    /// Every way `instance` breaks the schema; empty when it conforms.
    public func validate(_ instance: Data) throws -> [Violation] {
        let value = try JSONSerialization.jsonObject(with: instance, options: [.fragmentsAllowed])
        var violations: [Violation] = []
        try check(value, against: root, path: "$", into: &violations)
        return violations
    }

    private func resolve(_ ref: String) throws -> [String: Any] {
        let prefix = "#/$defs/"
        guard ref.hasPrefix(prefix), let defs = root["$defs"] as? [String: Any],
              let target = defs[String(ref.dropFirst(prefix.count))] as? [String: Any] else {
            throw SchemaError.unresolvedReference(ref)
        }
        return target
    }

    private func typeName(_ value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "boolean" }
            return floor(number.doubleValue) == number.doubleValue && !"\(number)".contains(".") ? "integer" : "number"
        case is String: return "string"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        default: return "unknown"
        }
    }

    private func matches(_ value: Any, type: String) -> Bool {
        let actual = typeName(value)
        return actual == type || (type == "number" && actual == "integer")
    }

    private func check(_ value: Any, against schema: [String: Any], path: String, into violations: inout [Violation]) throws {
        if let ref = schema["$ref"] as? String {
            try check(value, against: try resolve(ref), path: path, into: &violations)
        }
        if let type = schema["type"] {
            let types = (type as? [String]) ?? [(type as? String) ?? ""]
            if !types.contains(where: { matches(value, type: $0) }) {
                violations.append(Violation(path: path, message: "is \(typeName(value)), expected \(types.joined(separator: " or "))"))
                return
            }
        }
        if let options = schema["enum"] as? [Any], !options.contains(where: { equal($0, value) }) {
            violations.append(Violation(path: path, message: "is not one of the allowed values"))
        }
        if let constant = schema["const"], !equal(constant, value) {
            violations.append(Violation(path: path, message: "is not the required constant"))
        }
        if let text = value as? String {
            if let minimum = schema["minLength"] as? Int, text.count < minimum {
                violations.append(Violation(path: path, message: "is shorter than \(minimum)"))
            }
            if let maximum = schema["maxLength"] as? Int, text.count > maximum {
                violations.append(Violation(path: path, message: "is longer than \(maximum)"))
            }
            if let pattern = schema["pattern"] as? String, text.range(of: pattern, options: .regularExpression) == nil {
                violations.append(Violation(path: path, message: "does not match \(pattern)"))
            }
        }
        if let number = value as? NSNumber, typeName(value) != "boolean" {
            if let minimum = (schema["minimum"] as? NSNumber)?.doubleValue, number.doubleValue < minimum {
                violations.append(Violation(path: path, message: "is below \(minimum)"))
            }
            if let maximum = (schema["maximum"] as? NSNumber)?.doubleValue, number.doubleValue > maximum {
                violations.append(Violation(path: path, message: "is above \(maximum)"))
            }
        }
        if let object = value as? [String: Any] {
            for key in (schema["required"] as? [String]) ?? [] where object[key] == nil {
                violations.append(Violation(path: path, message: "is missing \(key)"))
            }
            let properties = (schema["properties"] as? [String: Any]) ?? [:]
            for (key, member) in object {
                if let propertySchema = properties[key] as? [String: Any] {
                    try check(member, against: propertySchema, path: "\(path).\(key)", into: &violations)
                } else if let additional = schema["additionalProperties"] {
                    if let allowed = additional as? Bool, !allowed {
                        violations.append(Violation(path: "\(path).\(key)", message: "is not a property of this format"))
                    } else if let additionalSchema = additional as? [String: Any] {
                        try check(member, against: additionalSchema, path: "\(path).\(key)", into: &violations)
                    }
                }
            }
        }
        if let array = value as? [Any] {
            if let minimum = schema["minItems"] as? Int, array.count < minimum {
                violations.append(Violation(path: path, message: "has fewer than \(minimum) items"))
            }
            if let maximum = schema["maxItems"] as? Int, array.count > maximum {
                violations.append(Violation(path: path, message: "has more than \(maximum) items"))
            }
            if let items = schema["items"] as? [String: Any] {
                for (index, element) in array.enumerated() {
                    try check(element, against: items, path: "\(path)[\(index)]", into: &violations)
                }
            }
        }
        if let all = schema["allOf"] as? [[String: Any]] {
            for sub in all { try check(value, against: sub, path: path, into: &violations) }
        }
        if let any = schema["anyOf"] as? [[String: Any]] {
            var passed = false
            for sub in any {
                var trial: [Violation] = []
                try check(value, against: sub, path: path, into: &trial)
                if trial.isEmpty { passed = true; break }
            }
            if !passed { violations.append(Violation(path: path, message: "matches none of the allowed shapes")) }
        }
        if let one = schema["oneOf"] as? [[String: Any]] {
            var passing = 0
            for sub in one {
                var trial: [Violation] = []
                try check(value, against: sub, path: path, into: &trial)
                if trial.isEmpty { passing += 1 }
            }
            if passing != 1 { violations.append(Violation(path: path, message: "matches \(passing) of the shapes, expected exactly one")) }
        }
    }

    private func equal(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case let (x as String, y as String): return x == y
        case let (x as NSNumber, y as NSNumber): return x == y
        case (is NSNull, is NSNull): return true
        default: return false
        }
    }
}
