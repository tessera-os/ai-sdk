import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import ModelBoard

/// A provider protocol adapter for a model service.
///
/// Backends translate canonical SDK values to and from the service's wire
/// format. They do not perform network I/O; Gateway owns URLSession requests,
/// response streaming, cancellation, and transport errors.
public protocol AIBackend: Sendable {
  /// The service reached by this backend.
  var service: Service { get }
  /// The wire protocol used for requests to the service.
  var apiProtocol: AIProtocol { get }
  /// The geographic scope this backend can guarantee, when known.
  var region: Region? { get }

  /// Encodes one generation as an HTTP request.
  ///
  /// - Parameters:
  ///   - modelID: The provider-specific identifier selected by Router.
  ///   - request: The canonical request to encode.
  ///   - stream: Whether the request should ask for server-sent events.
  /// - Returns: A URLRequest ready for Gateway's URLSession.
  /// - Throws: An AIError for invalid endpoints or unsupported request shapes.
  func encode(modelID: String, request: Request, stream: Bool) throws -> URLRequest

  /// Decodes a complete HTTP response.
  ///
  /// - Parameters:
  ///   - status: The HTTP status code.
  ///   - body: The response body.
  ///   - model: The canonical model requested by the caller.
  /// - Returns: The provider response converted to canonical values.
  /// - Throws: An AIError for provider failures or malformed response data.
  func decode(status: Int, body: Data, model: Model) throws -> Response

  /// Decodes one server-sent event and updates the in-progress response.
  ///
  /// - Parameters:
  ///   - event: The event fields parsed from the HTTP stream.
  ///   - assembly: Mutable state shared across this response's events.
  /// - Returns: Zero or more canonical stream events.
  /// - Throws: An AIError when the event contains a provider or decoding error.
  func decodeEvent(_ event: ServerSentEvent, assembly: inout StreamAssembly) throws -> [StreamEvent]

  /// Encodes the request that fetches one page of the service's model list.
  ///
  /// The default implementation throws `AIError.unsupportedCapability`.
  ///
  /// - Parameter cursor: The `ModelPage.next` value of the previous page, or nil for the first page.
  /// - Returns: A GET request ready for Gateway's transport.
  /// - Throws: An AIError for invalid endpoints or when the backend cannot list models.
  func listModelsRequest(after cursor: String?) throws -> URLRequest

  /// Decodes one page of the service's model list.
  ///
  /// The default implementation throws `AIError.unsupportedCapability`.
  ///
  /// - Parameters:
  ///   - status: The HTTP status code.
  ///   - body: The response body.
  /// - Returns: The page's typed entries and the cursor of the next page.
  /// - Throws: An AIError for provider failures or malformed bodies.
  func decodeModelPage(status: Int, body: Data) throws -> ModelPage
}

extension AIBackend {
  /// Reports that this backend cannot list models.
  public func listModelsRequest(after cursor: String?) throws -> URLRequest {
    throw AIError.unsupportedCapability("model listing")
  }

  /// Reports that this backend cannot list models.
  public func decodeModelPage(status: Int, body: Data) throws -> ModelPage {
    throw AIError.unsupportedCapability("model listing")
  }
}

/// One event parsed from a server-sent events response.
public struct ServerSentEvent: Sendable, Equatable {
  /// The optional event name from the event field.
  public var event: String?
  /// The optional event identifier from the id field.
  public var id: String?
  /// The event data, with multiple data lines joined by newline characters.
  public var data: String

  /// Creates a parsed server-sent event.
  public init(event: String? = nil, id: String? = nil, data: String) {
    self.event = event
    self.id = id
    self.data = data
  }
}

/// A redacted account of an HTTP exchange for diagnostics.
public struct Exchange: Sendable, Equatable {
  /// The full request URL.
  public var url: URL
  /// The provider-specific model identifier used in the request.
  public var modelID: String
  /// Request headers in display form; recognized credential headers have their values redacted.
  public var requestHeaders: [String]
  /// The encoded request body.
  public var requestBody: Data
  /// The HTTP status received, when the response has started.
  public var status: Int?
  /// Response headers keyed by their displayed names.
  public var responseHeaders: [String: String]
  /// Response bytes received so far.
  public var responseBody: Data

  /// Captures a request before sending it, replacing credential header values with placeholders.
  ///
  /// - Parameters:
  ///   - request: The encoded HTTP request.
  ///   - modelID: The endpoint's provider-specific model identifier.
  public init(request: URLRequest, modelID: String) {
    self.url = request.url ?? URL(string: "about:blank")!
    self.modelID = modelID
    self.requestHeaders = (request.allHTTPHeaderFields ?? [:]).keys.sorted().map { name in
      let value = request.value(forHTTPHeaderField: name) ?? ""
      let sensitive = ["authorization", "api-key", "x-api-key"].contains(name.lowercased())
      return "\(name): \(sensitive ? "(\(name))" : value)"
    }
    self.requestBody = request.httpBody ?? Data()
    self.responseHeaders = [:]
    self.responseBody = Data()
  }
}

/// Per-response state shared by streaming protocol decoders.
public struct StreamAssembly: Sendable {
  /// The canonical model being answered.
  public let model: Model
  /// Output blocks assembled from the received stream.
  public private(set) var output: [Output] = []
  /// Usage values reported so far.
  public var usage = Usage()
  /// The most recent provider finish reason.
  public var finishReason: FinishReason = .completed
  /// The provider's served model identifier, when reported.
  public var servedModel: String?
  /// Provider metadata preserved from the response.
  public var providerMetadata: JSONValue?
  /// Whether a terminal completion or failure has been recorded.
  public private(set) var isFinished = false

  private var openText: [String: Int] = [:]
  private var openReasoning: [String: Int] = [:]
  private var pendingTools: [String: PendingTool] = [:]
  private var pendingToolOrder: [String] = []

  /// Creates an empty stream assembly for the requested model.
  public init(model: Model) {
    self.model = model
  }

  /// Opens a text run identified by key, if it has not already been opened.
  ///
  /// - Parameter key: A provider block or channel identifier. Use the default
  ///   key for a protocol that has one sequential text run.
  /// - Returns: A text-start event when this call opens a new run.
  public mutating func beginText(key: String = "text") -> [StreamEvent] {
    guard openText[key] == nil else { return [] }
    output.append(.text(TextPart("")))
    openText[key] = output.count - 1
    return [.textStart]
  }

  /// Appends a text fragment to a keyed run, opening it if necessary.
  ///
  /// - Parameters:
  ///   - text: The fragment received from the provider.
  ///   - key: The run identifier used by beginText and endText.
  /// - Returns: A start event when needed, followed by the fragment event.
  public mutating func appendText(_ text: String, key: String = "text") -> [StreamEvent] {
    var events: [StreamEvent] = []
    if openText[key] == nil { events += beginText(key: key) }
    if let index = openText[key], case .text(var part) = output[index] {
      part.text += text
      output[index] = .text(part)
    }
    events.append(.textDelta(TextPart(text)))
    return events
  }

  /// Closes a text run.
  ///
  /// - Parameter key: The key supplied when the run was opened.
  /// - Returns: A text-end event when a matching run was open.
  public mutating func endText(key: String = "text") -> [StreamEvent] {
    guard openText.removeValue(forKey: key) != nil else { return [] }
    return [.textEnd]
  }

  /// Opens a reasoning run identified by key.
  ///
  /// - Parameter key: A provider block or channel identifier.
  /// - Returns: A reasoning-start event when this call opens a new run.
  public mutating func beginReasoning(key: String = "reasoning") -> [StreamEvent] {
    guard openReasoning[key] == nil else { return [] }
    output.append(.reasoning(Reasoning(text: "")))
    openReasoning[key] = output.count - 1
    return [.reasoningStart]
  }

  /// Appends reasoning text and optionally records its provider signature.
  ///
  /// - Parameters:
  ///   - text: The reasoning fragment received from the provider.
  ///   - signature: A signature needed to replay the reasoning block.
  ///   - key: The run identifier used by beginReasoning and endReasoning.
  /// - Returns: A start event when needed, followed by the fragment event.
  public mutating func appendReasoning(
    _ text: String, signature: String? = nil, source: Service? = nil,
    key: String = "reasoning"
  ) -> [StreamEvent] {
    var events: [StreamEvent] = []
    if openReasoning[key] == nil { events += beginReasoning(key: key) }
    if let index = openReasoning[key], case .reasoning(var part) = output[index] {
      part.text += text
      if let signature { part.signature = signature }
      if let source { part.source = source }
      output[index] = .reasoning(part)
    }
    events.append(.reasoningDelta(Reasoning(text: text, signature: signature, source: source)))
    return events
  }

  /// Closes a reasoning run.
  ///
  /// - Parameter key: The key supplied when the run was opened.
  /// - Returns: A reasoning-end event when a matching run was open.
  public mutating func endReasoning(key: String = "reasoning") -> [StreamEvent] {
    guard openReasoning.removeValue(forKey: key) != nil else { return [] }
    return [.reasoningEnd]
  }

  /// Attaches a provider signature to the currently open reasoning block.
  ///
  /// - Parameters:
  ///   - signature: The provider signature received in a separate event.
  ///   - source: The service that issued the signature.
  ///   - key: The run identifier supplied when reasoning was opened.
  public mutating func setReasoningSignature(
    _ signature: String, source: Service? = nil, key: String = "reasoning"
  ) {
    guard let index = openReasoning[key], case .reasoning(var part) = output[index] else { return }
    part.signature = signature
    if let source { part.source = source }
    output[index] = .reasoning(part)
  }

  /// Opens or updates a pending tool call.
  ///
  /// - Parameters:
  ///   - key: The provider's stable identifier for this call during streaming.
  ///   - id: The call identifier used in later conversation history.
  ///   - name: The function name.
  /// - Returns: A tool-call-start event when the call is first observed.
  public mutating func beginTool(key: String, id: String, name: String) -> [StreamEvent] {
    if pendingTools[key] == nil {
      pendingTools[key] = PendingTool(id: id, name: name, json: "")
      pendingToolOrder.append(key)
      return [.toolCallStart(ToolCallOpened(id: id, name: name))]
    }
    if !id.isEmpty { pendingTools[key]?.id = id }
    if !name.isEmpty { pendingTools[key]?.name = name }
    return []
  }

  /// Appends a JSON argument fragment to an open tool call.
  ///
  /// - Parameters:
  ///   - json: Partial JSON text from the provider.
  ///   - key: The provider's identifier for this call.
  /// - Returns: A tool-call-delta event when the call is open.
  public mutating func appendToolJSON(_ json: String, key: String) -> [StreamEvent] {
    guard var pending = pendingTools[key] else { return [] }
    pending.json += json
    pendingTools[key] = pending
    return [.toolCallDelta(ToolInputDelta(id: pending.id, json: json))]
  }

  /// Returns the argument text accumulated so far for an open tool call.
  ///
  /// - Parameter key: The provider's identifier for this call.
  /// - Returns: The partial JSON, or nil when no such call is open.
  public func toolInput(key: String) -> String? {
    pendingTools[key]?.json
  }

  /// Parses and closes one pending tool call.
  ///
  /// - Parameter key: The provider's identifier for this call.
  /// - Returns: A tool-call-end event when the call was open.
  /// - Throws: AIError.malformed if the accumulated argument text is invalid JSON.
  public mutating func endTool(key: String) throws(AIError) -> [StreamEvent] {
    guard let pending = pendingTools.removeValue(forKey: key) else { return [] }
    pendingToolOrder.removeAll { $0 == key }
    let data = pending.json.isEmpty ? Data("{}".utf8) : Data(pending.json.utf8)
    let value: JSONValue
    do { value = try JSONValue.parse(data) } catch {
      throw AIError.malformed("Tool arguments were not valid JSON: \(error.localizedDescription)")
    }
    let call = ToolCall(id: pending.id, name: pending.name, input: value)
    output.append(.call(call))
    return [.toolCallEnd(call)]
  }

  /// Parses and closes every pending tool call in stable key order.
  ///
  /// - Returns: The completion events for the calls that were open.
  /// - Throws: AIError.malformed if any accumulated arguments are invalid JSON.
  public mutating func endAllTools() throws(AIError) -> [StreamEvent] {
    var events: [StreamEvent] = []
    for key in pendingToolOrder {
      events += try endTool(key: key)
    }
    return events
  }

  /// Merges newly reported usage values into the accumulated usage record.
  ///
  /// Nil values do not erase values reported earlier in the same response.
  ///
  /// - Parameter usage: The newest usage values from a provider event.
  /// - Returns: A usage event containing the merged values.
  public mutating func recordUsage(_ usage: Usage) -> [StreamEvent] {
    self.usage.inputTokens = usage.inputTokens ?? self.usage.inputTokens
    self.usage.outputTokens = usage.outputTokens ?? self.usage.outputTokens
    self.usage.cacheReadTokens = usage.cacheReadTokens ?? self.usage.cacheReadTokens
    self.usage.cacheWriteTokens = usage.cacheWriteTokens ?? self.usage.cacheWriteTokens
    self.usage.reasoningTokens = usage.reasoningTokens ?? self.usage.reasoningTokens
    self.usage.cost = usage.cost ?? self.usage.cost
    return [.usage(self.usage)]
  }

  /// Closes open runs, creates the terminal response event, and marks the assembly finished.
  ///
  /// - Parameter reason: An optional final finish reason supplied by the protocol.
  /// - Returns: End events for open runs followed by completion, or no events
  ///   if the assembly already ended.
  /// - Throws: AIError.malformed when a pending tool call contains invalid JSON.
  public mutating func complete(_ reason: FinishReason? = nil) throws(AIError) -> [StreamEvent] {
    guard !isFinished else { return [] }
    var events = try endAllTools()
    for key in Array(openText.keys) {
      events += endText(key: key)
    }
    for key in Array(openReasoning.keys) {
      events += endReasoning(key: key)
    }
    finishReason = reason ?? finishReason
    isFinished = true
    let response = Response(
      model: model, output: output, usage: usage,
      finishReason: finishReason, servedModel: servedModel,
      providerMetadata: providerMetadata)
    events.append(.completed(response))
    return events
  }

  /// Marks the stream terminal with a decoding or provider failure.
  ///
  /// - Parameter error: The error to report.
  /// - Returns: One failure event, or no events if the assembly already ended.
  public mutating func fail(_ error: AIError) -> [StreamEvent] {
    guard !isFinished else { return [] }
    isFinished = true
    return [.failed(error)]
  }
}

private struct PendingTool: Sendable {
  var id: String
  var name: String
  var json: String
}

/// Converts a complete response to the equivalent sequence of stream events.
///
/// This is used when a streaming request receives a whole JSON response instead
/// of an event stream.
///
/// - Parameter response: The completed response to expand.
/// - Returns: Bracketed output events followed by usage and completion.
/// - Throws: An encoding error if a tool call's input cannot be encoded as JSON.
public func eventsOf(_ response: Response) throws -> [StreamEvent] {
  var events: [StreamEvent] = []
  for item in response.output {
    switch item {
    case .text(let part): events += [.textStart, .textDelta(part), .textEnd]
    case .reasoning(let part): events += [.reasoningStart, .reasoningDelta(part), .reasoningEnd]
    case .call(let call):
      let inputData = try call.input.encoded()
      guard let inputJSON = String(data: inputData, encoding: .utf8) else {
        throw AIError.malformed("The input of tool call \(call.id) could not be encoded as UTF-8.")
      }
      events += [
        .toolCallStart(ToolCallOpened(id: call.id, name: call.name)),
        .toolCallDelta(ToolInputDelta(id: call.id, json: inputJSON)),
        .toolCallEnd(call),
      ]
    case .image, .audio, .object: break
    }
  }
  events.append(.usage(response.usage))
  events.append(.completed(response))
  return events
}

/// Creates an HTTP POST request with a JSON body and the appropriate Accept header.
///
/// - Parameters:
///   - baseURL: An absolute HTTP or HTTPS endpoint root.
///   - path: The path appended to the endpoint root.
///   - apiKey: Optional credential. If supplied, the endpoint must use HTTPS.
///   - headers: Additional provider headers.
///   - credentialHeader: The header name used for the credential.
///   - credentialPrefix: Text prepended to the credential value, such as Bearer.
///   - document: The JSON request body.
///   - stream: Whether the request expects server-sent events.
/// - Returns: A configured POST request.
/// - Throws: AIError.invalidEndpoint for malformed URLs or cleartext credentials.
public func postJSON(
  baseURL: String, path: String, apiKey: String?, headers: [String: String] = [:],
  credentialHeader: String = "Authorization", credentialPrefix: String = "Bearer ",
  document: JSONValue, stream: Bool
) throws -> URLRequest {
  let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
  let target = base + path
  guard let url = URL(string: target), let scheme = url.scheme?.lowercased(),
    ["https", "http"].contains(scheme), url.host != nil
  else {
    throw AIError.invalidEndpoint("Invalid endpoint URL: \(target)")
  }
  if let apiKey, !apiKey.isEmpty, scheme != "https" {
    throw AIError.invalidEndpoint("API keys require an https endpoint: \(target)")
  }
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
  if let apiKey, !apiKey.isEmpty {
    request.setValue(credentialPrefix + apiKey, forHTTPHeaderField: credentialHeader)
  }
  for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
  request.httpBody = try document.encoded()
  return request
}

/// Parses a JSON object response body.
///
/// - Parameter data: The response bytes.
/// - Returns: The object's fields.
/// - Throws: AIError.malformed when the document is not a JSON object.
public func jsonObject(_ data: Data) throws -> [String: JSONValue] {
  guard case .object(let object) = try JSONValue.parse(data) else {
    throw AIError.malformed("Expected a JSON object.")
  }
  return object
}

/// Encodes a JSON value as UTF-8 for protocols that nest JSON in a string field.
///
/// - Parameter value: The value to encode.
/// - Returns: The compact JSON document.
/// - Throws: An error when the value cannot be represented as JSON.
public func jsonStringify(_ value: JSONValue) throws -> String {
  guard let text = String(data: try value.encoded(), encoding: .utf8) else {
    throw AIError.malformed("A JSON value could not be encoded as UTF-8.")
  }
  return text
}

/// Reads an integer-valued object member, accepting integral JSON numbers.
///
/// - Parameters:
///   - object: The JSON object to search.
///   - key: The member name.
/// - Returns: The integer value, or nil when the member is absent or not integral.
public func jsonInt(_ object: [String: JSONValue], _ key: String) -> Int? {
  guard let value = object[key] else { return nil }
  switch value {
  case .integer(let number): return Int(exactly: number)
  case .number(let number): return Int(exactly: number)
  default: return nil
  }
}

/// Reads a string-valued object member.
///
/// - Parameters:
///   - object: The JSON object to search.
///   - key: The member name.
/// - Returns: The string value, or nil when the member is absent or not a string.
public func jsonString(_ object: [String: JSONValue], _ key: String) -> String? {
  object[key]?.stringValue
}

/// Creates an HTTP GET request with the JSON Accept header.
///
/// - Parameters:
///   - baseURL: An absolute HTTP or HTTPS endpoint root.
///   - path: The path appended to the endpoint root, including any query string.
///   - apiKey: Optional credential. If supplied, the endpoint must use HTTPS.
///   - headers: Additional provider headers.
///   - credentialHeader: The header name used for the credential.
///   - credentialPrefix: Text prepended to the credential value, such as Bearer.
/// - Returns: A configured GET request.
/// - Throws: AIError.invalidEndpoint for malformed URLs or cleartext credentials.
public func getJSON(
  baseURL: String, path: String, apiKey: String?, headers: [String: String] = [:],
  credentialHeader: String = "Authorization", credentialPrefix: String = "Bearer "
) throws -> URLRequest {
  var request = try postJSON(
    baseURL: baseURL, path: path, apiKey: apiKey, headers: headers,
    credentialHeader: credentialHeader, credentialPrefix: credentialPrefix,
    document: .null, stream: false)
  request.httpMethod = "GET"
  request.httpBody = nil
  request.setValue(nil, forHTTPHeaderField: "Content-Type")
  return request
}
