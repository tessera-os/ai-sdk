import AI
import Foundation
import Testing

@testable import AIAnthropic
import ModelBoard

private let model = Model(
  identity: ModelIdentity(provider: .anthropic, family: .claude, variant: .fable, version: "5.6"),
  capabilities: ModelCapabilities(streaming: true, toolCalling: true, structuredOutput: true, reasoning: true, promptCaching: true),
  remoteIDs: [RemoteModelID(service: .anthropic, protocol: .anthropic, region: .global, id: "claude-opus-4-8")])

private let weather = Tool(
  name: "weather", description: "Gets weather.", inputSchema: Schema(.object(["type": .string("object")])))

private func fields(_ value: JSONValue?) -> [String: JSONValue] {
  if case .object(let object)? = value { return object }
  return [:]
}

private func doc(_ request: Request, modelID: String = "claude-opus-4-8") throws -> [String: JSONValue] {
  fields(try anthropicDocument(modelID: modelID, request: request, stream: false))
}

private func request(
  effort: ReasoningEffort? = nil, choice: ToolChoice? = nil, caching: PromptCaching? = nil,
  maxTokens: Int? = nil, messages: [Message] = [.user(text: "hi")]
) -> Request {
  Request(
    model: model, messages: messages, instructions: "be brief", tools: [weather],
    maxTokens: maxTokens, toolChoice: choice, reasoningEffort: effort, caching: caching)
}

@Suite struct AnthropicToolChoiceTests {
  @Test func mapsEveryCase() throws {
    let cases: [(ToolChoice, JSONValue)] = [
      (.auto, .object(["type": .string("auto")])),
      (.disabled, .object(["type": .string("none")])),
      (.required, .object(["type": .string("any")])),
      (.tool(named: "weather"), .object(["type": .string("tool"), "name": .string("weather")])),
    ]
    for (choice, wire) in cases { #expect(try doc(request(choice: choice))["tool_choice"] == wire) }
  }

  @Test func absentChoiceSendsNothingAndOptionsCannotOverrideIt() throws {
    #expect(try doc(request())["tool_choice"] == nil)
    var forced = request(choice: .disabled)
    forced.providerOptions = .object(["tool_choice": .string("evil")])
    #expect(try doc(forced)["tool_choice"] == .object(["type": .string("none")]))
  }
}

@Suite struct AnthropicReasoningEffortTests {
  @Test func adaptiveModelsGetEffortAndSummarizedDisplay() throws {
    let result = try doc(request(effort: .high))
    #expect(result["thinking"] == .object(["type": .string("adaptive"), "display": .string("summarized")]))
    #expect(fields(result["output_config"])["effort"] == .string("high"))
  }

  @Test func effortMergesWithStructuredOutputConfig() throws {
    var structured = request(effort: .max)
    structured.outputSchema = Schema(.object(["type": .string("object")]))
    let config = fields(try doc(structured)["output_config"])
    #expect(config["effort"] == .string("max"))
    #expect(config["format"] != nil)
  }

  @Test func budgetOnlyModelsGetBudgetTokensAndRaisedMaxTokens() throws {
    let medium = try doc(request(effort: .medium, maxTokens: 20000), modelID: "claude-haiku-4-5")
    #expect(medium["thinking"] == .object(["type": .string("enabled"), "budget_tokens": .integer(12000)]))
    #expect(medium["max_tokens"] == .integer(20000))
    #expect(medium["output_config"] == nil)
    let small = try doc(request(effort: .high, maxTokens: 2000), modelID: "claude-haiku-4-5")
    #expect(small["thinking"] == .object(["type": .string("enabled"), "budget_tokens": .integer(1024)]))
    #expect(small["max_tokens"] == .integer(2048))
  }

  @Test func explicitBudgetIsHonouredOnAnyModel() throws {
    let result = try doc(request(effort: .budget(5000), maxTokens: 9000))
    #expect(result["thinking"] == .object(["type": .string("enabled"), "budget_tokens": .integer(5000)]))
  }

  @Test func noneDisablesThinkingExceptOnAlwaysThinkingModels() throws {
    #expect(try doc(request(effort: .off))["thinking"] == .object(["type": .string("disabled")]))
    let always = try doc(request(effort: .off), modelID: "claude-fable-5-1")
    #expect(always["thinking"] == .object(["type": .string("adaptive"), "display": .string("summarized")]))
    #expect(fields(always["output_config"])["effort"] == .string("low"))
  }

  @Test func providerThinkingOptionYieldsToTypedEffort() throws {
    var typed = request(effort: .low)
    typed.providerOptions = .object(["thinking": .string("evil")])
    #expect(try doc(typed)["thinking"] != .string("evil"))
  }
}

@Suite struct AnthropicCachingTests {
  private func isMarked(_ value: JSONValue?, ttl: String = "1h") -> Bool {
    fields(value)["cache_control"] == .object(["type": .string("ephemeral"), "ttl": .string(ttl)])
  }

  private func lastBlock(_ result: [String: JSONValue]) -> JSONValue? {
    guard case .array(let messages)? = result["messages"], let last = messages.last,
      case .array(let blocks)? = fields(last)["content"]
    else { return nil }
    return blocks.last
  }

  @Test func standardMarksSystemAndLastMessageButNotTools() throws {
    let result = try doc(request(caching: .standard))
    guard case .array(let system)? = result["system"] else { Issue.record("system"); return }
    #expect(isMarked(system.last))
    #expect(isMarked(lastBlock(result)))
    guard case .array(let tools)? = result["tools"] else { Issue.record("tools"); return }
    #expect(!isMarked(tools.last))
  }

  @Test func toolsBreakpointMarksLastTool() throws {
    let result = try doc(request(caching: PromptCaching(breakpoints: [.tools])))
    guard case .array(let tools)? = result["tools"] else { Issue.record("tools"); return }
    #expect(isMarked(tools.last))
    #expect(result["system"] == .string("be brief"))
    #expect(!isMarked(lastBlock(result)))
  }

  @Test func requestsCacheForOneHourByDefault() throws {
    let result = try doc(Request(model: model, messages: [.user(text: "hi")], instructions: "be brief"))
    guard case .array(let system)? = result["system"] else { Issue.record("system"); return }
    #expect(isMarked(system.last))
    #expect(isMarked(lastBlock(result)))
  }

  @Test func fiveMinuteLifetimeSendsFiveMinuteTTL() throws {
    let result = try doc(request(caching: PromptCaching(lifetime: .fiveMinutes)))
    #expect(isMarked(lastBlock(result), ttl: "5m"))
  }

  @Test func noCachingSendsNoMarkers() throws {
    let result = try doc(request())
    #expect(!isMarked(lastBlock(result)))
    #expect(result["system"] == .string("be brief"))
  }

  @Test func thinkingBlocksAreNeverMarked() throws {
    let history: [Message] = [
      .user(text: "hi"),
      .assistant([.reasoning(Reasoning(text: "hm", signature: "sig", source: .anthropic))]),
    ]
    #expect(!isMarked(lastBlock(try doc(request(caching: .standard, messages: history)))))
  }

  @Test func reasoningFromAnotherServiceIsNotReplayed() throws {
    let history: [Message] = [
      .user(text: "hi"),
      .assistant([
        .reasoning(Reasoning(text: "x", signature: "openai-blob", source: .openAI)),
        .reasoning(Reasoning(text: "y", signature: "sig", source: .anthropic)),
        .text(TextPart("done")),
      ]),
    ]
    guard case .array(let messages)? = try doc(request(messages: history))["messages"],
      case .array(let blocks)? = fields(messages[1])["content"]
    else { Issue.record("messages"); return }
    #expect(blocks.count == 2)
    #expect(fields(blocks[0])["signature"] == .string("sig"))
  }
}

private actor ListTransport: HTTPTransport {
  private(set) var urls: [String] = []
  private var pages: [String]
  init(_ pages: [String]) { self.pages = pages }

  func open(_ request: URLRequest) async throws -> HTTPResponse {
    urls.append(request.url?.absoluteString ?? "")
    let text = pages.count > 1 ? pages.removeFirst() : pages[0]
    let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    continuation.yield(Data(text.utf8))
    continuation.finish()
    return HTTPResponse(head: HTTPResponseHead(status: 200, headers: [:]), body: body)
  }
}

@Suite struct AnthropicModelListTests {
  private let first = """
    {"data":[{"id":"claude-opus-4-6","display_name":"Claude Opus 4.6","created_at":"2026-01-02T03:04:05Z",
    "max_input_tokens":1000000,"max_tokens":128000,"capabilities":{"image_input":{"supported":true},
    "thinking":{"supported":true,"types":{"adaptive":{"supported":true},"enabled":{"supported":false}}},
    "effort":{"supported":true,"low":{"supported":true},"high":{"supported":true},"max":{"supported":true}}}}],
    "has_more":true,"last_id":"claude-opus-4-6"}
    """
  private let second = """
    {"data":[{"id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5"}],"has_more":false,"last_id":"claude-haiku-4-5"}
    """

  @Test func gatewayFollowsPagesAndMergesCatalog() async throws {
    let transport = ListTransport([first, second])
    let gateway = Gateway(backends: [AnthropicBackend(apiKey: "k")], transport: transport)
    let list = await gateway.listModels()
    #expect(list.failures.isEmpty)
    #expect(list.models.map(\.id) == ["claude-opus-4-6", "claude-haiku-4-5"])
    let opus = list.models[0]
    #expect(opus.displayName == "Claude Opus 4.6")
    #expect(opus.contextWindow == 1_000_000)
    #expect(opus.maxOutputTokens == 128_000)
    #expect(opus.inputModalities == [.text, .image])
    #expect(opus.thinking == ThinkingSupport(adaptive: true, budget: false, efforts: [.low, .high, .max]))
    #expect(opus.created != nil)
    #expect(opus.known == ModelCatalog.model(service: .anthropic, id: "claude-opus-4-6"))
    #expect(opus.known != nil)
    #expect(list.models[1].known == nil)
    let urls = await transport.urls
    #expect(urls == [
      "https://api.anthropic.com/v1/models?limit=1000",
      "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-opus-4-6",
    ])
  }

  @Test func failureIsReportedNotThrown() async {
    let transport = ListTransport([#"{"type":"error","error":{"type":"authentication_error","message":"bad key"}}"#])
    let gateway = Gateway(backends: [AnthropicBackend(apiKey: "k")], transport: transport)
    let list = await gateway.listModels()
    #expect(list.models.isEmpty)
    #expect(list.failures.count == 1)
  }
}

@Suite struct AnthropicThinkingStreamTests {
  @Test func thinkingDeltasSurfaceAsReasoningWithSignatureAndCacheUsage() throws {
    let backend = AnthropicBackend(apiKey: "k")
    var assembly = StreamAssembly(model: model)
    let script: [(String, String)] = [
      ("message_start", #"{"message":{"model":"m","usage":{"input_tokens":5,"cache_read_input_tokens":40,"cache_creation_input_tokens":7}}}"#),
      ("content_block_start", #"{"index":0,"content_block":{"type":"thinking","thinking":""}}"#),
      ("content_block_delta", #"{"index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#),
      ("content_block_delta", #"{"index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#),
      ("content_block_stop", #"{"index":0}"#),
      ("message_delta", #"{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#),
      ("message_stop", "{}"),
    ]
    var events: [StreamEvent] = []
    for (name, data) in script {
      events += try backend.decodeEvent(ServerSentEvent(event: name, data: data), assembly: &assembly)
    }
    #expect(events.contains(.reasoningStart))
    #expect(events.contains(.reasoningDelta(Reasoning(text: "hmm"))))
    #expect(events.contains(.reasoningEnd))
    guard case .completed(let response)? = events.last else { Issue.record("no completion"); return }
    #expect(response.output == [.reasoning(Reasoning(text: "hmm", signature: "sig", source: .anthropic))])
    #expect(response.usage.cacheReadTokens == 40)
    #expect(response.usage.cacheWriteTokens == 7)
    #expect(response.usage.outputTokens == 9)
  }
}
