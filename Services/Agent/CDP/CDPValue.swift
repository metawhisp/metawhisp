import Foundation

/// A JSON value as the Chrome DevTools Protocol sends and takes it, Sendable so
/// it can cross the connection's actor (ITER-076 3.1).
enum CDPValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CDPValue])
    case object([String: CDPValue])

    subscript(key: String) -> CDPValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// A whole number the protocol sent as a JSON number.
    var int: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) < 9e15 else { return nil }
        return Int(value)
    }

    var array: [CDPValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var object: [String: CDPValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    static func decode(_ text: String) throws -> CDPValue {
        try JSONDecoder().decode(CDPValue.self, from: Data(text.utf8))
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

extension CDPValue: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CDPValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CDPValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers go out as integers: CDP ids and pixel values are ints.
            if value.rounded() == value, abs(value) < 9e15 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let items): try container.encode(items)
        case .object(let fields): try container.encode(fields)
        }
    }
}

extension CDPValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: CDPValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, CDPValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
