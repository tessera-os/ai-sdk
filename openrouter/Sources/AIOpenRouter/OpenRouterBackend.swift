import AI
import AIOpenAI
import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import ModelBoard

/// Provider-selection controls understood by OpenRouter.
public struct OpenRouterOptions: Sendable, Equatable {
  /// Preferred upstream providers, in order.
  public var order: [String]?

  /// Whether OpenRouter may try another provider after a failure.
  public var allowFallbacks: Bool?

  /// Whether providers that collect prompt data may serve the request.
  public var dataCollection: Bool?

  /// Creates OpenRouter upstream-selection preferences.
  ///
  /// - Parameters:
  ///   - order: Preferred upstream providers. Nil uses OpenRouter's default.
  ///   - allowFallbacks: Whether to retry another upstream after a failure.
  ///   - dataCollection: Whether providers that collect prompts may be selected.
  public init(
    order: [String]? = nil,
    allowFallbacks: Bool? = nil,
    dataCollection: Bool? = nil
  ) {
    self.order = order
    self.allowFallbacks = allowFallbacks
    self.dataCollection = dataCollection
  }
}

/// An OpenAI-compatible backend with OpenRouter provider routing.
public struct OpenRouterBackend: AIBackend {
  /// API key sent as a bearer token over HTTPS.
  public let apiKey: String

  /// Optional OpenRouter upstream selection settings.
  public let options: OpenRouterOptions

  /// Display title sent in the X-Title header.
  public let title: String

  private let openAI: OpenAICompatibleBackend

  private let baseURL: String

  /// OpenRouter is treated as a globally routed service.
  public var region: Region? { .global }

  /// The service this backend connects to.
  public var service: Service { .openRouter }

  /// OpenRouter accepts the OpenAI chat-completions protocol.
  public var apiProtocol: AIProtocol { .openAI }

  /// Creates a backend for OpenRouter's OpenAI-compatible API.
  ///
  /// - Parameters:
  ///   - apiKey: The OpenRouter API key.
  ///   - options: Optional upstream provider-selection preferences.
  ///   - baseURL: The API root. Override it for compatible gateways or test servers.
  ///   - title: The client title shown in OpenRouter request metadata.
  public init(
    apiKey: String,
    options: OpenRouterOptions = OpenRouterOptions(),
    baseURL: String = "https://openrouter.ai/api/v1",
    title: String = "Kira AI SDK"
  ) {
    self.apiKey = apiKey
    self.options = options
    self.title = title
    self.baseURL = baseURL
    self.openAI = OpenAICompatibleBackend(
      baseURL: baseURL,
      apiKey: apiKey,
      service: .openRouter,
      region: .global,
      dialect: OpenAIDialect(reasoningField: "reasoning", reasoningEffort: .nested),
      headers: ["X-Title": title]
    )
  }

  /// Encodes a request with optional OpenRouter provider preferences.
  ///
  /// Caller provider options are merged with the backend's provider block and
  /// take precedence when they contain the same top-level field.
  ///
  /// - Parameters:
  ///   - modelID: The OpenRouter model identifier selected by Router.
  ///   - request: The canonical conversation and generation options.
  ///   - stream: Whether to request server-sent events.
  /// - Returns: A configured HTTP POST request.
  /// - Throws: AIError for invalid endpoints or JSON encoding failures.
  public func encode(modelID: String, request: Request, stream: Bool) throws -> URLRequest {
    var routedRequest = request
    var providerOptions: [String: JSONValue] = [:]

    if let provider = providerBlock {
      providerOptions["provider"] = provider
    }

    if let callerOptions = request.providerOptions,
      case .object(let values) = callerOptions
    {
      providerOptions.merge(values, uniquingKeysWith: { _, callerValue in callerValue })
    }

    routedRequest.providerOptions = providerOptions.isEmpty ? nil : .object(providerOptions)
    return try openAI.encode(modelID: modelID, request: routedRequest, stream: stream)
  }

  /// Encodes a GET for `/models`, OpenRouter's catalog of every routable model.
  public func listModelsRequest(after cursor: String?) throws -> URLRequest {
    try getJSON(
      baseURL: baseURL, path: "/models", apiKey: apiKey, headers: ["X-Title": title])
  }

  /// Decodes the catalog with context length, modalities, pricing, and supported parameters.
  public func decodeModelPage(status: Int, body: Data) throws -> ModelPage {
    try decodeOpenRouterModelPage(status: status, body: body)
  }

  /// Decodes a complete OpenRouter response using the shared chat-completions codec.
  ///
  /// - Parameters:
  ///   - status: HTTP status code.
  ///   - body: Response body bytes.
  ///   - model: The canonical model requested by the caller.
  /// - Returns: A normalized response with OpenRouter cost metadata when present.
  /// - Throws: AIError for service failures or malformed response documents.
  public func decode(status: Int, body: Data, model: Model) throws -> Response {
    try openAI.decode(status: status, body: body, model: model)
  }

  /// Decodes one OpenRouter event using the shared chat-completions codec.
  ///
  /// - Parameters:
  ///   - event: The parsed server-sent event.
  ///   - assembly: Mutable state for the in-progress response.
  /// - Returns: Canonical updates produced by the event.
  /// - Throws: AIError when the event or accumulated tool arguments are malformed.
  public func decodeEvent(
    _ event: ServerSentEvent,
    assembly: inout StreamAssembly
  ) throws -> [StreamEvent] {
    try openAI.decodeEvent(event, assembly: &assembly)
  }

  private var providerBlock: JSONValue? {
    var fields: [String: JSONValue] = [:]

    if let order = options.order {
      fields["order"] = .array(order.map(JSONValue.string))
    }

    if let allowFallbacks = options.allowFallbacks {
      fields["allow_fallbacks"] = .bool(allowFallbacks)
    }

    if let dataCollection = options.dataCollection {
      fields["data_collection"] = .string(dataCollection ? "allow" : "deny")
    }

    return fields.isEmpty ? nil : .object(fields)
  }
}
