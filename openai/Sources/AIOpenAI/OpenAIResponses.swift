import AI
import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import ModelBoard

/// Encodes a canonical request as a POST to the Responses API.
///
/// Requests are stateless: `store` is false, so no server-side items are
/// referenced. When the model reasons, `include` asks for
/// `reasoning.encrypted_content`, and reasoning returned earlier in the
/// conversation is sent back (without item identifiers) so the model keeps its
/// chain of thought across turns.
///
/// Typed options map as follows: `reasoningEffort` to `reasoning.effort` with
/// `summary: "auto"`, `toolChoice` to `tool_choice`, `outputSchema` to
/// `text.format`, `caching.key` to `prompt_cache_key`, and `maxTokens` to
/// `max_output_tokens`.
///
/// - Throws: AIError.unsupportedInputModality for audio and video input,
///   AIError.unsupportedCapability for a reasoning token budget.
func openAIResponsesRequest(
  baseURL: String, apiKey: String, modelID: String, request: Request, stream: Bool
) throws -> URLRequest {
  var document: [String: JSONValue] = [
    "model": .string(modelID),
    "input": .array(try responsesInput(request.messages)),
    "store": .bool(false),
  ]
  var reserved: Set<String> = ["model", "input", "store", "stream", "tools", "instructions"]
  if let instructions = request.instructions { document["instructions"] = .string(instructions) }
  if let limit = request.maxTokens {
    document["max_output_tokens"] = .integer(Int64(limit))
    reserved.insert("max_output_tokens")
  }
  if !request.tools.isEmpty {
    document["tools"] = .array(request.tools.map(responsesTool))
    if let choice = request.toolChoice { document["tool_choice"] = responsesToolChoice(choice) }
  }
  if request.toolChoice != nil { reserved.insert("tool_choice") }
  if let schema = request.outputSchema {
    var format: [String: JSONValue] = [
      "type": .string("json_schema"), "name": .string(schema.name ?? "response"),
      "schema": schema.json,
    ]
    if let strict = schema.strict { format["strict"] = .bool(strict) }
    document["text"] = .object(["format": .object(format)])
    reserved.insert("text")
  }
  if let effort = request.reasoningEffort {
    if case .budget = effort { throw AIError.unsupportedCapability("reasoning token budget") }
    document["reasoning"] = .object([
      "effort": .string(effort.openAIName), "summary": .string("auto"),
    ])
    reserved.insert("reasoning")
  }
  var include: [String] = []
  if request.reasoningEffort != nil || openAIIsReasoningModel(modelID: modelID, model: request.model) {
    include.append("reasoning.encrypted_content")
    if case .array(let extra)? = request.providerOptions?["include"] {
      include += extra.compactMap(\.stringValue).filter { $0 != "reasoning.encrypted_content" }
    }
    document["include"] = .array(include.map(JSONValue.string))
    reserved.insert("include")
  }
  if let key = request.caching?.key {
    document["prompt_cache_key"] = .string(key)
    reserved.insert("prompt_cache_key")
  }
  if stream { document["stream"] = .bool(true) }
  document.merge(providerOptions: request.providerOptions, reserving: reserved)
  return try postJSON(
    baseURL: baseURL, path: "/responses", apiKey: apiKey, document: .object(document),
    stream: stream)
}

private func responsesToolChoice(_ choice: ToolChoice) -> JSONValue {
  switch choice {
  case .auto: .string("auto")
  case .disabled: .string("none")
  case .required: .string("required")
  case .tool(let name): .object(["type": .string("function"), "name": .string(name)])
  }
}

private func responsesTool(_ tool: Tool) -> JSONValue {
  .object([
    "type": .string("function"), "name": .string(tool.name),
    "description": .string(tool.description), "parameters": tool.inputSchema.json,
  ])
}

private func responsesInput(_ messages: [Message]) throws -> [JSONValue] {
  var items: [JSONValue] = []
  for message in messages {
    switch message {
    case .user(let inputs):
      items.append(
        .object(["role": .string("user"), "content": .array(try inputs.map(responsesPart))]))
    case .assistant(let outputs):
      for output in outputs { try items.append(contentsOf: responsesItem(output)) }
    case .toolResults(let results):
      for result in results {
        let text = try result.output.stringValue ?? jsonText(result.output)
        items.append(
          .object([
            "type": .string("function_call_output"), "call_id": .string(result.id),
            "output": .string(text),
          ]))
      }
    }
  }
  return items
}

private func responsesPart(_ input: Input) throws -> JSONValue {
  switch input {
  case .text(let part):
    return .object(["type": .string("input_text"), "text": .string(part.text)])
  case .image(let part):
    return .object([
      "type": .string("input_image"), "image_url": .string(dataURL(part.mediaType, part.data)),
    ])
  case .file(let part):
    return .object([
      "type": .string("input_file"), "filename": .string(part.name),
      "file_data": .string(dataURL(part.mediaType, part.data)),
    ])
  case .audio: throw AIError.unsupportedInputModality(.audio)
  case .video: throw AIError.unsupportedInputModality(.video)
  }
}

private func responsesItem(_ output: Output) throws -> [JSONValue] {
  func message(_ text: String) -> JSONValue {
    .object([
      "type": .string("message"), "role": .string("assistant"),
      "content": .array([.object(["type": .string("output_text"), "text": .string(text)])]),
    ])
  }
  switch output {
  case .text(let part): return [message(part.text)]
  case .object(let value): return [message(try jsonText(value))]
  case .reasoning(let part):
    guard part.source == .openAI, let secret = part.signature else { return [] }
    let summary: [JSONValue] =
      part.text.isEmpty
      ? [] : [.object(["type": .string("summary_text"), "text": .string(part.text)])]
    return [
      .object([
        "type": .string("reasoning"), "summary": .array(summary),
        "encrypted_content": .string(secret),
      ])
    ]
  case .call(let call):
    return [
      .object([
        "type": .string("function_call"), "call_id": .string(call.id),
        "name": .string(call.name), "arguments": .string(try jsonText(call.input)),
      ])
    ]
  case .image, .audio: return []
  }
}
