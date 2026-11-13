import AI
import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import ModelBoard

/// Anthropic Messages API settings shared by request encoding and streaming.
public struct AnthropicOptions: Sendable, Equatable {
  /// The API root. The Messages path is appended by the backend.
  public var baseURL: String

  /// Maximum output-token count used when the request does not specify one.
  public var defaultMaxTokens: Int

  /// The Anthropic API version sent in the anthropic-version header.
  public var version: String

  /// Which models take budgeted versus adaptive thinking.
  public var thinking: AnthropicThinkingRules

  /// Creates settings for an Anthropic-compatible endpoint.
  public init(
    baseURL: String = "https://api.anthropic.com",
    defaultMaxTokens: Int = 4096,
    version: String = "2023-06-01",
    thinking: AnthropicThinkingRules = AnthropicThinkingRules()
  ) {
    self.baseURL = baseURL
    self.defaultMaxTokens = defaultMaxTokens
    self.version = version
    self.thinking = thinking
  }
}

/// A backend that speaks Anthropic's Messages API.
public struct AnthropicBackend: AIBackend {
  /// The API key sent in the x-api-key header.
  public let apiKey: String

  /// Configuration for the endpoint and API version.
  public let options: AnthropicOptions

  /// Anthropic is treated as a globally routed service.
  public var region: Region? { .global }

  /// The service this backend connects to.
  public var service: Service { .anthropic }

  /// The wire protocol used by this backend.
  public var apiProtocol: AIProtocol { .anthropic }

  /// Creates an Anthropic backend that authenticates with an API key.
  public init(apiKey: String, options: AnthropicOptions = AnthropicOptions()) {
    self.apiKey = apiKey
    self.options = options
  }

  /// Encodes a canonical request as an HTTP POST to /v1/messages.
  public func encode(modelID: String, request: Request, stream: Bool) throws -> URLRequest {
    let document = try anthropicDocument(
      modelID: modelID,
      request: request,
      fallbackMaxTokens: options.defaultMaxTokens,
      stream: stream,
      thinking: options.thinking
    )

    return try postJSON(
      baseURL: options.baseURL,
      path: "/v1/messages",
      apiKey: apiKey,
      headers: headers,
      credentialHeader: credentialHeader,
      credentialPrefix: credentialPrefix,
      document: document,
      stream: stream
    )
  }

  /// The version header.
  private var headers: [String: String] { ["anthropic-version": options.version] }

  private var credentialHeader: String { "x-api-key" }
  private var credentialPrefix: String { "" }

  /// Decodes a complete HTTP response into canonical output and usage values.
  public func decode(status: Int, body: Data, model: Model) throws -> Response {
    try decodeAnthropic(status: status, body: body, model: model)
  }

  /// Encodes a GET for one page of `/v1/models` (up to 1000 entries).
  public func listModelsRequest(after cursor: String?) throws -> URLRequest {
    let query = "?limit=1000" + (cursor.map { "&after_id=\($0)" } ?? "")
    return try getJSON(
      baseURL: options.baseURL, path: "/v1/models" + query, apiKey: apiKey,
      headers: headers, credentialHeader: credentialHeader, credentialPrefix: credentialPrefix)
  }

  /// Decodes one page of the model list, including thinking and effort support.
  public func decodeModelPage(status: Int, body: Data) throws -> ModelPage {
    try decodeAnthropicModelPage(status: status, body: body)
  }

  /// Decodes one Anthropic server-sent event and updates the stream assembly.
  public func decodeEvent(
    _ event: ServerSentEvent,
    assembly: inout StreamAssembly
  ) throws -> [StreamEvent] {
    try decodeAnthropicEvent(event, assembly: &assembly)
  }
}

/// Encodes a canonical request as an Anthropic Messages JSON document.
///
/// Typed request options map as follows. `toolChoice` becomes `tool_choice`
/// (`required` is `any`). `reasoningEffort` becomes `thinking` plus
/// `output_config.effort` (adaptive models) or `thinking.budget_tokens`
/// (budget-only models), per `thinking`. `caching` places ephemeral
/// `cache_control` markers, with its lifetime as `ttl`, on the chosen
/// breakpoints.
///
/// Anthropic requires max_tokens on every request. A request outputSchema is
/// sent as `output_config.format` (type `json_schema`); the model's reply
/// arrives as JSON text in an ordinary text block. Provider options are merged
/// after core fields and never override model, messages, max_tokens, system,
/// tools, stream, or (when a schema is set) output_config.
///
/// - Parameters:
///   - modelID: The provider-specific model identifier selected by Router.
///   - request: The canonical conversation and generation options.
///   - fallbackMaxTokens: The limit used when request.maxTokens is nil.
///   - stream: Whether the document should request event streaming.
/// - Returns: A JSON document accepted by the Messages API.
/// - Throws: AIError.unsupportedInputModality for unsupported media, and
///   encoding errors for invalid nested JSON values.
public func anthropicDocument(
  modelID: String,
  request: Request,
  fallbackMaxTokens: Int = 4096,
  stream: Bool,
  thinking: AnthropicThinkingRules = AnthropicThinkingRules()
) throws -> JSONValue {
  var messages: [JSONValue] = []
  for message in request.messages {
    messages.append(try anthropicMessage(message))
  }

  let breakpoints = request.caching?.breakpoints ?? []
  let lifetime = request.caching?.lifetime ?? .oneHour
  if breakpoints.contains(.lastMessage) { messages = anthropicMarkingLastMessage(messages, lifetime: lifetime) }

  var maxTokens = request.maxTokens ?? fallbackMaxTokens
  var outputConfig: [String: JSONValue] = [:]
  var reserved: Set<String> = ["model", "max_tokens", "messages", "system", "tools", "stream"]
  var thinkingField: JSONValue?
  if let effort = request.reasoningEffort {
    let plan = anthropicThinkingPlan(
      effort: effort, modelID: modelID, maxTokens: maxTokens, rules: thinking)
    thinkingField = plan.thinking
    maxTokens = plan.maxTokens
    if let level = plan.effort { outputConfig["effort"] = .string(level) }
    reserved.insert("thinking")
  }

  var document: [String: JSONValue] = [
    "model": .string(modelID),
    "max_tokens": .integer(Int64(maxTokens)),
    "messages": .array(messages),
  ]
  if let thinkingField { document["thinking"] = thinkingField }

  let systemLifetime = breakpoints.contains(.system) ? lifetime : nil
  if let instructions = request.instructions {
    document["system"] = anthropicSystem(instructions, cachedFor: systemLifetime)
  }

  if !request.tools.isEmpty {
    var tools = request.tools.map(anthropicTool)
    if breakpoints.contains(.tools), let last = tools.last {
      tools[tools.count - 1] = anthropicMarkedForCache(last, lifetime: lifetime)
    }
    document["tools"] = .array(tools)
    if let choice = request.toolChoice { document["tool_choice"] = anthropicToolChoice(choice) }
  }
  if request.toolChoice != nil { reserved.insert("tool_choice") }

  if let schema = request.outputSchema {
    outputConfig["format"] = .object(["type": .string("json_schema"), "schema": schema.json])
  }
  if !outputConfig.isEmpty {
    document["output_config"] = .object(outputConfig)
    reserved.insert("output_config")
  }

  if stream {
    document["stream"] = .bool(true)
  }

  document.merge(providerOptions: request.providerOptions, reserving: reserved)

  return .object(document)
}

private func anthropicToolChoice(_ choice: ToolChoice) -> JSONValue {
  switch choice {
  case .auto: .object(["type": .string("auto")])
  case .disabled: .object(["type": .string("none")])
  case .required: .object(["type": .string("any")])
  case .tool(let name): .object(["type": .string("tool"), "name": .string(name)])
  }
}

private func anthropicMessage(_ message: Message) throws -> JSONValue {
  var role = "user"
  var content: [JSONValue] = []

  switch message {
  case .user(let inputs):
    for input in inputs {
      content.append(try anthropicInput(input))
    }

  case .assistant(let outputs):
    role = "assistant"

    for output in outputs {
      switch output {
      case .text(let part):
        content.append(anthropicTextBlock(part.text))

      case .reasoning(let part):
        if let signature = part.signature, part.source == nil || part.source == .anthropic {
          content.append(
            .object([
              "type": .string("thinking"),
              "thinking": .string(part.text),
              "signature": .string(signature),
            ]))
        }

      case .call(let call):
        content.append(
          .object([
            "type": .string("tool_use"),
            "id": .string(call.id),
            "name": .string(call.name),
            "input": call.input,
          ]))

      case .object(let value):
        content.append(anthropicTextBlock(try jsonStringify(value)))

      case .image, .audio:
        break
      }
    }

  case .toolResults(let results):
    for result in results {
      let text: String
      if let string = result.output.stringValue {
        text = string
      } else {
        text = try jsonStringify(result.output)
      }
      content.append(
        .object([
          "type": .string("tool_result"),
          "tool_use_id": .string(result.id),
          "content": .string(text),
        ]))
    }
  }

  return .object([
    "role": .string(role),
    "content": .array(content),
  ])
}

private func anthropicInput(_ input: Input) throws -> JSONValue {
  switch input {
  case .text(let part):
    return anthropicTextBlock(part.text)

  case .image(let part):
    return anthropicMediaBlock(
      kind: "image",
      mediaType: part.mediaType,
      data: part.data
    )

  case .file(let part):
    return anthropicMediaBlock(
      kind: "document",
      mediaType: part.mediaType,
      data: part.data
    )

  case .audio:
    throw AIError.unsupportedInputModality(.audio)

  case .video:
    throw AIError.unsupportedInputModality(.video)
  }
}

private func anthropicTextBlock(_ text: String) -> JSONValue {
  .object([
    "type": .string("text"),
    "text": .string(text),
  ])
}

private func anthropicMediaBlock(kind: String, mediaType: String, data: Data) -> JSONValue {
  .object([
    "type": .string(kind),
    "source": .object([
      "type": .string("base64"),
      "media_type": .string(mediaType),
      "data": .string(data.base64EncodedString()),
    ]),
  ])
}

private func anthropicTool(_ tool: Tool) -> JSONValue {
  .object([
    "name": .string(tool.name),
    "description": .string(tool.description),
    "input_schema": tool.inputSchema.json,
  ])
}

private func objectValue(_ value: JSONValue?) -> [String: JSONValue] {
  guard case .object(let fields)? = value else {
    return [:]
  }
  return fields
}

private func decodeAnthropic(status: Int, body: Data, model: Model) throws -> Response {
  guard (200..<300).contains(status) || !body.isEmpty else {
    throw AIError.status(status)
  }

  let document: [String: JSONValue]
  do {
    document = try jsonObject(body)
  } catch {
    if !(200..<300).contains(status) {
      throw AIError.status(status)
    }
    throw error
  }

  if document["type"]?.stringValue == "error" || !(200..<300).contains(status) {
    throw anthropicServiceError(status: status, document: document)
  }

  var output: [Output] = []

  if case .array(let blocks)? = document["content"] {
    for block in blocks {
      guard case .object(let fields) = block else {
        continue
      }

      switch fields["type"]?.stringValue {
      case "text":
        output.append(.text(TextPart(fields["text"]?.stringValue ?? "")))

      case "thinking":
        output.append(
          .reasoning(
            Reasoning(
              text: fields["thinking"]?.stringValue ?? "",
              signature: fields["signature"]?.stringValue,
              source: .anthropic
            )))

      case "tool_use":
        output.append(
          .call(
            ToolCall(
              id: fields["id"]?.stringValue ?? "",
              name: fields["name"]?.stringValue ?? "",
              input: fields["input"] ?? .object([:])
            )))

      default:
        // Redacted thinking and unknown block types have no canonical value.
        break
      }
    }
  }

  return Response(
    model: model,
    output: output,
    usage: anthropicUsage(document["usage"]),
    finishReason: anthropicFinish(document["stop_reason"]?.stringValue),
    servedModel: document["model"]?.stringValue
  )
}

private func anthropicServiceError(status: Int, document: [String: JSONValue]) -> AIError {
  guard case .object(let error)? = document["error"],
    let message = error["message"]?.stringValue,
    !message.isEmpty
  else {
    return .status(status)
  }

  return .service(
    ServiceFailure(
      status: status,
      kind: error["type"]?.stringValue,
      message: message
    ))
}

/// Maps an in-stream error event to a typed service failure.
///
/// The HTTP status of such a stream is 200, so the status reported is derived
/// from the error type in the event body (for example overloaded_error is 529).
private func anthropicStreamError(document: [String: JSONValue]) -> AIError {
  let error = objectValue(document["error"])
  let kind = error["type"]?.stringValue
  let status: Int
  switch kind {
  case "invalid_request_error": status = 400
  case "authentication_error": status = 401
  case "billing_error": status = 402
  case "permission_error": status = 403
  case "not_found_error": status = 404
  case "request_too_large": status = 413
  case "rate_limit_error": status = 429
  case "timeout_error": status = 504
  case "overloaded_error": status = 529
  default: status = 500
  }
  let message = error["message"]?.stringValue ?? ""
  return .service(
    ServiceFailure(
      status: status, kind: kind,
      message: message.isEmpty ? "Anthropic reported a \(kind ?? "stream") error." : message))
}

private func anthropicUsage(_ value: JSONValue?) -> Usage {
  guard case .object(let fields)? = value else {
    return Usage()
  }

  return Usage(
    inputTokens: jsonInt(fields, "input_tokens"),
    outputTokens: jsonInt(fields, "output_tokens"),
    cacheReadTokens: jsonInt(fields, "cache_read_input_tokens"),
    cacheWriteTokens: jsonInt(fields, "cache_creation_input_tokens")
  )
}

private func anthropicFinish(_ stopReason: String?) -> FinishReason {
  switch stopReason {
  case "max_tokens": .length
  case "tool_use": .toolCall
  case "refusal": .refusal
  default: .completed
  }
}

private func decodeAnthropicEvent(
  _ event: ServerSentEvent,
  assembly: inout StreamAssembly
) throws -> [StreamEvent] {
  if event.event == "ping" {
    return []
  }

  let document: [String: JSONValue]
  do {
    document = try jsonObject(Data(event.data.utf8))
  } catch {
    throw AIError.malformed(
      "Anthropic event \(event.event ?? "") is not valid JSON: \(error.localizedDescription)")
  }

  let key = "block-\(jsonInt(document, "index") ?? 0)"
  var events: [StreamEvent] = []

  switch event.event {
  case "message_start":
    let message = objectValue(document["message"])
    assembly.servedModel = message["model"]?.stringValue
    events += assembly.recordUsage(anthropicUsage(message["usage"]))

  case "content_block_start":
    let block = objectValue(document["content_block"])

    switch block["type"]?.stringValue {
    case "tool_use":
      events += assembly.beginTool(
        key: key,
        id: block["id"]?.stringValue ?? "",
        name: block["name"]?.stringValue ?? ""
      )

    case "text":
      if let text = block["text"]?.stringValue, !text.isEmpty {
        events += assembly.appendText(text, key: key)
      } else {
        events += assembly.beginText(key: key)
      }

    case "thinking":
      if let text = block["thinking"]?.stringValue, !text.isEmpty {
        events += assembly.appendReasoning(text, key: key)
      } else {
        events += assembly.beginReasoning(key: key)
      }

    default:
      break
    }

  case "content_block_delta":
    let delta = objectValue(document["delta"])

    switch delta["type"]?.stringValue {
    case "text_delta":
      events += assembly.appendText(delta["text"]?.stringValue ?? "", key: key)

    case "thinking_delta":
      events += assembly.appendReasoning(delta["thinking"]?.stringValue ?? "", key: key)

    case "signature_delta":
      assembly.setReasoningSignature(
        delta["signature"]?.stringValue ?? "", source: .anthropic, key: key)

    case "input_json_delta":
      events += assembly.appendToolJSON(
        delta["partial_json"]?.stringValue ?? "",
        key: key
      )

    default:
      break
    }

  case "content_block_stop":
    events += assembly.endText(key: key)
    events += assembly.endReasoning(key: key)
    events += try assembly.endTool(key: key)

  case "message_delta":
    let delta = objectValue(document["delta"])
    if let reason = delta["stop_reason"]?.stringValue {
      assembly.finishReason = anthropicFinish(reason)
    }
    events += assembly.recordUsage(anthropicUsage(document["usage"]))

  case "message_stop":
    events += try assembly.endAllTools()
    events += try assembly.complete()

  case "error":
    throw anthropicStreamError(document: document)

  default:
    break
  }

  return events
}
