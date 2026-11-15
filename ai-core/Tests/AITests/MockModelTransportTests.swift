import Foundation
import Testing

@testable import AI

@Suite("Mock model transport")
struct MockModelTransportTests {
  private func payload(_ messages: [JSONValue], tools: [JSONValue] = []) -> [String: JSONValue] {
    var payload: [String: JSONValue] = ["model": .string("mock"), "stream": .bool(true), "messages": .array(messages)]
    if !tools.isEmpty { payload["tools"] = .array(tools) }
    return payload
  }

  private let readTool: JSONValue = .object([
    "type": .string("function"),
    "function": .object([
      "name": .string("read_file"),
      "parameters": .object([
        "type": .string("object"),
        "properties": .object([
          "path": .object(["type": .string("string")]),
          "lines": .object(["type": .string("integer")]),
          "mode": .object(["type": .string("string"), "enum": .array([.string("text"), .string("hex")])]),
        ]),
        "required": .array([.string("path"), .string("lines"), .string("mode")]),
      ]),
    ]),
  ])

  private func deltas(_ events: [[String: JSONValue]]) -> [[String: JSONValue]] {
    events.compactMap { event in
      guard case .array(let choices) = event["choices"], case .object(let choice) = choices.first,
        case .object(let delta) = choice["delta"]
      else { return nil }
      return delta
    }
  }

  @Test func repliesWithTextWithoutTools() throws {
    let events = try MockModelTransport.events(
      for: payload([.object(["role": .string("user"), "content": .string("hi")])]), requestBytes: 100)
    let text = deltas(events).compactMap { $0["content"]?.stringValue }.joined()
    #expect(text.hasPrefix("Mock reply to 2 bytes"))
    #expect(events.last?["usage"] != nil)
  }

  @Test func callsAToolWithArgumentsFromItsSchema() throws {
    let events = try MockModelTransport.events(
      for: payload([.object(["role": .string("user"), "content": .string("read it")])], tools: [readTool]),
      requestBytes: 100)
    let call = deltas(events).compactMap { delta -> [String: JSONValue]? in
      guard case .array(let calls) = delta["tool_calls"], case .object(let call) = calls.first,
        case .object(let function) = call["function"]
      else { return nil }
      return function
    }.first
    #expect(call?["name"]?.stringValue == "read_file")
    let arguments = try JSONValue.parse(Data((call?["arguments"]?.stringValue ?? "").utf8))
    #expect(arguments == .object(["path": .string("mock"), "lines": .integer(1), "mode": .string("text")]))
  }

  @Test func answersAToolResult() throws {
    let events = try MockModelTransport.events(
      for: payload(
        [
          .object(["role": .string("user"), "content": .string("read it")]),
          .object(["role": .string("tool"), "tool_call_id": .string("mock-call-1"), "content": .string("12345")]),
        ], tools: [readTool]),
      requestBytes: 100)
    let text = deltas(events).compactMap { $0["content"]?.stringValue }.joined()
    #expect(text == "Mock reply: the tool answered 5 bytes.")
  }
}
