import AI
import Foundation
import Testing

@testable import AIAnthropic
import ModelBoard

private let model = Model(
  identity: ModelIdentity(provider: .anthropic, family: .claude, variant: .fable, version: "5.6"),
  capabilities: ModelCapabilities(streaming: true, structuredOutput: true),
  remoteIDs: [RemoteModelID(service: .anthropic, protocol: .anthropic, region: .global, id: "claude-test")])

private let schema = Schema(.object(["type": .string("object")]))

private func document(_ request: Request, stream: Bool = false) throws -> [String: JSONValue] {
  guard case .object(let doc) = try anthropicDocument(modelID: "claude-test", request: request, stream: stream)
  else { throw AIError.malformed("not an object") }
  return doc
}

@Suite struct StructuredOutputTests {
  @Test func schemaIsEncodedAsOutputConfigFormat() throws {
    let doc = try document(Request(model: model, messages: [.user(text: "hi")], outputSchema: schema))
    #expect(
      doc["output_config"]
        == .object(["format": .object(["type": .string("json_schema"), "schema": schema.json])]))
  }

  @Test func capabilityAndEncoderAgree() throws {
    let request = Request(model: model, messages: [.user(text: "hi")], outputSchema: schema)
    #expect(validate(request) == nil)  // model declares structuredOutput
    _ = try document(request)  // and the encoder no longer rejects it
  }

  @Test func noSchemaMeansNoOutputConfig() throws {
    #expect(try document(Request(model: model, messages: [.user(text: "hi")]))["output_config"] == nil)
  }

  @Test func jsonTextResponseDecodesAsText() throws {
    let body = #"{"type":"message","content":[{"type":"text","text":"{\"a\":1}"}],"stop_reason":"end_turn"}"#
    let response = try AnthropicBackend(apiKey: "k").decode(status: 200, body: Data(body.utf8), model: model)
    #expect(response.output == [.text(TextPart(#"{"a":1}"#))])
  }
}

@Suite struct ProviderOptionsPrecedenceTests {
  @Test func providerOptionsCannotOverwriteCoreFields() throws {
    let hostile: JSONValue = .object([
      "model": .string("evil"), "messages": .array([]), "max_tokens": .integer(1),
      "system": .string("evil"), "tools": .array([]), "stream": .bool(false),
      "thinking": .object(["type": .string("enabled")]),
    ])
    let request = Request(
      model: model, messages: [.user(text: "hi")], instructions: "core", maxTokens: 99, caching: nil,
      providerOptions: hostile)
    let doc = try document(request, stream: true)
    #expect(doc["model"] == .string("claude-test"))
    #expect(doc["max_tokens"] == .integer(99))
    #expect(doc["system"] == .string("core"))
    #expect(doc["stream"] == .bool(true))
    #expect(doc["tools"] == nil)
    if case .array(let messages)? = doc["messages"] { #expect(messages.count == 1) } else { Issue.record("messages") }
    #expect(doc["thinking"] != nil)
  }

  @Test func providerOptionsCannotReplaceOutputConfigWhenSchemaSet() throws {
    let request = Request(
      model: model, messages: [.user(text: "hi")], outputSchema: schema,
      providerOptions: .object(["output_config": .string("evil")]))
    #expect(try document(request)["output_config"] != .string("evil"))
  }
}

@Suite struct StreamErrorTests {
  private func decode(_ data: String) throws -> [StreamEvent] {
    var assembly = StreamAssembly(model: model)
    return try AnthropicBackend(apiKey: "k").decodeEvent(
      ServerSentEvent(event: "error", data: data), assembly: &assembly)
  }

  @Test func overloadedErrorIsTyped() {
    let data = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
    #expect(throws: AIError.service(ServiceFailure(status: 529, kind: "overloaded_error", message: "Overloaded"))) {
      try decode(data)
    }
  }

  @Test func typeMapsToStatus() {
    let data = #"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#
    #expect(throws: AIError.service(ServiceFailure(status: 429, kind: "rate_limit_error", message: "slow"))) {
      try decode(data)
    }
  }

  @Test func errorNeverReportsStatus200() {
    #expect(throws: AIError.service(ServiceFailure(status: 500, kind: "weird", message: "Anthropic reported a weird error."))) {
      try decode(#"{"type":"error","error":{"type":"weird"}}"#)
    }
  }
}

private actor FakeTransport: HTTPTransport {
  private var bodies: [String]
  private(set) var seenBodies: [Data] = []

  init(_ bodies: [String]) { self.bodies = bodies }

  func open(_ request: URLRequest) async throws -> HTTPResponse {
    seenBodies.append(request.httpBody ?? Data())
    let sse = bodies.count > 1 ? bodies.removeFirst() : bodies[0]
    let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    continuation.yield(Data(sse.utf8))
    continuation.finish()
    return HTTPResponse(
      head: HTTPResponseHead(status: 200, headers: ["Content-Type": "text/event-stream"]),
      body: body)
  }
}

private struct ImmediateClock: ResilienceClock {
  func sleep(for duration: Duration) async throws {}
  func now() async -> Date { Date() }
  func randomUnit() async -> Double { 0 }
}

@Suite struct GatewayIntegrationTests {
  private let overloaded =
    "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
  private let good =
    "event: message_start\ndata: {\"message\":{\"model\":\"m\",\"usage\":{\"input_tokens\":1}}}\n\n"
    + "event: content_block_start\ndata: {\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
    + "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n"
    + "event: content_block_stop\ndata: {\"index\":0}\n\n"
    + "event: message_stop\ndata: {}\n\n"

  @Test func overloadedInsideA200StreamIsRetried() async throws {
    let transport = FakeTransport([overloaded, good])
    let clock = ImmediateClock()
    let gateway = Gateway(
      backends: [AnthropicBackend(apiKey: "k")], transport: transport,
      resilience: Resilience(retry: RetryPolicy(), timeout: .none, clock: clock))
    var text = ""
    for try await event in gateway.stream(Request(model: model, messages: [.user(text: "hi")])) {
      if case .textDelta(let part) = event { text += part.text }
    }
    #expect(text == "hi")
    #expect(await transport.seenBodies.count == 2)
  }

  @Test func overloadedWithRetriesExhaustedSurfacesTypedError() async {
    let transport = FakeTransport([overloaded])
    let clock = ImmediateClock()
    let gateway = Gateway(
      backends: [AnthropicBackend(apiKey: "k")], transport: transport,
      resilience: Resilience(retry: .none, timeout: .none, clock: clock))
    await #expect(throws: AIError.service(ServiceFailure(status: 529, kind: "overloaded_error", message: "Overloaded"))) {
      for try await _ in gateway.stream(Request(model: model, messages: [.user(text: "hi")])) {}
    }
  }
}
