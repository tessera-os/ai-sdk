import AI
import Foundation

/// Which Claude models take which kind of thinking.
///
/// Newer Claude models use adaptive thinking steered by an effort level; older
/// ones only take an extended-thinking token budget. Matching is by substring
/// of the provider model identifier. The defaults reproduce the lists in
/// Harmony's C++ gateway.
public struct AnthropicThinkingRules: Sendable, Equatable {
  /// Identifier fragments of models that only accept a thinking budget.
  public var budgetOnly: [String]
  /// Identifier fragments of models whose thinking cannot be disabled.
  public var alwaysThinking: [String]

  /// Creates a rule set.
  public init(
    budgetOnly: [String] = [
      "haiku-4-5", "sonnet-4-5", "opus-4-5", "opus-4-1", "opus-4-2025", "sonnet-4-2025",
      "3-7", "3-5",
    ],
    alwaysThinking: [String] = ["claude-opus-5-5", "claude-fable-5"]
  ) {
    self.budgetOnly = budgetOnly
    self.alwaysThinking = alwaysThinking
  }
}

/// The thinking-related fields to add to a Messages request.
struct ThinkingPlan: Equatable {
  /// The `thinking` object, or nil to leave it out.
  var thinking: JSONValue?
  /// The `output_config.effort` level, or nil.
  var effort: String?
  /// The possibly raised `max_tokens`.
  var maxTokens: Int
}

/// Maps a canonical reasoning request to Anthropic's thinking fields.
///
/// - Parameters:
///   - effort: The requested amount of reasoning.
///   - modelID: The provider model identifier.
///   - maxTokens: The output limit before thinking is accounted for.
///   - rules: Which models take budgets and which cannot stop thinking.
/// - Returns: The fields to send. A budget never exceeds `maxTokens - 1024`
///   and raises `maxTokens` to leave 1024 tokens for the answer.
func anthropicThinkingPlan(
  effort: ReasoningEffort, modelID: String, maxTokens: Int, rules: AnthropicThinkingRules
) -> ThinkingPlan {
  var effort = effort
  if effort.disablesReasoning, rules.alwaysThinking.contains(where: modelID.contains) {
    effort = .low
  }
  if effort.disablesReasoning {
    return ThinkingPlan(thinking: .object(["type": .string("disabled")]), effort: nil, maxTokens: maxTokens)
  }
  let requested: Int?
  switch effort {
  case .budget(let tokens): requested = tokens
  case .low where rules.budgetOnly.contains(where: modelID.contains): requested = 4000
  case .medium where rules.budgetOnly.contains(where: modelID.contains): requested = 12000
  case .high where rules.budgetOnly.contains(where: modelID.contains): requested = 24000
  case .xhigh where rules.budgetOnly.contains(where: modelID.contains): requested = 32000
  case .max where rules.budgetOnly.contains(where: modelID.contains): requested = 32000
  default: requested = nil
  }
  if let requested {
    let budget = max(1024, min(requested, maxTokens - 1024))
    return ThinkingPlan(
      thinking: .object(["type": .string("enabled"), "budget_tokens": .integer(Int64(budget))]),
      effort: nil, maxTokens: max(maxTokens, budget + 1024))
  }
  let level: String
  switch effort {
  case .low: level = "low"
  case .medium: level = "medium"
  case .high: level = "high"
  case .xhigh: level = "xhigh"
  default: level = "max"
  }
  return ThinkingPlan(
    thinking: .object(["type": .string("adaptive"), "display": .string("summarized")]),
    effort: level, maxTokens: maxTokens)
}
