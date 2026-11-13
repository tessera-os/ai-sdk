import AI
import Foundation
import ModelBoard

/// One scripted transport outcome.
enum Step: Sendable {
  case body(Int, [String: String], String)
  case sse(Int, [String])
  case fail(URLError.Code)
  case hang
}

/// A transport that replays steps (in order, or per key) and records each request's key header.
actor ScriptedTransport: HTTPTransport {
  private var steps: [Step]
  private var byKey: [String: [Step]]
  private(set) var requestedKeys: [String] = []

  init(_ steps: [Step]) {
    self.steps = steps
    self.byKey = [:]
  }

  init(byKey: [String: [Step]]) {
    self.steps = []
    self.byKey = byKey
  }

  private func next(key: String) -> Step {
    requestedKeys.append(key)
    if let queue = byKey[key], !queue.isEmpty {
      if queue.count > 1 { byKey[key]?.removeFirst() }
      return queue[0]
    }
    if steps.count > 1 { return steps.removeFirst() }
    return steps[0]
  }

  func open(_ request: URLRequest) async throws -> HTTPResponse {
    switch next(key: request.value(forHTTPHeaderField: "x-key") ?? "") {
    case .body(let status, let headers, let text):
      return respond(status, headers, [text])
    case .sse(let status, let chunks):
      return respond(status, ["Content-Type": "text/event-stream"], chunks)
    case .fail(let code): throw URLError(code)
    case .hang:
      try await Task.sleep(for: .seconds(3600))
      throw URLError(.timedOut)
    }
  }

  private func respond(_ status: Int, _ headers: [String: String], _ chunks: [String])
    -> HTTPResponse
  {
    let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
    continuation.finish()
    return HTTPResponse(head: HTTPResponseHead(status: status, headers: headers), body: body)
  }
}

/// A clock that never waits: sleeps are recorded and return at once.
///
/// Sleeps of exactly `holding` model a timeout timer: they stay pending until
/// `fireTimers()` releases one, so a test controls which attempt times out.
actor TestClock: ResilienceClock {
  private(set) var sleeps: [Duration] = []
  private var date: Date
  private let random: Double
  private let holding: Duration?
  private var pendingFires = 0

  init(date: Date = Date(timeIntervalSince1970: 1000), random: Double = 0, holding: Duration? = nil) {
    self.date = date
    self.random = random
    self.holding = holding
  }

  func sleep(for duration: Duration) async throws {
    sleeps.append(duration)
    guard duration == holding else { return }
    while pendingFires == 0 { try await Task.sleep(for: .milliseconds(1)) }
    pendingFires -= 1
  }

  func now() -> Date { date }
  func randomUnit() -> Double { random }
  func advance(to newDate: Date) { date = newDate }
  func fireTimers() { pendingFires += 1 }
}

/// A minimal backend: the key goes in x-key; failures decode to a service error.
struct TestBackend: AIBackend {
  var key: String
  var service: Service { .custom }
  var apiProtocol: AIProtocol { .custom }
  var region: Region? { .global }

  func encode(modelID: String, request: Request, stream: Bool) throws -> URLRequest {
    var wire = URLRequest(url: URL(string: "https://example.test/v1")!)
    wire.httpMethod = "POST"
    wire.setValue(key, forHTTPHeaderField: "x-key")
    return wire
  }

  func decode(status: Int, body: Data, model: Model) throws -> Response {
    let text = String(decoding: body, as: UTF8.self)
    guard (200..<300).contains(status) else {
      let kind = text.contains("overloaded") ? "overloaded_error" : nil
      throw AIError.service(ServiceFailure(status: status, kind: kind, message: text))
    }
    return Response(model: model, output: [.text(TextPart(text))], finishReason: .completed)
  }

  func decodeEvent(_ event: ServerSentEvent, assembly: inout StreamAssembly) throws
    -> [StreamEvent]
  {
    switch event.event {
    case "text": return assembly.appendText(event.data)
    case "done": return try assembly.complete()
    case "error":
      throw AIError.service(
        ServiceFailure(status: 529, kind: "overloaded_error", message: event.data))
    default: return []
    }
  }
}

let testModel = Model(
  identity: ModelIdentity(provider: .anthropic, family: .claude, version: "test"),
  capabilities: ModelCapabilities(streaming: true),
  remoteIDs: [RemoteModelID(service: .custom, protocol: .custom, region: .global, id: "m")])

let testRequest = Request(model: testModel, messages: [.user(text: "hi")])

func gateway(
  _ backends: [TestBackend], transport: ScriptedTransport,
  retry: RetryPolicy = RetryPolicy(), timeout: TimeoutPolicy = .none,
  clock: any ResilienceClock
) -> Gateway {
  Gateway(
    backends: backends, transport: transport,
    resilience: Resilience(retry: retry, timeout: timeout, clock: clock))
}
