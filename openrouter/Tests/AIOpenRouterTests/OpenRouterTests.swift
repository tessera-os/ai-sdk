import AI
import AIOpenRouter
import Foundation
import Testing
import ModelBoard

private let model = Model(
  identity: ModelIdentity(provider: .anthropic, family: .claude, version: "t"),
  capabilities: ModelCapabilities(streaming: true, toolCalling: true, structuredOutput: true, reasoning: true),
  remoteIDs: [RemoteModelID(service: .openRouter, protocol: .openAI, region: .global, id: "x/y")])

@Suite struct OpenRouterProviderOptionsTests {
  @Test func providerOptionsCannotOverwriteCoreFields() throws {
    let request = Request(
      model: model, messages: [.user(text: "hi")], maxTokens: 10,
      providerOptions: .object(["model": .string("evil"), "messages": .array([]), "route": .string("fallback")]))
    let wire = try OpenRouterBackend(apiKey: "k").encode(modelID: "x/y", request: request, stream: false)
    guard case .object(let doc) = try JSONValue.parse(wire.httpBody ?? Data()) else {
      Issue.record("body"); return
    }
    #expect(doc["model"] == .string("x/y"))
    if case .array(let messages)? = doc["messages"] { #expect(messages.count == 1) } else { Issue.record("messages") }
    #expect(doc["route"] == .string("fallback"))
  }
}

private func document(_ request: Request) throws -> [String: JSONValue] {
  let wire = try OpenRouterBackend(apiKey: "k").encode(modelID: "x/y", request: request, stream: false)
  guard case .object(let doc) = try JSONValue.parse(wire.httpBody ?? Data()) else { return [:] }
  return doc
}

private let echo = Tool(
  name: "echo", description: "Echoes.", inputSchema: Schema(.object(["type": .string("object")])))

@Suite struct OpenRouterTypedOptionTests {
  @Test func effortIsSentAsNestedReasoningObject() throws {
    let request = Request(model: model, messages: [.user(text: "hi")], reasoningEffort: .high)
    #expect(try document(request)["reasoning"] == .object(["effort": .string("high")]))
    #expect(try document(request)["reasoning_effort"] == nil)
  }

  @Test func budgetBecomesMaxTokens() throws {
    let request = Request(model: model, messages: [.user(text: "hi")], reasoningEffort: .budget(3000))
    #expect(try document(request)["reasoning"] == .object(["max_tokens": .integer(3000)]))
  }

  @Test func typedEffortBeatsProviderOptions() throws {
    let request = Request(
      model: model, messages: [.user(text: "hi")], reasoningEffort: .low,
      providerOptions: .object(["reasoning": .string("evil")]))
    #expect(try document(request)["reasoning"] == .object(["effort": .string("low")]))
  }

  @Test func toolChoiceAndStrictSchemaUseChatShapes() throws {
    let request = Request(
      model: model, messages: [.user(text: "hi")], tools: [echo],
      outputSchema: Schema(.object(["type": .string("object")]), strict: true), toolChoice: .required)
    let doc = try document(request)
    #expect(doc["tool_choice"] == .string("required"))
    guard case .object(let format)? = doc["response_format"], case .object(let inner)? = format["json_schema"]
    else { Issue.record("response_format"); return }
    #expect(inner["name"] == .string("response"))
    #expect(inner["strict"] == .bool(true))
  }

  @Test func cacheKeyIsNotSentToOpenRouter() throws {
    let request = Request(model: model, messages: [.user(text: "hi")], caching: PromptCaching(key: "k"))
    #expect(try document(request)["prompt_cache_key"] == nil)
  }
}

private actor Reply: HTTPTransport {
  let text: String
  init(_ text: String) { self.text = text }
  func open(_ request: URLRequest) async throws -> HTTPResponse {
    let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    continuation.yield(Data(text.utf8))
    continuation.finish()
    return HTTPResponse(head: HTTPResponseHead(status: 200), body: body)
  }
}

@Suite struct OpenRouterModelListTests {
  @Test func catalogEntriesCarryContextPricingAndCapabilities() async throws {
    let body = """
      {"data":[{"id":"anthropic/claude-x","name":"Claude X","created":1750000000,"context_length":200000,
      "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
      "pricing":{"prompt":"0.000003","completion":"0.000015"},
      "top_provider":{"context_length":200000,"max_completion_tokens":64000},
      "supported_parameters":["tools","reasoning","structured_outputs","temperature"]}]}
      """
    let list = await Gateway(backends: [OpenRouterBackend(apiKey: "k")], transport: Reply(body)).listModels()
    #expect(list.failures.isEmpty)
    #expect(
      list.models == [
        ModelListing(
          service: .openRouter, id: "anthropic/claude-x", displayName: "Claude X",
          created: Date(timeIntervalSince1970: 1_750_000_000), contextWindow: 200_000,
          maxOutputTokens: 64_000, inputModalities: [.text, .image], outputModalities: [.text],
          supportsTools: true, supportsStructuredOutput: true,
          thinking: ThinkingSupport(adaptive: true, budget: true),
          pricing: ListedPricing(input: 0.000003, output: 0.000015))
      ])
  }
}
