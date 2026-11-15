import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A transport that answers OpenAI chat completions sent to
/// ``MockModelTransport/host`` itself, with made-up replies and tool calls, so
/// a whole reply flow (streaming, decoding, tool calls and their results)
/// runs without spending a model. Every other request goes to `base`.
///
/// A streamed reply is a reasoning delta then the text in a few deltas; when
/// the request offers tools and its last message is not a tool result, one
/// tool call instead, with arguments built from the tool's JSON schema. A
/// user message containing `tool:<name>` picks the tool. After a tool
/// result, a final text saying how long it was. Usage counts a token per
/// four bytes.
public struct MockModelTransport: HTTPTransport {
  /// The host mock requests go to: `https://mock.ai.invalid/v1`.
  public static let host = "mock.ai.invalid"
  public static let baseURL = "https://\(host)/v1"

  public let base: any HTTPTransport

  public init(base: any HTTPTransport) { self.base = base }

  public func open(_ request: URLRequest) async throws -> HTTPResponse {
    guard request.url?.host == Self.host else { return try await base.open(request) }
    guard let body = request.httpBody else { throw AIError.transport("A mock request has no body.") }
    guard case .object(let payload) = try JSONValue.parse(body) else {
      throw AIError.malformed("A mock request body is not a JSON object.")
    }
    let events = try Self.events(for: payload, requestBytes: body.count)
    let streamed = payload["stream"] == .bool(true)
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    if streamed {
      for event in events { continuation.yield(Data("data: \(try jsonStringify(.object(event)))\n\n".utf8)) }
      continuation.yield(Data("data: [DONE]\n\n".utf8))
    } else {
      continuation.yield(try JSONValue.object(Self.completion(events)).encoded())
    }
    continuation.finish()
    let type = streamed ? "text/event-stream" : "application/json"
    return HTTPResponse(head: HTTPResponseHead(status: 200, headers: ["Content-Type": type]), body: stream)
  }

  // MARK: The reply

  /// The chunks of the reply to `payload`, as OpenAI streams them.
  static func events(for payload: [String: JSONValue], requestBytes: Int) throws -> [[String: JSONValue]] {
    let model = payload["model"]?.stringValue ?? "mock"
    let messages: [JSONValue] = if case .array(let items) = payload["messages"] { items } else { [] }
    let last: [String: JSONValue] = if case .object(let message) = messages.last { message } else { [:] }
    let tools: [[String: JSONValue]] =
      if case .array(let items) = payload["tools"] {
        items.compactMap { if case .object(let tool) = $0, case .object(let function) = tool["function"] { function } else { nil } }
      } else { [] }

    func chunk(_ delta: [String: JSONValue], finish: String? = nil) -> [String: JSONValue] {
      [
        "id": .string("mock-reply"), "object": .string("chat.completion.chunk"), "model": .string(model),
        "choices": .array([.object([
          "index": .integer(0), "delta": .object(delta), "finish_reason": finish.map(JSONValue.string) ?? .null,
        ])]),
      ]
    }

    var events = [chunk(["role": .string("assistant"), "reasoning_content": .string("Mock reasoning about the request. ")])]
    var replyBytes = 0
    if last["role"]?.stringValue == "tool" {
      let result = Self.text(of: last["content"])
      let reply = "Mock reply: the tool answered \(result.utf8.count) bytes."
      replyBytes = reply.utf8.count
      events += Self.split(reply).map { chunk(["content": .string($0)]) }
      events.append(chunk([:], finish: "stop"))
    } else if !tools.isEmpty {
      let wanted = Self.requestedTool(in: messages)
      let tool = tools.first { $0["name"]?.stringValue == wanted } ?? tools[0]
      let name = tool["name"]?.stringValue ?? "tool"
      let arguments = try jsonStringify(Self.sample(tool["parameters"] ?? .object([:])))
      replyBytes = arguments.utf8.count
      events.append(chunk([
        "tool_calls": .array([.object([
          "index": .integer(0), "id": .string("mock-call-\(messages.count)"), "type": .string("function"),
          "function": .object(["name": .string(name), "arguments": .string(arguments)]),
        ])])
      ]))
      events.append(chunk([:], finish: "tool_calls"))
    } else {
      let asked = Self.text(of: last["content"])
      let reply = "Mock reply to \(asked.utf8.count) bytes: lorem ipsum dolor sit amet, consectetur adipiscing elit."
      replyBytes = reply.utf8.count
      events += Self.split(reply).map { chunk(["content": .string($0)]) }
      events.append(chunk([:], finish: "stop"))
    }
    let prompt = Int64(requestBytes / 4)
    let completion = Int64(max(1, replyBytes / 4))
    events.append([
      "id": .string("mock-reply"), "object": .string("chat.completion.chunk"), "model": .string(model),
      "choices": .array([]),
      "usage": .object([
        "prompt_tokens": .integer(prompt), "completion_tokens": .integer(completion),
        "total_tokens": .integer(prompt + completion),
      ]),
    ])
    return events
  }

  /// The same reply as one non-streamed completion.
  static func completion(_ events: [[String: JSONValue]]) -> [String: JSONValue] {
    var content = ""
    var reasoning = ""
    var calls: [JSONValue] = []
    var finish = "stop"
    var usage: JSONValue = .null
    for event in events {
      if let value = event["usage"] { usage = value }
      guard case .array(let choices) = event["choices"], case .object(let choice) = choices.first else { continue }
      if let reason = choice["finish_reason"]?.stringValue { finish = reason }
      guard case .object(let delta) = choice["delta"] else { continue }
      content += delta["content"]?.stringValue ?? ""
      reasoning += delta["reasoning_content"]?.stringValue ?? ""
      if case .array(let items) = delta["tool_calls"] {
        calls += items.map { item in
          guard case .object(var call) = item else { return item }
          call["index"] = nil
          return .object(call)
        }
      }
    }
    var message: [String: JSONValue] = ["role": .string("assistant"), "content": .string(content)]
    if !reasoning.isEmpty { message["reasoning_content"] = .string(reasoning) }
    if !calls.isEmpty { message["tool_calls"] = .array(calls) }
    return [
      "id": .string("mock-reply"), "object": .string("chat.completion"), "model": .string("mock"),
      "choices": .array([.object(["index": .integer(0), "message": .object(message), "finish_reason": .string(finish)])]),
      "usage": usage,
    ]
  }

  // MARK: Helpers

  /// A value that fits `schema`: its required properties filled in.
  static func sample(_ schema: JSONValue) -> JSONValue {
    guard case .object(let schema) = schema else { return .string("mock") }
    if case .array(let choices) = schema["enum"], let first = choices.first { return first }
    switch schema["type"]?.stringValue {
    case "integer", "number": return .integer(1)
    case "boolean": return .bool(true)
    case "array": return .array([])
    case "string": return .string("mock")
    default:
      guard case .object(let properties) = schema["properties"] else { return .object([:]) }
      let required: [String] = if case .array(let names) = schema["required"] { names.compactMap(\.stringValue) } else { [] }
      var object: [String: JSONValue] = [:]
      for name in required { object[name] = sample(properties[name] ?? .object([:])) }
      return .object(object)
    }
  }

  /// The tool a user message names with `tool:<name>`, the latest first.
  static func requestedTool(in messages: [JSONValue]) -> String? {
    for message in messages.reversed() {
      guard case .object(let fields) = message, fields["role"]?.stringValue == "user" else { continue }
      let text = Self.text(of: fields["content"])
      guard let range = text.range(of: "tool:") else { continue }
      return String(text[range.upperBound...].prefix { !$0.isWhitespace })
    }
    return nil
  }

  /// A message's text: a string, or the text parts of a content list.
  static func text(of content: JSONValue?) -> String {
    switch content {
    case .string(let text): return text
    case .array(let parts):
      return parts.compactMap { part in
        if case .object(let fields) = part { fields["text"]?.stringValue } else { nil }
      }.joined()
    default: return ""
    }
  }

  /// `text` in a few pieces, as a model streams it.
  static func split(_ text: String) -> [String] {
    let words = text.split(separator: " ", omittingEmptySubsequences: false)
    let size = max(1, words.count / 3)
    return stride(from: 0, to: words.count, by: size).map { start in
      let piece = words[start..<min(words.count, start + size)].joined(separator: " ")
      return start + size < words.count ? piece + " " : piece
    }
  }
}
