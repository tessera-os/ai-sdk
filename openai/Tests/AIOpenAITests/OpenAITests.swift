import AI
import Foundation
import Testing

@testable import AIOpenAI
import ModelBoard

private let model = Model(
  identity: ModelIdentity(provider: .openAI, family: .gpt, version: "t"),
  capabilities: ModelCapabilities(streaming: true, structuredOutput: true),
  remoteIDs: [RemoteModelID(service: .openAI, protocol: .openAI, region: .global, id: "gpt-test")])

@Suite struct OpenAIProviderOptionsTests {
  @Test func providerOptionsCannotOverwriteCoreFields() throws {
    let hostile: JSONValue = .object([
      "model": .string("evil"), "messages": .array([]), "max_completion_tokens": .integer(1),
      "stream": .bool(false), "stream_options": .string("evil"), "tools": .array([]),
      "response_format": .string("evil"), "temperature": .number(0.2),
    ])
    let request = Request(
      model: model, messages: [.user(text: "hi")], maxTokens: 50,
      outputSchema: Schema(.object(["type": .string("object")])), providerOptions: hostile)
    let wire = try OpenAIBackend(apiKey: "k").encode(modelID: "gpt-test", request: request, stream: true)
    guard case .object(let doc) = try JSONValue.parse(wire.httpBody ?? Data()) else {
      Issue.record("body"); return
    }
    #expect(doc["model"] == .string("gpt-test"))
    #expect(doc["max_completion_tokens"] == .integer(50))
    #expect(doc["stream"] == .bool(true))
    #expect(doc["stream_options"] != .string("evil"))
    #expect(doc["response_format"] != .string("evil"))
    #expect(doc["tools"] == nil)
    if case .array(let messages)? = doc["messages"] { #expect(messages.count == 1) } else { Issue.record("messages") }
    #expect(doc["temperature"] != nil)
  }
}

@Suite struct OpenAIStreamErrorTests {
  private func decode(_ data: String) throws -> [StreamEvent] {
    var assembly = StreamAssembly(model: model)
    return try OpenAIBackend(apiKey: "k").decodeEvent(
      ServerSentEvent(data: data), assembly: &assembly)
  }

  @Test func inStreamErrorsMapToHTTPStatuses() {
    #expect(throws: AIError.service(ServiceFailure(status: 429, kind: "requests", message: "slow"))) {
      try decode(#"{"error":{"message":"slow","type":"requests","code":"rate_limit_exceeded"}}"#)
    }
    #expect(throws: AIError.service(ServiceFailure(status: 400, kind: "invalid_request_error", message: "bad"))) {
      try decode(#"{"error":{"message":"bad","type":"invalid_request_error"}}"#)
    }
    #expect(throws: AIError.service(ServiceFailure(status: 500, kind: "server_error", message: "oops"))) {
      try decode(#"{"error":{"message":"oops","type":"server_error"}}"#)
    }
  }
}
