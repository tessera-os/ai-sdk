import Foundation

/// A failed attempt annotated with the HTTP context a retry strategy needs.
public struct AttemptFailure: Error {
  /// The decoded failure.
  public var error: AIError
  /// The HTTP status, when a response arrived.
  public var status: Int?
  /// The parsed Retry-After header, when present.
  public var retryAfter: Duration?
  /// True when output already reached the caller, so the attempt cannot be repeated.
  public var isCommitted: Bool

  /// Creates a failure record.
  public init(
    error: AIError, status: Int? = nil, retryAfter: Duration? = nil, isCommitted: Bool = false
  ) {
    self.error = error
    self.status = status
    self.retryAfter = retryAfter
    self.isCommitted = isCommitted
  }
}

/// Internal timeout signals; surfaced to callers as AIError.transport.
public enum GatewayTimeout: Error {
  /// Response headers did not arrive in time.
  case firstByte
  /// The whole call exceeded its time limit.
  case total
}

/// Whether a failure is worth repeating.
public enum FailureAction: Equatable, Sendable {
  /// Not worth repeating; surface immediately.
  case fatal
  /// Transient (429, 408, 5xx, overloaded, network, first-byte timeout).
  case transient
}

/// A failure reduced to an error, an action, and HTTP context.
public struct ClassifiedFailure: Sendable {
  /// The error to surface.
  public var error: AIError
  /// Whether to retry.
  public var action: FailureAction
  /// The HTTP status, when known.
  public var status: Int?
  /// The parsed Retry-After value, when present.
  public var retryAfter: Duration?

  /// Classifies any error raised by a gateway attempt.
  public init(_ raw: any Error) {
    var failure = AttemptFailure(error: .transport("Unknown failure."))
    switch raw {
    case let value as AttemptFailure: failure = value
    case let value as AIError: failure.error = value
    case GatewayTimeout.firstByte:
      failure.error = .transport("The request timed out waiting for the first byte.")
    case GatewayTimeout.total:
      failure.error = .transport("The request exceeded its total time limit.")
    default: failure.error = .wrapping(raw)
    }
    var status = failure.status
    var kind: String?
    switch failure.error {
    case .service(let service): status = status ?? service.status; kind = service.kind
    case .status(let code): status = status ?? code
    default: break
    }
    let isTransient: Bool
    if failure.isCommitted {
      isTransient = false
    } else if case .transport = failure.error {
      isTransient = true
    } else {
      isTransient =
        status == 429 || status == 408 || (status.map { $0 >= 500 } ?? false)
        || (kind?.contains("overloaded") ?? false)
    }
    self.error = failure.error
    self.action = isTransient ? .transient : .fatal
    self.status = status
    self.retryAfter = failure.retryAfter
  }
}

/// A parsed Retry-After header.
public struct RetryAfter: Sendable, Equatable {
  /// How long the server asked the client to wait.
  public var delay: Duration

  /// Parses delay-seconds or an HTTP date; returns nil for a missing or malformed value.
  ///
  /// - Parameters:
  ///   - header: The raw header value.
  ///   - now: The reference time for HTTP-date values.
  public init?(header: String?, now: Date) {
    guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
      return nil
    }
    if let seconds = Double(text), seconds >= 0 {
      delay = .seconds(seconds)
      return
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: text) else { return nil }
    delay = .seconds(max(0, date.timeIntervalSince(now)))
  }
}
