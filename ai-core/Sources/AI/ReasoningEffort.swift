import Foundation

/// How much reasoning a model should spend before answering.
///
/// One typed option covers every provider; each backend maps it to its own
/// wire shape:
///
/// - Anthropic: adaptive thinking with `output_config.effort`, or extended
///   thinking with `budget_tokens` for models that only take a budget.
/// - OpenAI: `reasoning.effort` (Responses) or `reasoning_effort` (Chat Completions).
/// - OpenRouter: the unified `reasoning` object.
///
/// Thinking that the provider returns surfaces as `StreamEvent.reasoningDelta`
/// and `Output.reasoning`.
public enum ReasoningEffort: Sendable, Equatable, Hashable {
  /// Reasoning is switched off where the model allows it. Named `off` so it never reads as `Optional.none`.
  case off
  /// The smallest amount of reasoning the provider offers.
  case minimal
  /// Light reasoning.
  case low
  /// Balanced reasoning.
  case medium
  /// Thorough reasoning.
  case high
  /// Very thorough reasoning, on models that offer a level above high.
  case xhigh
  /// The most reasoning the provider allows, sent as `max`.
  case max
  /// An explicit thinking-token budget.
  ///
  /// Anthropic and OpenRouter accept this directly. OpenAI has no token budget,
  /// so its backend rejects it with `AIError.unsupportedCapability`.
  case budget(Int)

  /// Whether this value asks the provider not to reason at all.
  public var disablesReasoning: Bool {
    switch self {
    case .off, .minimal: true
    default: false
    }
  }
}
