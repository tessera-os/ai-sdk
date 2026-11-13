import Foundation
import ModelBoard

/// Which kinds of thinking a listed model supports.
public struct ThinkingSupport: Sendable, Equatable {
  /// Whether the model takes adaptive thinking (effort levels).
  public var adaptive: Bool
  /// Whether the model takes extended thinking with a token budget.
  public var budget: Bool
  /// The effort levels the model accepts, lowest first. Empty when it reports none.
  public var efforts: [ReasoningEffort]

  /// Creates a thinking-support description.
  public init(adaptive: Bool = false, budget: Bool = false, efforts: [ReasoningEffort] = []) {
    self.adaptive = adaptive
    self.budget = budget
    self.efforts = efforts
  }
}

/// Per-token prices a service reports for a listed model, in US dollars.
public struct ListedPricing: Sendable, Equatable {
  /// Dollars per input token.
  public var input: Double?
  /// Dollars per output token.
  public var output: Double?

  /// Creates a price record.
  public init(input: Double? = nil, output: Double? = nil) {
    self.input = input
    self.output = output
  }
}

/// One model as reported live by a service's model-list endpoint.
///
/// Services report different subsets, so every figure beyond the identifier is optional.
public struct ModelListing: Sendable, Equatable {
  /// The service that listed the model.
  public var service: Service
  /// The identifier to use in requests to that service.
  public var id: String
  /// A human-readable name, when the service provides one.
  public var displayName: String?
  /// When the model was released or registered, when reported.
  public var created: Date?
  /// The owning organization, when reported (OpenAI's `owned_by`).
  public var owner: String?
  /// The input context window in tokens, when reported.
  public var contextWindow: Int?
  /// The largest output in tokens, when reported.
  public var maxOutputTokens: Int?
  /// The input modalities, when reported.
  public var inputModalities: Set<Modality>?
  /// The output modalities, when reported.
  public var outputModalities: Set<Modality>?
  /// Whether the model supports tool calling, when reported.
  public var supportsTools: Bool?
  /// Whether the model supports schema-constrained output, when reported.
  public var supportsStructuredOutput: Bool?
  /// How the model thinks, when reported.
  public var thinking: ThinkingSupport?
  /// Prices, when reported.
  public var pricing: ListedPricing?
  /// The built-in catalog model that matches this entry, filled by `Gateway.listModels()`.
  public var known: Model?

  /// Creates a listing with the identifier and any figures the service reported.
  public init(
    service: Service, id: String, displayName: String? = nil, created: Date? = nil,
    owner: String? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil,
    inputModalities: Set<Modality>? = nil, outputModalities: Set<Modality>? = nil,
    supportsTools: Bool? = nil, supportsStructuredOutput: Bool? = nil,
    thinking: ThinkingSupport? = nil, pricing: ListedPricing? = nil, known: Model? = nil
  ) {
    self.service = service
    self.id = id
    self.displayName = displayName
    self.created = created
    self.owner = owner
    self.contextWindow = contextWindow
    self.maxOutputTokens = maxOutputTokens
    self.inputModalities = inputModalities
    self.outputModalities = outputModalities
    self.supportsTools = supportsTools
    self.supportsStructuredOutput = supportsStructuredOutput
    self.thinking = thinking
    self.pricing = pricing
    self.known = known
  }
}

/// One page of a service's model list.
public struct ModelPage: Sendable, Equatable {
  /// The entries on this page.
  public var models: [ModelListing]
  /// The cursor to pass to fetch the next page, or nil on the last page.
  public var next: String?

  /// Creates a page.
  public init(models: [ModelListing], next: String? = nil) {
    self.models = models
    self.next = next
  }
}

/// A service whose model list could not be fetched.
public struct ModelListFailure: Sendable, Equatable {
  /// The service that failed.
  public var service: Service
  /// The error from the last backend tried for that service.
  public var error: AIError

  /// Creates a failure record.
  public init(service: Service, error: AIError) {
    self.service = service
    self.error = error
  }
}

/// The merged result of listing models across a gateway's backends.
public struct ModelList: Sendable, Equatable {
  /// Entries from every service that answered, deduplicated by service and identifier.
  public var models: [ModelListing]
  /// Services that could not be listed. A revoked key on one service never hides the others.
  public var failures: [ModelListFailure]

  /// Creates a result.
  public init(models: [ModelListing], failures: [ModelListFailure] = []) {
    self.models = models
    self.failures = failures
  }
}

/// Parses the epoch-seconds or ISO 8601 timestamps services use for model creation dates.
///
/// - Parameter value: A JSON number of epoch seconds, or an ISO 8601 string.
/// - Returns: The date, or nil when the value is missing or unparseable.
public func listedDate(_ value: JSONValue?) -> Date? {
  switch value {
  case .integer(let seconds)?: return Date(timeIntervalSince1970: Double(seconds))
  case .number(let seconds)?: return Date(timeIntervalSince1970: seconds)
  case .string(let text)?:
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  default: return nil
  }
}
