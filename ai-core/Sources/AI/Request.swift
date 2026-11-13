import Foundation
import ModelBoard

/// A canonical generation request before it is encoded for a provider.
///
/// A request carries the complete conversation history. The selected model is
/// validated against caller-supplied input, tools, and structured-output needs
/// before the gateway performs network I/O.
public struct Request: Sendable, Equatable {
  /// The model identity, capabilities, and known endpoint bindings.
  public var model: Model
  /// Conversation turns supplied to the model, in chronological order.
  public var messages: [Message]
  /// Optional system-level instructions, sent separately from conversation history.
  public var instructions: String?
  /// Functions the model may request the caller to run.
  public var tools: [Tool]
  /// Maximum number of output tokens. Each provider applies its own default when nil.
  public var maxTokens: Int?
  /// JSON Schema requested for the model's structured response.
  public var outputSchema: Schema?
  /// How the model may use `tools`. Nil leaves the provider's default (automatic).
  public var toolChoice: ToolChoice?
  /// How much the model should reason. Nil leaves the provider's default.
  public var reasoningEffort: ReasoningEffort?
  /// Prompt caching, on by default (`.standard`: one hour). Nil turns it off.
  public var caching: PromptCaching?
  /// Provider-specific request fields merged into the encoded document.
  public var providerOptions: JSONValue?

  /// Creates a generation request.
  ///
  /// - Parameters:
  ///   - model: The model to route the request to.
  ///   - messages: The conversation history, in chronological order.
  ///   - instructions: Optional system instructions.
  ///   - tools: Optional tool definitions.
  ///   - maxTokens: Optional output-token limit.
  ///   - outputSchema: Optional structured-output schema.
  ///   - toolChoice: Optional constraint on tool use.
  ///   - reasoningEffort: Optional reasoning amount or budget.
  ///   - caching: Prompt caching. Defaults to `.standard`; nil turns it off.
  ///   - providerOptions: Optional provider-specific JSON fields.
  public init(
    model: Model, messages: [Message], instructions: String? = nil,
    tools: [Tool] = [], maxTokens: Int? = nil, outputSchema: Schema? = nil,
    toolChoice: ToolChoice? = nil, reasoningEffort: ReasoningEffort? = nil,
    caching: PromptCaching? = .standard, providerOptions: JSONValue? = nil
  ) {
    self.model = model
    self.messages = messages
    self.instructions = instructions
    self.tools = tools
    self.maxTokens = maxTokens
    self.outputSchema = outputSchema
    self.toolChoice = toolChoice
    self.reasoningEffort = reasoningEffort
    self.caching = caching
    self.providerOptions = providerOptions
  }
}

/// Token and cost figures reported by a provider.
///
/// Values remain optional because providers report different subsets. The SDK
/// does not estimate cost from a local pricing table.
public struct Usage: Codable, Sendable, Equatable {
  /// Number of input tokens reported by the provider.
  public var inputTokens: Int?
  /// Number of output tokens reported by the provider.
  public var outputTokens: Int?
  /// Input tokens served from the provider's prompt cache.
  public var cacheReadTokens: Int?
  /// Input tokens written into the provider's prompt cache.
  public var cacheWriteTokens: Int?
  /// Output tokens attributed to reasoning, when reported separately.
  public var reasoningTokens: Int?
  /// Cost reported by the provider, in the provider's currency unit.
  public var cost: Double?

  /// Creates a usage value from the figures a provider reports.
  ///
  /// Unreported figures should remain nil rather than being represented as zero.
  public init(
    inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil,
    cacheWriteTokens: Int? = nil, reasoningTokens: Int? = nil, cost: Double? = nil
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheReadTokens = cacheReadTokens
    self.cacheWriteTokens = cacheWriteTokens
    self.reasoningTokens = reasoningTokens
    self.cost = cost
  }
}

/// A completed generation response.
public struct Response: Sendable, Equatable {
  /// The canonical model requested by the caller.
  public var model: Model
  /// Typed text, reasoning, media, JSON, and tool calls returned by the model.
  public var output: [Output]
  /// Token and cost figures reported by the service.
  public var usage: Usage
  /// Why the provider stopped generating.
  public var finishReason: FinishReason
  /// The provider's served model identifier, when it reports one.
  public var servedModel: String?
  /// Provider-returned JSON not represented by the canonical response fields.
  public var providerMetadata: JSONValue?

  /// Creates a response from canonical output and provider-reported metadata.
  public init(
    model: Model, output: [Output], usage: Usage = Usage(), finishReason: FinishReason,
    servedModel: String? = nil, providerMetadata: JSONValue? = nil
  ) {
    self.model = model
    self.output = output
    self.usage = usage
    self.finishReason = finishReason
    self.servedModel = servedModel
    self.providerMetadata = providerMetadata
  }
}

/// Structured error information returned by a model service.
public struct ServiceFailure: Sendable, Equatable {
  /// HTTP status code returned by the service.
  public var status: Int
  /// Provider-specific error type, when supplied.
  public var kind: String?
  /// Human-readable message returned by the provider.
  public var message: String

  /// Creates a service failure value.
  public init(status: Int, kind: String? = nil, message: String) {
    self.status = status
    self.kind = kind
    self.message = message
  }
}

/// A local validation, routing, transport, or provider failure.
///
/// Gateway operations throw this error before producing a response. Local
/// validation and routing failures occur before any request is sent.
public enum AIError: Error, Sendable, Equatable, LocalizedError {
  /// No configured backend matches any endpoint bound to the requested model.
  case noRoute(ModelIdentity)
  /// The request requires a capability the model does not provide.
  case unsupportedCapability(String)
  /// A user message contains an input modality the model does not accept.
  case unsupportedInputModality(Modality)
  /// The endpoint URL is invalid or would send credentials without TLS.
  case invalidEndpoint(String)
  /// The HTTP exchange could not be completed.
  case transport(String)
  /// The service returned a structured error document.
  case service(ServiceFailure)
  /// The service returned an unsuccessful status without a structured error.
  case status(Int)
  /// The response body or stream event could not be decoded.
  case malformed(String)
  /// The service stopped after reaching the output-token limit.
  case truncated(Int?)

  /// A concise description suitable for logs or a user-facing error surface.
  public var errorDescription: String? {
    switch self {
    case .noRoute(let identity):
      return
        "No backend can serve \(identity.provider.rawValue)/\(identity.family.rawValue)/\(identity.version)."
    case .unsupportedCapability(let name): return "The model does not support \(name)."
    case .unsupportedInputModality(let modality):
      return "The model does not accept \(modality.rawValue) input."
    case .invalidEndpoint(let message), .malformed(let message), .transport(let message):
      return message
    case .service(let failure): return "\(failure.status): \(failure.message)"
    case .status(let status): return "The service returned HTTP \(status)."
    case .truncated(let tokens):
      let tokenDescription = tokens.map { " after \($0) output tokens" } ?? ""
      return "The response was truncated\(tokenDescription)."
    }
  }
}

/// Checks a request against its model's declared capabilities.
///
/// Validation considers user-supplied input modalities, tool use, and
/// structured-output requests. It returns the first issue found so callers can
/// fail locally without sending a doomed request.
///
/// - Parameter request: The request to validate.
/// - Returns: The first capability error, or nil when the request is supported.
public func validate(_ request: Request) -> AIError? {
  for message in request.messages {
    guard case .user(let inputs) = message else { continue }
    for input in inputs {
      let modality = inputModality(input)
      if !request.model.acceptsInput(modality) { return .unsupportedInputModality(modality) }
    }
  }
  if !request.tools.isEmpty && !request.model.capabilities.toolCalling {
    return .unsupportedCapability("tool-calling")
  }
  if request.outputSchema != nil && !request.model.capabilities.structuredOutput {
    return .unsupportedCapability("structured-output")
  }
  return nil
}
