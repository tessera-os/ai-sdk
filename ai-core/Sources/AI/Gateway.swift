import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import ModelBoard

/// Validates requests, selects a provider backend, and performs HTTP transport.
///
/// A Gateway owns one URLSession and one Router. A generation request is
/// validated against the selected model before encoding or network activity.
/// Streaming responses are surfaced as an AsyncThrowingStream of canonical
/// events and stop automatically when the consuming task is cancelled.
public struct Gateway: Sendable {
  /// The router and ordered backend set used for generation requests.
  public var router: Router

  /// The URLSession used for provider requests when no custom transport is set.
  public var session: URLSession

  /// Replaces URLSession as the network layer, mainly for tests.
  public var transport: (any HTTPTransport)?

  /// Timeout and opt-in retry settings.
  public var resilience: Resilience

  /// How candidate routes are tried and retried. Defaults to `RetryStrategy`.
  public var strategy: any RouteStrategy

  /// Creates a gateway from ordered backends and an optional runtime catalog.
  ///
  /// - Parameters:
  ///   - backends: Candidate provider backends, in routing preference order.
  ///   - catalog: Application-specific model endpoint bindings.
  ///   - session: The URLSession used for HTTP requests. Defaults to the shared session.
  ///   - transport: Optional network layer that replaces the session.
  ///   - resilience: Timeout and opt-in retry settings.
  ///   - strategy: Route selection and failover. The default uses the first
  ///     matching backend; AIGateway offers key-pool rotation.
  public init(
    backends: [any AIBackend], catalog: RemoteCatalog = RemoteCatalog(),
    session: URLSession = .shared, transport: (any HTTPTransport)? = nil,
    resilience: Resilience = Resilience(), strategy: any RouteStrategy = RetryStrategy()
  ) {
    self.strategy = strategy
    self.router = Router(backends: backends, catalog: catalog)
    self.session = session
    self.transport = transport
    self.resilience = resilience
  }

  /// Creates a gateway from a preconfigured router.
  ///
  /// - Parameters:
  ///   - router: The router that selects a backend for each model.
  ///   - session: The URLSession used for HTTP requests.
  ///   - transport: Optional network layer that replaces the session.
  ///   - resilience: Timeout and opt-in retry settings.
  public init(
    router: Router, session: URLSession = .shared, transport: (any HTTPTransport)? = nil,
    resilience: Resilience = Resilience(), strategy: any RouteStrategy = RetryStrategy()
  ) {
    self.strategy = strategy
    self.router = router
    self.session = session
    self.transport = transport
    self.resilience = resilience
  }

  /// Sends a non-streaming request and returns the decoded response.
  ///
  /// The request is capability-checked and routed before the HTTP request is
  /// sent. Transient failures are retried when the retry policy opts in.
  ///
  /// - Parameter request: The canonical request to generate.
  /// - Returns: The model response, including output, usage, and finish reason.
  /// - Throws: AIError when validation, routing, transport, or decoding fails,
  ///   or CancellationError when the calling task is cancelled.
  public func generate(_ request: Request) async throws -> Response {
    try await generateWithExchange(request).response
  }

  /// Generates a response and returns a redacted HTTP exchange for diagnostics.
  ///
  /// The exchange describes the final attempt. Known credential headers are
  /// redacted before the exchange is returned.
  ///
  /// - Parameter request: The canonical request to generate.
  /// - Returns: The decoded response and its captured HTTP exchange.
  /// - Throws: AIError when validation, routing, transport, or decoding fails,
  ///   or CancellationError when the calling task is cancelled.
  public func generateWithExchange(_ request: Request) async throws -> (
    response: Response, exchange: Exchange
  ) {
    if let issue = validate(request) { throw issue }
    let routes = try router.candidates(for: request.model)
    let context = self
    return try await executeWithResilience(
      routes: routes, resilience: resilience, strategy: strategy
    ) { route in
      try await context.attemptGenerate(route: route, request: request)
    }
  }

  /// Streams canonical events as the provider sends them.
  ///
  /// Text, reasoning, and tool-call updates arrive as typed events. A terminal
  /// completed event carries the assembled response. A whole-document response
  /// from a service that ignored the stream request is expanded into the same
  /// event shape. Failures before the first event are retried like generate;
  /// once an event has been delivered, a failure ends the stream.
  ///
  /// Cancelling the task that consumes the sequence cancels the underlying request.
  ///
  /// - Parameter request: A request whose selected model supports streaming.
  /// - Returns: An asynchronous stream of canonical response events.
  /// - Note: AIError is thrown while iterating when validation, routing,
  ///   provider decoding, or transport fails.
  public func stream(_ request: Request) -> AsyncThrowingStream<StreamEvent, any Error> {
    let (events, continuation) = AsyncThrowingStream<StreamEvent, any Error>.makeStream(
      bufferingPolicy: .unbounded)
    let producer = Task {
      do {
        try await deliverStream(request, to: continuation)
        continuation.finish()
      } catch let error as AIError {
        continuation.finish(throwing: error)
      } catch is CancellationError {
        continuation.finish(throwing: AIError.transport("The request was cancelled."))
      } catch {
        continuation.finish(throwing: AIError.wrapping(error))
      }
    }
    continuation.onTermination = { _ in producer.cancel() }
    return events
  }

  var activeTransport: any HTTPTransport { transport ?? URLSessionTransport(session: session) }

  func send(_ wire: URLRequest) async throws -> HTTPResponse {
    var wire = wire
    wire.timeoutInterval = max(resilience.timeout.total?.timeInterval ?? 3600, 1) + 5
    let transport = activeTransport
    do {
      return try await withTimeout(
        resilience.timeout.firstByte, clock: resilience.clock, error: GatewayTimeout.firstByte
      ) { [wire] in try await transport.open(wire) }
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    }
  }

  func collect(_ response: HTTPResponse) async throws -> Data {
    var data = Data()
    for try await chunk in response.body { data.append(chunk) }
    return data
  }

  /// Decodes a non-2xx response into an AttemptFailure carrying status and Retry-After.
  private func failure(
    _ response: HTTPResponse, route: Route, model: Model
  ) async -> any Error {
    let head = response.head
    let retryAfter = RetryAfter(header: head.value(for: "Retry-After"), now: await resilience.clock.now())?.delay
    do {
      let body = try await collect(response)
      _ = try route.backend.decode(status: head.status, body: body, model: model)
      return AttemptFailure(error: .status(head.status), status: head.status, retryAfter: retryAfter)
    } catch let error as AIError {
      return AttemptFailure(error: error, status: head.status, retryAfter: retryAfter)
    } catch { return error }
  }

  fileprivate func attemptGenerate(route: Route, request: Request) async throws -> (
    response: Response, exchange: Exchange
  ) {
    let wire = try route.backend.encode(modelID: route.remoteID.id, request: request, stream: false)
    var exchange = Exchange(request: wire, modelID: route.remoteID.id)
    let response = try await send(wire)
    let head = response.head
    exchange.status = head.status
    exchange.responseHeaders = head.headers
    if !(200..<300).contains(head.status) {
      let error = await failure(response, route: route, model: request.model)
      throw error
    }
    let body = try await collect(response)
    exchange.responseBody = body
    let decoded =
      isEventStream(head: head, body: body)
      ? try fold(events: body, backend: route.backend, model: request.model)
      : try route.backend.decode(status: head.status, body: body, model: request.model)
    return (decoded, exchange)
  }

  /// Whether a complete body is an event stream: labelled so, or, since some
  /// subscription endpoints stream without the label, starting with an
  /// event-stream field instead of a JSON document.
  private func isEventStream(head: HTTPResponseHead, body: Data) -> Bool {
    if head.value(for: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true { return true }
    let start = String(decoding: body.prefix(16), as: UTF8.self).drop { $0.isWhitespace }
    return ["event:", "data:", "id:", ":"].contains { start.hasPrefix($0) }
  }

  /// Folds a complete event-stream body into one response.
  ///
  /// Some backends, such as subscription endpoints, answer every request as a
  /// stream; a non-streaming call still gets one finished response.
  private func fold(events body: Data, backend: any AIBackend, model: Model) throws -> Response {
    var parser = ServerSentEventParser()
    var splitter = LineSplitter()
    var assembly = StreamAssembly(model: model)
    var response: Response?
    func take(_ produced: [StreamEvent]) throws {
      for event in produced {
        switch event {
        case .completed(let finished): response = finished
        case .failed(let error): throw error
        default: continue
        }
      }
    }
    func handle(_ line: String) throws {
      guard let event = parser.consume(line) else { return }
      try take(try backend.decodeEvent(event, assembly: &assembly))
    }
    for line in splitter.feed(body) { try handle(line) }
    if let line = splitter.finish() { try handle(line) }
    if !assembly.isFinished, let event = parser.finish() {
      try take(try backend.decodeEvent(event, assembly: &assembly))
    }
    if response == nil { try take(try assembly.complete()) }
    if let response { return response }
    throw AIError.malformed("The event stream ended without a response.")
  }

  private func deliverStream(
    _ request: Request,
    to continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
  ) async throws {
    if !request.model.capabilities.streaming { throw AIError.unsupportedCapability("streaming") }
    if let issue = validate(request) { throw issue }
    let routes = try router.candidates(for: request.model)
    let context = self
    try await executeWithResilience(routes: routes, resilience: resilience, strategy: strategy) {
      route in
      try await context.attemptStream(route: route, request: request, to: continuation)
    }
  }

  /// Streams one attempt; failures after the first delivered event become non-retryable.
  fileprivate func attemptStream(
    route: Route, request: Request,
    to continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
  ) async throws {
    var committed = false
    do {
      try await pumpStream(route: route, request: request, to: continuation, committed: &committed)
    } catch is CancellationError {
      throw CancellationError()
    } catch where committed {
      let aiError = (error as? AIError) ?? .wrapping(error)
      throw AttemptFailure(error: aiError, isCommitted: true)
    }
  }

  private func pumpStream(
    route: Route, request: Request,
    to continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation,
    committed: inout Bool
  ) async throws {
    let wire = try route.backend.encode(modelID: route.remoteID.id, request: request, stream: true)
    let response = try await send(wire)
    let head = response.head
    if !(200..<300).contains(head.status) {
      throw await failure(response, route: route, model: request.model)
    }
    func emit(_ event: StreamEvent) {
      committed = true
      continuation.yield(event)
    }

    let contentType = head.value(for: "Content-Type")?.lowercased() ?? ""
    if !contentType.hasPrefix("text/event-stream") {
      let body = try await collect(response)
      let result =
        isEventStream(head: head, body: body)
        ? try fold(events: body, backend: route.backend, model: request.model)
        : try route.backend.decode(status: head.status, body: body, model: request.model)
      for event in eventsOf(result) { emit(event) }
      return
    }

    var parser = ServerSentEventParser()
    var splitter = LineSplitter()
    var assembly = StreamAssembly(model: request.model)
    func handle(_ line: String) throws {
      guard let event = parser.consume(line) else { return }
      for produced in try route.backend.decodeEvent(event, assembly: &assembly) { emit(produced) }
    }
    for try await chunk in response.body {
      for line in splitter.feed(chunk) {
        try handle(line)
        if assembly.isFinished { return }
      }
    }
    if let line = splitter.finish() { try handle(line) }
    if !assembly.isFinished, let event = parser.finish() {
      for produced in try route.backend.decodeEvent(event, assembly: &assembly) { emit(produced) }
    }
    if !assembly.isFinished {
      assembly.finishReason = .completed
      for event in try assembly.complete() { emit(event) }
    }
  }
}
