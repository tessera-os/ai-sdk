import AI
import Foundation
import Testing

@testable import AIOpenAI
import ModelBoard

private func makeModel(reasoning: Bool = true) -> Model {
  Model(
    identity: ModelIdentity(provider: .openAI, family: .gpt, version: "5"),
    capabilities: ModelCapabilities(
      streaming: true, toolCalling: true, structuredOutput: true, reasoning: reasoning),
    remoteIDs: [RemoteModelID(service: .openAI, protocol: .openAI, region: .global, id: "gpt-5")])
}

private let weather = Tool(
  name: "weather", description: "Gets weather.", inputSchema: Schema(.object(["type": .string("object")])))

private func fields(_ value: JSONValue?) -> [String: JSONValue] {
  if case .object(let object)? = value { return object }
  return [:]
}

private func wire(
  _ request: Request, modelID: String = "gpt-5", stream: Bool = true,
  endpoint: OpenAIEndpoint = .automatic
) throws -> (path: String, doc: [String: JSONValue]) {
  let built = try OpenAIBackend(apiKey: "k", endpoint: endpoint).encode(
    modelID: modelID, request: request, stream: stream)
  return (built.url?.path ?? "", fields(try JSONValue.parse(built.httpBody ?? Data())))
}

/// Replays one scripted SSE body or JSON body for every request and records request bodies.
private actor Script: HTTPTransport {
  private(set) var bodies: [Data] = []
  private(set) var urls: [String] = []
  private var replies: [(String, Bool)]

  init(sse: [String]) { replies = sse.map { ($0, true) } }
  init(json: [String]) { replies = json.map { ($0, false) } }
  /// Event streams sent with a JSON label, as some subscription endpoints do.
  init(unlabelledSSE: [String]) { replies = unlabelledSSE.map { ($0, false) } }

  func open(_ request: URLRequest) async throws -> HTTPResponse {
    bodies.append(request.httpBody ?? Data())
    urls.append(request.url?.absoluteString ?? "")
    let (text, isStream) = replies.count > 1 ? replies.removeFirst() : replies[0]
    let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    continuation.yield(Data(text.utf8))
    continuation.finish()
    let headers = ["Content-Type": isStream ? "text/event-stream" : "application/json"]
    return HTTPResponse(head: HTTPResponseHead(status: 200, headers: headers), body: body)
  }
}

private func event(_ type: String, _ json: String) -> String {
  "event: \(type)\ndata: {\"type\":\"\(type)\",\(json)}\n\n"
}

@Suite struct OpenAIEndpointSelectionTests {
  @Test func reasoningModelsUseResponsesAndOthersUseChat() throws {
    let plain = makeModel(reasoning: false)
    for id in ["gpt-5", "gpt-5.6-sol", "gpt-6-luna", "o3", "o4-mini", "codex-mini"] {
      let request = Request(model: plain, messages: [.user(text: "hi")])
      #expect(try wire(request, modelID: id).path == "/v1/responses", "\(id)")
    }
    for id in ["gpt-4.1", "gpt-4o", "gpt-oss-120b"] {
      let request = Request(model: plain, messages: [.user(text: "hi")])
      #expect(try wire(request, modelID: id).path == "/v1/chat/completions", "\(id)")
    }
  }

  @Test func capabilityAndExplicitEndpointOverrideTheName() throws {
    let reasoning = Request(model: makeModel(reasoning: true), messages: [.user(text: "hi")])
    #expect(try wire(reasoning, modelID: "gpt-4.1").path == "/v1/responses")
    #expect(try wire(reasoning, endpoint: .chatCompletions).path == "/v1/chat/completions")
    let plain = Request(model: makeModel(reasoning: false), messages: [.user(text: "hi")])
    #expect(try wire(plain, modelID: "gpt-4.1", endpoint: .responses).path == "/v1/responses")
  }
}

@Suite struct OpenAIResponsesEncodingTests {
  @Test func typedOptionsMapToResponsesFields() throws {
    let request = Request(
      model: makeModel(), messages: [.user(text: "hi")], instructions: "be brief", tools: [weather],
      maxTokens: 500, outputSchema: Schema(.object(["type": .string("object")]), name: "answer", strict: true),
      toolChoice: .tool(named: "weather"), reasoningEffort: .max,
      caching: PromptCaching(key: "conv-1"))
    let doc = try wire(request).doc
    #expect(doc["store"] == .bool(false))
    #expect(doc["stream"] == .bool(true))
    #expect(doc["instructions"] == .string("be brief"))
    #expect(doc["max_output_tokens"] == .integer(500))
    #expect(doc["reasoning"] == .object(["effort": .string("max"), "summary": .string("auto")]))
    #expect(doc["include"] == .array([.string("reasoning.encrypted_content")]))
    #expect(doc["prompt_cache_key"] == .string("conv-1"))
    #expect(doc["tool_choice"] == .object(["type": .string("function"), "name": .string("weather")]))
    #expect(
      doc["tools"]
        == .array([
          .object([
            "type": .string("function"), "name": .string("weather"),
            "description": .string("Gets weather."),
            "parameters": .object(["type": .string("object")]),
          ])
        ]))
    #expect(
      doc["text"]
        == .object([
          "format": .object([
            "type": .string("json_schema"), "name": .string("answer"),
            "schema": .object(["type": .string("object")]), "strict": .bool(true),
          ])
        ]))
    #expect(doc["messages"] == nil)
  }

  @Test func toolChoiceSimpleCases() throws {
    for (choice, wireValue) in [
      (ToolChoice.auto, "auto"), (.disabled, "none"), (.required, "required"),
    ] {
      let request = Request(
        model: makeModel(), messages: [.user(text: "hi")], tools: [weather], toolChoice: choice)
      #expect(try wire(request).doc["tool_choice"] == .string(wireValue))
    }
  }

  @Test func budgetIsRejectedBecauseOpenAIHasNone() {
    let request = Request(
      model: makeModel(), messages: [.user(text: "hi")], reasoningEffort: .budget(2000))
    #expect(throws: AIError.unsupportedCapability("reasoning token budget")) { try wire(request) }
  }

  @Test func typedFieldsBeatProviderOptions() throws {
    let request = Request(
      model: makeModel(), messages: [.user(text: "hi")], reasoningEffort: .low,
      providerOptions: .object([
        "store": .bool(true), "reasoning": .string("evil"), "include": .array([.string("file_search_call.results")]),
        "temperature": .number(0.1),
      ]))
    let doc = try wire(request).doc
    #expect(doc["store"] == .bool(false))
    #expect(doc["reasoning"] != .string("evil"))
    #expect(
      doc["include"]
        == .array([.string("reasoning.encrypted_content"), .string("file_search_call.results")]))
    #expect(doc["temperature"] != nil)
  }

  @Test func historyReplaysOwnEncryptedReasoningWithoutIdentifiers() throws {
    let history: [Message] = [
      .user(text: "weather?"),
      .assistant([
        .reasoning(Reasoning(text: "thinking", signature: "enc-1", source: .openAI)),
        .reasoning(Reasoning(text: "foreign", signature: "sig", source: .anthropic)),
        .text(TextPart("Let me check.")),
        .call(ToolCall(id: "call_1", name: "weather", input: .object(["city": .string("Oslo")]))),
      ]),
      .toolResults([ToolResult(id: "call_1", output: .string("rain"))]),
    ]
    let doc = try wire(Request(model: makeModel(), messages: history)).doc
    guard case .array(let input)? = doc["input"] else { Issue.record("input"); return }
    #expect(input.count == 5)
    #expect(fields(input[0])["role"] == .string("user"))
    let reasoning = fields(input[1])
    #expect(reasoning["type"] == .string("reasoning"))
    #expect(reasoning["encrypted_content"] == .string("enc-1"))
    #expect(reasoning["id"] == nil)
    #expect(fields(input[2])["type"] == .string("message"))
    #expect(fields(input[3])["call_id"] == .string("call_1"))
    #expect(fields(input[3])["arguments"] == .string(#"{"city":"Oslo"}"#))
    #expect(fields(input[4])["type"] == .string("function_call_output"))
    #expect(fields(input[4])["output"] == .string("rain"))
  }

  @Test func audioInputIsRejected() {
    let request = Request(
      model: makeModel(),
      messages: [.user([.audio(AudioPart(mediaType: "audio/wav", data: Data()))])])
    #expect(throws: AIError.unsupportedInputModality(.audio)) { try wire(request) }
  }
}

@Suite struct OpenAIResponsesStreamTests {
  private var stream: String {
    event("response.created", #""response":{"id":"resp_1","model":"gpt-5-2026"}"#)
      + event("response.output_item.added", #""output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}"#)
      + event("response.reasoning_summary_part.added", #""item_id":"rs_1","summary_index":0"#)
      + event("response.reasoning_summary_text.delta", #""item_id":"rs_1","summary_index":0,"delta":"Check data""#)
      + event("response.reasoning_summary_part.added", #""item_id":"rs_1","summary_index":1"#)
      + event("response.reasoning_summary_text.delta", #""item_id":"rs_1","summary_index":1,"delta":"Then answer""#)
      + event("response.output_item.done", #""output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"ENC"}"#)
      + event("response.output_item.added", #""output_index":1,"item":{"type":"message","id":"msg_1"}"#)
      + event("response.output_text.delta", #""item_id":"msg_1","content_index":0,"delta":"Hel""#)
      + event("response.output_text.delta", #""item_id":"msg_1","content_index":0,"delta":"lo""#)
      + event("response.output_item.done", #""output_index":1,"item":{"type":"message","id":"msg_1"}"#)
      + event("response.output_item.added", #""output_index":2,"item":{"type":"function_call","id":"fc_1","call_id":"call_9","name":"weather","arguments":""}"#)
      + event("response.function_call_arguments.delta", #""item_id":"fc_1","delta":"{\"city\":""#)
      + event("response.function_call_arguments.delta", #""item_id":"fc_1","delta":"\"Oslo\"}""#)
      + event("response.output_item.done", #""output_index":2,"item":{"type":"function_call","id":"fc_1","call_id":"call_9","name":"weather","arguments":"{\"city\":\"Oslo\"}"}"#)
      + event(
        "response.completed",
        #""response":{"status":"completed","usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":64},"output_tokens":30,"output_tokens_details":{"reasoning_tokens":12}}}"#)
  }

  @Test func eventsSurfaceReasoningTextToolCallAndUsage() async throws {
    let transport = Script(sse: [stream])
    let gateway = Gateway(backends: [OpenAIBackend(apiKey: "k")], transport: transport)
    let request = Request(model: makeModel(), messages: [.user(text: "hi")], tools: [weather], reasoningEffort: .high)
    var events: [StreamEvent] = []
    for try await event in gateway.stream(request) { events.append(event) }
    #expect(await transport.urls == ["https://api.openai.com/v1/responses"])
    #expect(events.contains(.reasoningStart))
    #expect(events.contains(.reasoningDelta(Reasoning(text: "Check data"))))
    #expect(events.contains(.reasoningEnd))
    #expect(events.contains(.textDelta(TextPart("Hel"))))
    #expect(events.contains(.toolCallStart(ToolCallOpened(id: "call_9", name: "weather"))))
    guard case .completed(let response)? = events.last else { Issue.record("no completion"); return }
    #expect(
      response.output == [
        .reasoning(Reasoning(text: "Check data\n\nThen answer", signature: "ENC", source: .openAI)),
        .text(TextPart("Hello")),
        .call(ToolCall(id: "call_9", name: "weather", input: .object(["city": .string("Oslo")]))),
      ])
    #expect(response.finishReason == .toolCall)
    #expect(response.servedModel == "gpt-5-2026")
    #expect(response.usage == Usage(inputTokens: 100, outputTokens: 30, cacheReadTokens: 64, reasoningTokens: 12))
  }

  @Test func encryptedReasoningRoundTripsIntoTheNextTurn() async throws {
    let transport = Script(sse: [stream])
    let gateway = Gateway(backends: [OpenAIBackend(apiKey: "k")], transport: transport)
    var first = Request(model: makeModel(), messages: [.user(text: "hi")], tools: [weather], reasoningEffort: .high)
    var completed: Response?
    for try await case .completed(let response) in gateway.stream(first) { completed = response }
    guard let completed else { Issue.record("no response"); return }
    first.messages += [
      .assistant(completed.output),
      .toolResults([ToolResult(id: "call_9", output: .string("rain"))]),
    ]
    for try await _ in gateway.stream(first) {}
    let second = fields(try JSONValue.parse(await transport.bodies[1]))
    guard case .array(let input)? = second["input"] else { Issue.record("input"); return }
    let reasoning = input.map(fields).first { $0["type"] == .string("reasoning") }
    #expect(reasoning?["encrypted_content"] == .string("ENC"))
    #expect(second["store"] == .bool(false))
  }

  @Test func incompleteMapsToLengthAndFailureToServiceError() async throws {
    let truncated = event("response.output_text.delta", #""item_id":"m","delta":"a""#)
      + event("response.incomplete", #""response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":1,"output_tokens":2}}"#)
    let gateway = Gateway(backends: [OpenAIBackend(apiKey: "k")], transport: Script(sse: [truncated]))
    var finish: FinishReason?
    for try await case .completed(let response) in gateway.stream(Request(model: makeModel(), messages: [.user(text: "hi")])) {
      finish = response.finishReason
    }
    #expect(finish == .length)

    let failed = event("response.failed", #""response":{"status":"failed","error":{"code":"rate_limit_exceeded","message":"slow"}}"#)
    let failing = Gateway(
      backends: [OpenAIBackend(apiKey: "k")], transport: Script(sse: [failed]),
      resilience: Resilience(retry: .none, timeout: .none))
    await #expect(throws: AIError.service(ServiceFailure(status: 429, kind: "rate_limit_exceeded", message: "slow"))) {
      for try await _ in failing.stream(Request(model: makeModel(), messages: [.user(text: "hi")])) {}
    }
  }

  @Test func wholeDocumentResponseDecodes() async throws {
    let body = """
      {"id":"resp_1","object":"response","status":"completed","model":"gpt-5",
      "output":[{"type":"reasoning","id":"rs","summary":[{"type":"summary_text","text":"why"}],"encrypted_content":"ENC"},
      {"type":"message","content":[{"type":"output_text","text":"hi"}]}],
      "usage":{"input_tokens":3,"output_tokens":4,"input_tokens_details":{"cached_tokens":1},"output_tokens_details":{"reasoning_tokens":2}}}
      """
    let gateway = Gateway(backends: [OpenAIBackend(apiKey: "k")], transport: Script(json: [body]))
    let response = try await gateway.generate(Request(model: makeModel(), messages: [.user(text: "hi")]))
    #expect(
      response.output == [
        .reasoning(Reasoning(text: "why", signature: "ENC", source: .openAI)), .text(TextPart("hi")),
      ])
    #expect(response.usage == Usage(inputTokens: 3, outputTokens: 4, cacheReadTokens: 1, reasoningTokens: 2))
    #expect(response.finishReason == .completed)
  }

  @Test func generateFoldsAStreamedAnswer() async throws {
    let gateway = Gateway(backends: [OpenAIBackend(apiKey: "k")], transport: Script(sse: [stream]))
    let response = try await gateway.generate(
      Request(model: makeModel(), messages: [.user(text: "hi")], tools: [weather]))
    #expect(
      response.output == [
        .reasoning(Reasoning(text: "Check data\n\nThen answer", signature: "ENC", source: .openAI)),
        .text(TextPart("Hello")),
        .call(ToolCall(id: "call_9", name: "weather", input: .object(["city": .string("Oslo")]))),
      ])
    #expect(response.finishReason == .toolCall)
    #expect(response.usage == Usage(inputTokens: 100, outputTokens: 30, cacheReadTokens: 64, reasoningTokens: 12))
  }

  @Test func unlabelledEventStreamsAreFolded() async throws {
    let gateway = Gateway(backends: [OpenAIBackend(apiKey: "k")], transport: Script(unlabelledSSE: [stream, stream]))
    let request = Request(model: makeModel(), messages: [.user(text: "hi")], tools: [weather])
    let generated = try await gateway.generate(request)
    #expect(generated.output.contains(.text(TextPart("Hello"))))
    var streamed: Response?
    for try await case .completed(let response) in gateway.stream(request) { streamed = response }
    #expect(streamed?.output.contains(.text(TextPart("Hello"))) == true)
  }
}

@Suite struct OpenAIChatOptionTests {
  private let plain = makeModel(reasoning: false)

  @Test func chatCompletionsGetsToolChoiceEffortCacheKeyAndStrictSchema() throws {
    let request = Request(
      model: plain, messages: [.user(text: "hi")], tools: [weather],
      outputSchema: Schema(.object(["type": .string("object")]), name: "answer", strict: true),
      toolChoice: .tool(named: "weather"), reasoningEffort: .medium, caching: PromptCaching(key: "k1"))
    let built = try wire(request, modelID: "gpt-4.1", stream: false)
    #expect(built.path == "/v1/chat/completions")
    #expect(built.doc["reasoning_effort"] == .string("medium"))
    #expect(built.doc["prompt_cache_key"] == .string("k1"))
    #expect(
      built.doc["tool_choice"]
        == .object(["type": .string("function"), "function": .object(["name": .string("weather")])]))
    let format = fields(fields(built.doc["response_format"])["json_schema"])
    #expect(format["name"] == .string("answer"))
    #expect(format["strict"] == .bool(true))
  }

  @Test func compatibleBackendsIgnoreEffortAndCacheKeyByDefault() throws {
    let request = Request(
      model: plain, messages: [.user(text: "hi")], toolChoice: .required, reasoningEffort: .high,
      caching: PromptCaching(key: "k1"))
    let built = try OpenAICompatibleBackend(baseURL: "https://x.test/v1").encode(
      modelID: "m", request: request, stream: false)
    let doc = fields(try JSONValue.parse(built.httpBody ?? Data()))
    #expect(doc["reasoning_effort"] == nil)
    #expect(doc["prompt_cache_key"] == nil)
    #expect(built.url?.path == "/v1/chat/completions")
  }

  @Test func listModelsDecodesIdsAndOwners() async throws {
    let body = #"{"object":"list","data":[{"id":"gpt-5","created":1754000000,"owned_by":"system"},{"id":"o3","created":1744000000,"owned_by":"system"}]}"#
    let transport = Script(json: [body])
    let list = await Gateway(backends: [OpenAIBackend(apiKey: "k")], transport: transport).listModels()
    #expect(list.models.map(\.id) == ["gpt-5", "o3"])
    #expect(list.models[0].owner == "system")
    #expect(list.models[0].created == Date(timeIntervalSince1970: 1_754_000_000))
    #expect(await transport.urls == ["https://api.openai.com/v1/models"])
  }
}
