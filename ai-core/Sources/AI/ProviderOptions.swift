import Foundation

extension Dictionary where Key == String, Value == JSONValue {
  /// Merges caller-supplied provider options into an encoded request document.
  ///
  /// Core request fields always win: a provider option is ignored when the
  /// document already holds that key or when the key is reserved. This stops
  /// `providerOptions` from replacing the model, messages, token limit, tools,
  /// or streaming flags the SDK derived from the canonical request.
  ///
  /// - Parameters:
  ///   - providerOptions: The request's providerOptions value. Non-object values are ignored.
  ///   - reserved: Keys owned by the backend even when the document does not
  ///     currently contain them (for example `tools` on a request without tools).
  public mutating func merge(providerOptions: JSONValue?, reserving reserved: Set<String> = []) {
    guard case .object(let values)? = providerOptions else { return }
    for (key, value) in values where self[key] == nil && !reserved.contains(key) {
      self[key] = value
    }
  }
}
