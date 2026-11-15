import AI
import Foundation
import ModelBoard

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Service-specific choices layered on the chat-completions protocol.
public struct OpenAIDialect: Sendable, Equatable {
  /// Name of the output-token limit field accepted by the service.
  public var maxTokensField: String

  /// Assistant-message field used when replaying reasoning content.
  public var reasoningField: String?

  /// Fallback output-token limit used when a request does not set maxTokens.
  public var fallbackMaxTokens: Int

  /// How the service takes `Request.reasoningEffort`.
  public var reasoningEffort: OpenAIReasoningParameter

  /// Whether the service understands OpenAI's `prompt_cache_key`.
  public var sendsPromptCacheKey: Bool

  /// Provider-specific fields sent on every request, such as chat template options.
  public var additionalFields: [String: JSONValue]

  /// Creates options for a service that implements the OpenAI chat-completions shape.
  ///
  /// - Parameters:
  ///   - maxTokensField: Provider field for the output-token limit.
  ///   - reasoningField: Optional field used to replay reasoning content.
  ///   - fallbackMaxTokens: Default limit for requests without an explicit cap.
  ///   - reasoningEffort: How reasoning effort is sent. Defaults to not sent.
  ///   - sendsPromptCacheKey: Whether `PromptCaching.key` is sent as `prompt_cache_key`.
  ///   - additionalFields: Fields included in every request body.
  public init(
    maxTokensField: String = "max_tokens", reasoningField: String? = nil,
    fallbackMaxTokens: Int = 4096, reasoningEffort: OpenAIReasoningParameter = .unsupported,
    sendsPromptCacheKey: Bool = false, additionalFields: [String: JSONValue] = [:]
  ) {
    self.maxTokensField = maxTokensField
    self.reasoningField = reasoningField
    self.fallbackMaxTokens = fallbackMaxTokens
    self.reasoningEffort = reasoningEffort
    self.sendsPromptCacheKey = sendsPromptCacheKey
    self.additionalFields = additionalFields
  }
}

/// OpenAI's Responses and chat-completions APIs.
///
/// With the default `OpenAIEndpoint.automatic`, reasoning models (the GPT-5
/// and later families and the o-series) use `/responses`, which streams
/// reasoning summaries and round-trips encrypted reasoning; other models use
/// `/chat/completions`.
public struct OpenAIBackend: AIBackend {
  /// Which OpenAI API receives requests.
  public let endpoint: OpenAIEndpoint

  /// The OpenAI API key. It is sent only in the Authorization header over HTTPS.
  public let apiKey: String

  /// The API root; the chat-completions path is appended automatically.
  public let baseURL: String

  /// OpenAI endpoints are modeled as globally routed.
  public let region: Region? = .global

  /// The service this backend connects to.
  public let service: Service

  /// The wire protocol this backend speaks.
  public let apiProtocol: AIProtocol = .openAI

  /// OpenAI's chat-completions field names and defaults.
  public let dialect: OpenAIDialect

  /// Creates a backend for OpenAI.
  ///
  /// - Parameters:
  ///   - apiKey: The API credential.
  ///   - baseURL: The API root, useful for compatible gateways and test servers.
  ///   - endpoint: Which API to use. Defaults to choosing per model.
  public init(
    apiKey: String, baseURL: String = "https://api.openai.com/v1",
    endpoint: OpenAIEndpoint = .automatic, service: Service = .openAI,
    dialect: OpenAIDialect? = nil
  ) {
    self.apiKey = apiKey
    self.baseURL = baseURL
    self.endpoint = endpoint
    self.service = service
    self.dialect =
      dialect
      ?? OpenAIDialect(
        maxTokensField: "max_completion_tokens", reasoningEffort: .topLevel,
        sendsPromptCacheKey: true)
  }

  /// Encodes a canonical request as an OpenAI chat-completions POST.
  ///
  /// - Parameters:
  ///   - modelID: The endpoint-specific model identifier.
  ///   - request: The canonical conversation and generation options.
  ///   - stream: Whether to request server-sent events.
  /// - Returns: A configured HTTP request.
  /// - Throws: AIError for invalid endpoints or JSON encoding failures.
  public func encode(modelID: String, request: Request, stream: Bool) throws -> URLRequest {
    if endpoint.usesResponses(modelID: modelID, model: request.model) {
      return try openAIResponsesRequest(
        baseURL: baseURL, apiKey: apiKey, modelID: modelID, request: request, stream: stream)
    }
    return try openAIRequest(
      baseURL: baseURL, apiKey: apiKey, headers: [:], modelID: modelID,
      request: request, dialect: dialect, stream: stream)
  }

  /// Encodes a GET for `/models`.
  public func listModelsRequest(after cursor: String?) throws -> URLRequest {
    try getJSON(baseURL: baseURL, path: "/models", apiKey: apiKey)
  }

  /// Decodes `/models` into typed entries.
  public func decodeModelPage(status: Int, body: Data) throws -> ModelPage {
    try decodeOpenAIModelPage(status: status, body: body, service: service)
  }

  /// Decodes a complete chat-completions response.
  ///
  /// - Parameters:
  ///   - status: HTTP status code.
  ///   - body: Response body bytes.
  ///   - model: The canonical model requested by the caller.
  /// - Returns: A normalized response.
  /// - Throws: AIError for service errors or malformed response documents.
  public func decode(status: Int, body: Data, model: Model) throws -> Response {
    try decodeOpenAI(status: status, body: body, model: model)
  }

  /// Decodes one chat-completions stream event and updates accumulated state.
  ///
  /// - Parameters:
  ///   - event: The parsed server-sent event.
  ///   - assembly: Mutable state for the in-progress response.
  /// - Returns: Canonical text, reasoning, usage, or tool-call events.
  /// - Throws: AIError when a chunk or tool argument is malformed.
  public func decodeEvent(_ event: ServerSentEvent, assembly: inout StreamAssembly) throws
    -> [StreamEvent]
  {
    try decodeOpenAIEvent(event, assembly: &assembly)
  }
}

private func openAIChatToolChoice(_ choice: ToolChoice) -> JSONValue {
  switch choice {
  case .auto: .string("auto")
  case .disabled: .string("none")
  case .required: .string("required")
  case .tool(let name):
    .object(["type": .string("function"), "function": .object(["name": .string(name)])])
  }
}

/// A configurable endpoint that speaks the OpenAI chat-completions protocol.
///
/// Use this backend for self-hosted inference servers and compatible proxies.
/// Set service and region to match the model endpoint that should route here.
public struct OpenAICompatibleBackend: AIBackend {
  /// The API root; the chat-completions path is appended automatically.
  public let baseURL: String

  /// Optional API credential. When present, HTTPS is required.
  public let apiKey: String

  /// Service identity used during model routing.
  public let service: Service

  /// Protocol identity used during model routing.
  public let apiProtocol: AIProtocol

  /// Geographic scope guaranteed by this endpoint.
  public let region: Region?

  /// Provider-specific field names and token defaults.
  public let dialect: OpenAIDialect

  /// Additional HTTP headers sent with each request.
  public let headers: [String: String]

  /// Creates a configurable OpenAI-compatible backend.
  ///
  /// - Parameters:
  ///   - baseURL: The absolute HTTP or HTTPS API root.
  ///   - apiKey: Optional bearer credential.
  ///   - service: Service identity used by Router. Defaults to custom.
  ///   - apiProtocol: Protocol identity used by Router. Defaults to OpenAI.
  ///   - region: Geographic scope guaranteed by this endpoint.
  ///   - dialect: Token-limit and reasoning field customization.
  ///   - headers: Additional provider-specific HTTP headers.
  public init(
    baseURL: String, apiKey: String = "", service: Service = .custom,
    apiProtocol: AIProtocol = .openAI, region: Region? = nil,
    dialect: OpenAIDialect = OpenAIDialect(),
    headers: [String: String] = [:]
  ) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.service = service
    self.apiProtocol = apiProtocol
    self.region = region
    self.dialect = dialect
    self.headers = headers
  }

  /// Encodes a canonical request for this compatible endpoint.
  ///
  /// - Parameters:
  ///   - modelID: The endpoint-specific model identifier.
  ///   - request: The canonical conversation and generation options.
  ///   - stream: Whether to request server-sent events.
  /// - Returns: A configured HTTP request.
  /// - Throws: AIError for invalid endpoints or JSON encoding failures.
  public func encode(modelID: String, request: Request, stream: Bool) throws -> URLRequest {
    try openAIRequest(
      baseURL: baseURL, apiKey: apiKey, headers: headers, modelID: modelID,
      request: request, dialect: dialect, stream: stream)
  }

  /// Encodes a GET for `/models`.
  public func listModelsRequest(after cursor: String?) throws -> URLRequest {
    try getJSON(baseURL: baseURL, path: "/models", apiKey: apiKey, headers: headers)
  }

  /// Decodes `/models` into typed entries.
  public func decodeModelPage(status: Int, body: Data) throws -> ModelPage {
    try decodeOpenAIModelPage(status: status, body: body, service: service)
  }

  /// Decodes a complete chat-completions response.
  ///
  /// - Parameters:
  ///   - status: HTTP status code.
  ///   - body: Response body bytes.
  ///   - model: The canonical model requested by the caller.
  /// - Returns: A normalized response.
  /// - Throws: AIError for service errors or malformed response documents.
  public func decode(status: Int, body: Data, model: Model) throws -> Response {
    try decodeOpenAI(status: status, body: body, model: model)
  }

  /// Decodes one stream event and updates accumulated response state.
  ///
  /// - Parameters:
  ///   - event: The parsed server-sent event.
  ///   - assembly: Mutable state for the in-progress response.
  /// - Returns: Canonical updates produced by the chunk.
  /// - Throws: AIError when a chunk or tool argument is malformed.
  public func decodeEvent(_ event: ServerSentEvent, assembly: inout StreamAssembly) throws
    -> [StreamEvent]
  {
    try decodeOpenAIEvent(event, assembly: &assembly)
  }
}

private func openAIRequest(
  baseURL: String, apiKey: String, headers: [String: String],
  modelID: String, request: Request, dialect: OpenAIDialect,
  stream: Bool
) throws -> URLRequest {
  var document: [String: JSONValue] = [
    "model": .string(modelID),
    "messages": .array(try openAIMessages(request, dialect: dialect)),
    dialect.maxTokensField: .integer(Int64(request.maxTokens ?? dialect.fallbackMaxTokens)),
  ]
  var reserved: Set<String> = [
    "model", "messages", "tools", "response_format", "stream", "stream_options",
    dialect.maxTokensField,
  ]
  for (key, value) in dialect.additionalFields {
    document[key] = value
    reserved.insert(key)
  }
  if !request.tools.isEmpty {
    document["tools"] = .array(request.tools.map(openAITool))
    if let choice = request.toolChoice { document["tool_choice"] = openAIChatToolChoice(choice) }
  }
  if request.toolChoice != nil { reserved.insert("tool_choice") }
  if let schema = request.outputSchema {
    var format: [String: JSONValue] = [
      "name": .string(schema.name ?? "response"), "schema": schema.json,
    ]
    if let strict = schema.strict { format["strict"] = .bool(strict) }
    document["response_format"] = .object([
      "type": .string("json_schema"), "json_schema": .object(format),
    ])
  }
  if let effort = request.reasoningEffort, dialect.reasoningEffort != .unsupported {
    let (key, value) = try dialect.reasoningEffort.field(for: effort)
    if key == "chat_template_kwargs", case .object(let additions) = value,
      case .object(let existing)? = document[key]
    {
      document[key] = .object(existing.merging(additions) { _, new in new })
    } else {
      document[key] = value
    }
    reserved.insert(key)
  }
  if dialect.sendsPromptCacheKey, let key = request.caching?.key {
    document["prompt_cache_key"] = .string(key)
    reserved.insert("prompt_cache_key")
  }
  if stream {
    document["stream"] = .bool(true)
    document["stream_options"] = .object(["include_usage": .bool(true)])
  }
  document.merge(providerOptions: request.providerOptions, reserving: reserved)
  return try postJSON(
    baseURL: baseURL, path: "/chat/completions", apiKey: apiKey,
    headers: headers, document: .object(document), stream: stream)
}

private func openAIMessages(_ request: Request, dialect: OpenAIDialect) throws -> [JSONValue] {
  var result: [JSONValue] = []
  if let instructions = request.instructions {
    result.append(.object(["role": .string("system"), "content": .string(instructions)]))
  }
  for message in request.messages {
    switch message {
    case .user(let inputs):
      result.append(.object(["role": .string("user"), "content": .array(inputs.map(openAIInput))]))
    case .assistant(let outputs):
      var text = ""
      var reasoning = ""
      var calls: [JSONValue] = []
      for output in outputs {
        switch output {
        case .text(let part): text += part.text
        case .reasoning(let part): reasoning += part.text
        case .call(let call): calls.append(try openAICall(call))
        case .object(let value): text += try jsonText(value)
        case .image, .audio: break
        }
      }
      var fields: [String: JSONValue] = [
        "role": .string("assistant"),
        "content": text.isEmpty ? .null : .string(text),
      ]
      if let field = dialect.reasoningField, !reasoning.isEmpty {
        fields[field] = .string(reasoning)
      }
      if !calls.isEmpty { fields["tool_calls"] = .array(calls) }
      result.append(.object(fields))
    case .toolResults(let results):
      for toolResult in results {
        let text: String
        if let string = toolResult.output.stringValue {
          text = string
        } else {
          text = try jsonText(toolResult.output)
        }

        result.append(
          .object([
            "role": .string("tool"),
            "tool_call_id": .string(toolResult.id),
            "content": .string(text),
          ]))
      }
    }
  }
  return result
}

private func openAIInput(_ input: Input) -> JSONValue {
  switch input {
  case .text(let part):
    return .object(["type": .string("text"), "text": .string(part.text)])
  case .image(let part):
    return .object([
      "type": .string("image_url"),
      "image_url": .object(["url": .string(dataURL(part.mediaType, part.data))]),
    ])
  case .audio(let part):
    return .object([
      "type": .string("input_audio"),
      "input_audio": .object([
        "data": .string(part.data.base64EncodedString()),
        "format": .string(part.mediaType.localizedCaseInsensitiveContains("wav") ? "wav" : "mp3"),
      ]),
    ])
  case .video(let part):
    return openAIFile(name: "video", mediaType: part.mediaType, data: part.data)
  case .file(let part):
    return openAIFile(name: part.name, mediaType: part.mediaType, data: part.data)
  }
}

private func openAIFile(name: String, mediaType: String, data: Data) -> JSONValue {
  .object([
    "type": .string("file"),
    "file": .object([
      "filename": .string(name),
      "file_data": .string(dataURL(mediaType, data)),
    ]),
  ])
}

func dataURL(_ mediaType: String, _ data: Data) -> String {
  "data:\(mediaType);base64,\(data.base64EncodedString())"
}

private func openAITool(_ tool: Tool) -> JSONValue {
  .object([
    "type": .string("function"),
    "function": .object([
      "name": .string(tool.name),
      "description": .string(tool.description),
      "parameters": tool.inputSchema.json,
    ]),
  ])
}

private func openAICall(_ call: ToolCall) throws -> JSONValue {
  .object([
    "id": .string(call.id),
    "type": .string("function"),
    "function": .object([
      "name": .string(call.name),
      "arguments": .string(try jsonText(call.input)),
    ]),
  ])
}

func jsonText(_ value: JSONValue) throws -> String {
  guard let text = String(data: try value.encoded(), encoding: .utf8) else {
    throw AIError.malformed("A JSON value could not be encoded as UTF-8.")
  }
  return text
}

private func decodeOpenAI(status: Int, body: Data, model: Model) throws -> Response {
  guard (200..<300).contains(status) || !body.isEmpty else { throw AIError.status(status) }
  let document: [String: JSONValue]
  do { document = try jsonObject(body) } catch {
    if !(200..<300).contains(status) { throw AIError.status(status) }
    throw error
  }
  if let error = document["error"], error != .null {
    throw openAIServiceError(status: status, error: error)
  }
  if !(200..<300).contains(status) { throw openAIServiceError(status: status, error: .null) }
  if document["choices"] == nil, document["object"]?.stringValue == "response" {
    return try decodeResponsesDocument(document, model: model)
  }
  guard case .array(let choices)? = document["choices"], let first = choices.first,
    case .object(let choice) = first, case .object(let message)? = choice["message"]
  else {
    throw AIError.malformed("The OpenAI response contains no choices.")
  }
  var output: [Output] = []
  let reasoning =
    (message["reasoning_content"]?.stringValue ?? message["reasoning"]?.stringValue) ?? ""
  if !reasoning.isEmpty { output.append(.reasoning(Reasoning(text: reasoning))) }
  if let content = message["content"]?.stringValue, !content.isEmpty {
    output.append(.text(TextPart(content)))
  }
  if case .array(let calls)? = message["tool_calls"] {
    for value in calls {
      guard case .object(let call) = value,
        case .object(let function)? = call["function"]
      else { continue }
      let name = function["name"]?.stringValue ?? ""
      let arguments = function["arguments"]?.stringValue ?? "{}"
      let input: JSONValue
      do { input = try JSONValue.parse(Data(arguments.utf8)) } catch {
        throw AIError.malformed(
          "Arguments for \(name) are not valid JSON: \(error.localizedDescription)")
      }
      output.append(.call(ToolCall(id: call["id"]?.stringValue ?? "", name: name, input: input)))
    }
  }
  let usage = openAIUsage(document["usage"])
  return Response(
    model: model, output: output, usage: usage,
    finishReason: openAIFinish(choice["finish_reason"]?.stringValue),
    servedModel: document["model"]?.stringValue,
    providerMetadata: document["provider_metadata"])
}

func openAIServiceError(status: Int, error: JSONValue) -> AIError {
  guard case .object(let object) = error,
    let message = object["message"]?.stringValue, !message.isEmpty
  else {
    return .status(status)
  }
  let kind = object["type"]?.stringValue
  let resolved = status == 200 ? openAIStreamStatus(kind: kind, code: object["code"]) : status
  return .service(ServiceFailure(status: resolved, kind: kind, message: message))
}

/// Derives an HTTP-style status for an error carried inside a 200 stream.
private func openAIStreamStatus(kind: String?, code: JSONValue?) -> Int {
  let codeText = code?.stringValue ?? ""
  let names = [codeText, kind ?? ""]
  if names.contains(where: {
    $0 == "rate_limit_exceeded" || $0 == "insufficient_quota" || $0.contains("rate_limit")
  }) {
    return 429
  }
  if names.contains("invalid_api_key") || kind == "authentication_error" { return 401 }
  switch kind {
  case "invalid_request_error": return 400
  case "permission_error": return 403
  case "not_found_error": return 404
  case "service_unavailable", "overloaded_error", "server_overloaded": return 503
  case "timeout_error": return 504
  default: return 500
  }
}

func openAIUsage(_ value: JSONValue?) -> Usage {
  guard case .object(let usage)? = value else { return Usage() }
  let promptDetails: [String: JSONValue] =
    usage["prompt_tokens_details"].flatMap {
      if case .object(let value) = $0 { value } else { nil }
    } ?? [:]
  let completionDetails: [String: JSONValue] =
    usage["completion_tokens_details"].flatMap {
      if case .object(let value) = $0 { value } else { nil }
    } ?? [:]
  return Usage(
    inputTokens: number(usage["prompt_tokens"]),
    outputTokens: number(usage["completion_tokens"]),
    cacheReadTokens: number(promptDetails["cached_tokens"]),
    reasoningTokens: number(completionDetails["reasoning_tokens"]),
    cost: decimal(usage["cost"]))
}

func number(_ value: JSONValue?) -> Int? {
  guard let value else { return nil }
  switch value {
  case .integer(let value): return Int(exactly: value)
  case .number(let value): return Int(exactly: value)
  default: return nil
  }
}

func decimal(_ value: JSONValue?) -> Double? {
  guard let value else { return nil }
  switch value {
  case .integer(let value): return Double(value)
  case .number(let value): return value
  default: return nil
  }
}

private func openAIFinish(_ value: String?) -> FinishReason {
  switch value {
  case "length": .length
  case "tool_calls": .toolCall
  case "content_filter": .refusal
  default: .completed
  }
}

func decodeOpenAIEvent(_ event: ServerSentEvent, assembly: inout StreamAssembly) throws
  -> [StreamEvent]
{
  if event.data == "[DONE]" {
    var events = try assembly.endAllTools()
    events += try assembly.complete()
    return events
  }
  guard !event.data.isEmpty else { return [] }
  let chunk: [String: JSONValue]
  do { chunk = try jsonObject(Data(event.data.utf8)) } catch {
    throw AIError.malformed(
      "An OpenAI stream chunk is not valid JSON: \(error.localizedDescription)")
  }
  if let type = chunk["type"]?.stringValue, type.hasPrefix("response.") || type == "error" {
    return try decodeResponsesEvent(type: type, chunk: chunk, assembly: &assembly)
  }
  if let error = chunk["error"], error != .null {
    throw openAIServiceError(status: 200, error: error)
  }
  if assembly.servedModel == nil { assembly.servedModel = chunk["model"]?.stringValue }
  var events: [StreamEvent] = []
  if let usage = chunk["usage"], usage != .null {
    events += assembly.recordUsage(openAIUsage(usage))
  }
  guard case .array(let choices)? = chunk["choices"], let first = choices.first,
    case .object(let choice) = first,
    case .object(let delta)? = choice["delta"]
  else { return events }

  let thought = delta["reasoning_content"]?.stringValue ?? delta["reasoning"]?.stringValue ?? ""
  if !thought.isEmpty { events += assembly.appendReasoning(thought) }
  let content = delta["content"]?.stringValue ?? ""
  if !content.isEmpty {
    events += assembly.endReasoning()
    events += assembly.appendText(content)
  }
  if case .array(let calls)? = delta["tool_calls"] {
    for value in calls {
      guard case .object(let call) = value else { continue }
      let key = "tool-\(number(call["index"]) ?? 0)"
      let function: [String: JSONValue]
      if case .object(let value)? = call["function"] {
        function = value
      } else {
        function = [:]
      }
      let id = call["id"]?.stringValue ?? ""
      let name = function["name"]?.stringValue ?? ""
      if !id.isEmpty || !name.isEmpty {
        events += assembly.endReasoning()
        events += assembly.endText()
        events += assembly.beginTool(key: key, id: id, name: name)
      }
      if let fragment = function["arguments"]?.stringValue, !fragment.isEmpty {
        events += assembly.appendToolJSON(fragment, key: key)
      }
    }
  }
  if let reason = choice["finish_reason"]?.stringValue {
    assembly.finishReason = openAIFinish(reason)
    events += try assembly.endAllTools()
    events += assembly.endText()
    events += assembly.endReasoning()
  }
  return events
}
