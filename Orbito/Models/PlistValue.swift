import Foundation

/// Sendable, value-typed mirror of a property list value.
///
/// Keeps launchd plists fully round-trippable: every key the app does not
/// understand is carried through unchanged when the file is written back.
indirect enum PlistValue: Hashable, Sendable {
    case string(String)
    case integer(Int)
    case real(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    init?(any value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .real(number.doubleValue)
            } else {
                self = .integer(number.intValue)
            }
        case let date as Date:
            self = .date(date)
        case let data as Data:
            self = .data(data)
        case let array as [Any]:
            self = .array(array.compactMap(PlistValue.init(any:)))
        case let dict as [String: Any]:
            var result: [String: PlistValue] = [:]
            for (key, raw) in dict {
                if let value = PlistValue(any: raw) { result[key] = value }
            }
            self = .dictionary(result)
        default:
            return nil
        }
    }

    /// Foundation object suitable for `PropertyListSerialization`.
    var foundationValue: Any {
        switch self {
        case .string(let value): value
        case .integer(let value): NSNumber(value: value)
        case .real(let value): NSNumber(value: value)
        case .bool(let value): NSNumber(value: value)
        case .date(let value): value
        case .data(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .dictionary(let dict): dict.mapValues(\.foundationValue)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Strict integer: launchd rejects strings and reals for integer keys.
    var integerValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [PlistValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var dictionaryValue: [String: PlistValue]? {
        if case .dictionary(let value) = self { return value }
        return nil
    }

    var typeName: String {
        switch self {
        case .string: "string"
        case .integer: "integer"
        case .real: "real"
        case .bool: "boolean"
        case .date: "date"
        case .data: "data"
        case .array: "array"
        case .dictionary: "dictionary"
        }
    }
}

enum PlistFormat: String, Hashable, Sendable, Codable {
    case xml
    case binary
    case openStep

    init(_ format: PropertyListSerialization.PropertyListFormat) {
        switch format {
        case .binary: self = .binary
        case .openStep: self = .openStep
        default: self = .xml
        }
    }

    /// OpenStep cannot be written by Foundation, so it is upgraded to XML.
    var writableFormat: PropertyListSerialization.PropertyListFormat {
        self == .binary ? .binary : .xml
    }
}
