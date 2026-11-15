import Foundation

/// A lossless, Codable representation of a JSON document.
///
/// Use JSONValue for tool schemas and arguments, provider-specific request
/// options, or metadata that the canonical SDK types do not interpret. The
/// enum preserves integer and floating-point numbers separately.
public indirect enum JSONValue: Codable, Sendable, Equatable {
  /// The JSON null value.
  case null

  /// A JSON boolean.
  case bool(Bool)

  /// An integer JSON number.
  case integer(Int64)

  /// A non-integral JSON number.
  case number(Double)

  /// A JSON string.
  case string(String)

  /// An ordered JSON array.
  case array([JSONValue])

  /// A JSON object keyed by member name.
  case object([String: JSONValue])

  /// Decodes one JSON value from a single-value decoder container.
  ///
  /// Numbers that fit in Int64 are represented as integer values; other
  /// numeric values are represented as floating-point values.
  ///
  /// - Parameter decoder: The decoder providing the JSON value.
  /// - Throws: A decoding error when the input is not valid JSON.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try Self.decodeIfType(Bool.self, from: container) {
      self = .bool(value)
    } else if let value = try Self.decodeIfType(Int64.self, from: container) {
      self = .integer(value)
    } else if let value = try Self.decodeIfType(Double.self, from: container) {
      self = .number(value)
    } else if let value = try Self.decodeIfType(String.self, from: container) {
      self = .string(value)
    } else if let value = try Self.decodeIfType([JSONValue].self, from: container) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  /// Decodes `type` from the container, or answers nil when the value in it is
  /// not of that type.
  ///
  /// Probing for the JSON type of a value is how `init(from:)` finds the case:
  /// a type mismatch (or a number that does not fit, which decoders report as
  /// corrupted data) is the expected "not this one". The last probe in
  /// `init(from:)` decodes without it, so genuinely invalid input still throws.
  private static func decodeIfType<Value: Decodable>(
    _ type: Value.Type, from container: any SingleValueDecodingContainer
  ) throws -> Value? {
    do {
      return try container.decode(type)
    } catch DecodingError.typeMismatch, DecodingError.dataCorrupted {
      return nil
    }
  }

  /// Encodes this value as the corresponding JSON primitive, array, or object.
  ///
  /// - Parameter encoder: The encoder receiving the JSON value.
  /// - Throws: An encoding error if a contained value cannot be encoded.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  /// Returns the string payload when this value is a JSON string.
  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  /// Looks up a member when this value is an object.
  ///
  /// Returns nil for a missing member or when this value is not an object.
  public subscript(_ key: String) -> JSONValue? {
    guard case .object(let object) = self else { return nil }
    return object[key]
  }

  /// Encodes this value as JSON data.
  ///
  /// - Parameter sortedKeys: Sorts object keys for stable output when true.
  /// - Returns: UTF-8 encoded JSON data.
  /// - Throws: An encoding error if the value cannot be represented as JSON.
  public func encoded(sortedKeys: Bool = false) throws -> Data {
    let encoder = JSONEncoder()
    if sortedKeys { encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes] }
    return try encoder.encode(self)
  }

  /// Parses one JSON document.
  ///
  /// - Parameter data: UTF-8 JSON data.
  /// - Returns: The parsed JSON value.
  /// - Throws: A decoding error when the data is not valid JSON.
  public static func parse(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
  }
}
