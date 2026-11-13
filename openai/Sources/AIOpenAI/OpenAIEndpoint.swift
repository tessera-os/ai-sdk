import AI
import Foundation
import ModelBoard

/// Which OpenAI API an `OpenAIBackend` sends requests to.
public enum OpenAIEndpoint: Sendable, Equatable {
  /// Reasoning models use `/responses`; every other model uses `/chat/completions`.
  case automatic
  /// Always `/chat/completions`.
  case chatCompletions
  /// Always `/responses`.
  case responses

  /// Decides whether a request goes to `/responses`.
  ///
  /// - Parameters:
  ///   - modelID: The provider model identifier.
  ///   - model: The canonical model, whose reasoning capability also counts.
  /// - Returns: True when the Responses API should be used.
  func usesResponses(modelID: String, model: Model) -> Bool {
    switch self {
    case .chatCompletions: false
    case .responses: true
    case .automatic: openAIIsReasoningModel(modelID: modelID, model: model)
    }
  }
}

/// Whether an OpenAI model reasons: the GPT-5 and later families, the o-series,
/// Codex models, or any model whose capabilities declare reasoning.
func openAIIsReasoningModel(modelID: String, model: Model) -> Bool {
  if model.capabilities.reasoning { return true }
  let id = modelID.lowercased()
  if id.hasPrefix("codex") { return true }
  if id.hasPrefix("gpt-") {
    let rest = id.dropFirst(4)
    if let first = rest.first, let major = first.wholeNumberValue { return major >= 5 }
    return false
  }
  if id.hasPrefix("o"), let second = id.dropFirst().first, second.isNumber { return true }
  return false
}

/// How a chat-completions service takes `Request.reasoningEffort`.
public enum OpenAIReasoningParameter: Sendable, Equatable {
  /// The service ignores reasoning effort; the request field is not sent.
  case unsupported
  /// A top-level `reasoning_effort` string, as OpenAI's Chat Completions takes it.
  case topLevel
  /// A nested `reasoning` object, as OpenRouter takes it.
  case nested

  /// Builds the request field for an effort.
  ///
  /// - Parameter effort: The requested reasoning.
  /// - Returns: The top-level field name and its value.
  /// - Throws: AIError.unsupportedCapability when a token budget is sent to a
  ///   service with no budget field.
  func field(for effort: ReasoningEffort) throws -> (String, JSONValue) {
    switch (self, effort) {
    case (.nested, .budget(let tokens)):
      return ("reasoning", .object(["max_tokens": .integer(Int64(tokens))]))
    case (_, .budget):
      throw AIError.unsupportedCapability("reasoning token budget")
    case (.nested, _):
      return ("reasoning", .object(["effort": .string(effort.openAIName)]))
    default:
      return ("reasoning_effort", .string(effort.openAIName))
    }
  }
}

extension ReasoningEffort {
  /// The effort name sent to OpenAI and OpenRouter, the level's own name.
  var openAIName: String {
    switch self {
    case .off: "none"
    case .minimal: "minimal"
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    case .xhigh: "xhigh"
    case .max: "max"
    case .budget: "medium"
    }
  }
}
