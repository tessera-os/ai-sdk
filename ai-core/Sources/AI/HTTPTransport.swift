import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The status line and headers of an HTTP response.
public struct HTTPResponseHead: Sendable, Equatable {
  /// The HTTP status code.
  public var status: Int
  /// Response headers keyed by displayed name.
  public var headers: [String: String]

  /// Creates a response head.
  public init(status: Int, headers: [String: String] = [:]) {
    self.status = status
    self.headers = headers
  }

  /// Returns a header value, matching the name case-insensitively.
  public func value(for name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

/// A response whose body arrives as chunks.
public struct HTTPResponse: Sendable {
  /// Status and headers, available before any body bytes.
  public var head: HTTPResponseHead
  /// Body chunks in arrival order.
  public var body: AsyncThrowingStream<Data, any Error>

  /// Creates a streaming response.
  public init(head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>) {
    self.head = head
    self.body = body
  }
}

/// The network layer used by Gateway. Inject a fake in tests.
public protocol HTTPTransport: Sendable {
  /// Sends a request and returns once the response head has arrived.
  ///
  /// Implementations must stop work promptly when the calling task is cancelled.
  func open(_ request: URLRequest) async throws -> HTTPResponse
}

/// A transport backed by URLSession.
public struct URLSessionTransport: HTTPTransport {
  /// The session used for requests.
  public var session: URLSession

  /// Creates a transport over a session.
  public init(session: URLSession = .shared) { self.session = session }

  #if canImport(FoundationNetworking)
  /// Sends a request and hands back its whole body as one chunk:
  /// FoundationNetworking has no byte stream. Streaming servers on Linux
  /// inject a transport of their own.
  public func open(_ request: URLRequest) async throws -> HTTPResponse {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw AIError.transport("The server returned a non-HTTP response.")
    }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
    let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    continuation.yield(data)
    continuation.finish()
    return HTTPResponse(head: HTTPResponseHead(status: http.statusCode, headers: headers), body: body)
  }
  #else
  /// Opens a request with URLSession's byte stream.
  public func open(_ request: URLRequest) async throws -> HTTPResponse {
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw AIError.transport("The server returned a non-HTTP response.")
    }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
    let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let pump = Task {
      do {
        var buffer = Data()
        for try await byte in bytes {
          buffer.append(byte)
          if buffer.count >= 4096 || byte == 10 {
            continuation.yield(buffer)
            buffer.removeAll(keepingCapacity: true)
          }
        }
        if !buffer.isEmpty { continuation.yield(buffer) }
        continuation.finish()
      } catch { continuation.finish(throwing: error) }
    }
    continuation.onTermination = { _ in pump.cancel() }
    return HTTPResponse(head: HTTPResponseHead(status: http.statusCode, headers: headers), body: body)
  }
  #endif
}

/// Splits byte chunks into lines, keeping empty lines (SSE event separators).
struct LineSplitter {
  private var pending = Data()
  private var lastWasCR = false

  mutating func feed(_ chunk: Data) -> [String] {
    var lines: [String] = []
    for byte in chunk {
      if byte == 10 {
        if lastWasCR { lastWasCR = false; continue }
        lines.append(flush())
      } else if byte == 13 {
        lines.append(flush())
        lastWasCR = true
      } else {
        lastWasCR = false
        pending.append(byte)
      }
    }
    return lines
  }

  mutating func finish() -> String? { pending.isEmpty ? nil : flush() }

  private mutating func flush() -> String {
    defer { pending.removeAll(keepingCapacity: true) }
    return String(decoding: pending, as: UTF8.self)
  }
}
