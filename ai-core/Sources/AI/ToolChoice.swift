import Foundation

/// How the model may use the tools supplied in a request.
///
/// A choice only has an effect when the request carries tools. Backends map
/// the cases to each provider's `tool_choice` field.
public enum ToolChoice: Sendable, Equatable, Hashable {
  /// The model decides whether to call a tool.
  case auto
  /// The model must answer without calling a tool.
  case disabled
  /// The model must call some tool.
  case required
  /// The model must call the named tool.
  case tool(named: String)
}
