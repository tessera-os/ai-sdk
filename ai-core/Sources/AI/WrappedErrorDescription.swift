import Foundation

extension AIError {
  /// Wraps a non-AI error, keeping its diagnostic detail.
  ///
  /// A decoding error becomes a malformed-response error, which is not retried,
  /// and keeps its debug description and coding path: its localized description
  /// says only that the data was in the wrong format. Any other error is a
  /// transport failure.
  ///
  /// - Parameter error: The underlying failure.
  /// - Returns: The AI error describing it.
  static func wrapping(_ error: any Error) -> AIError {
    guard let decoding = error as? DecodingError else { return .transport(error.localizedDescription) }
    let context: DecodingError.Context
    switch decoding {
    case .dataCorrupted(let value), .keyNotFound(_, let value), .typeMismatch(_, let value),
      .valueNotFound(_, let value):
      context = value
    @unknown default:
      return .malformed(String(describing: decoding))
    }
    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
    let underlying = (context.underlyingError as NSError?).map { " (\($0.debugDescription))" } ?? ""
    return .malformed(
      "Undecodable data\(path.isEmpty ? "" : " at \(path)"): \(context.debugDescription)\(underlying)")
  }
}
