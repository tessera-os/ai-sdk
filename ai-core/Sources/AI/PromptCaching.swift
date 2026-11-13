import Foundation

/// A place in a request where Anthropic may cache the prompt prefix.
public enum CacheBreakpoint: Sendable, Equatable, Hashable {
  /// The last tool definition, caching every tool.
  case tools
  /// The last system block, caching tools and system instructions.
  case system
  /// The last content block of the final message, caching the whole conversation so far.
  case lastMessage
}

/// Prompt-caching hints for a request.
///
/// Every request caches by default (`Request.caching` is `.standard`, one
/// hour); `nil` turns caching off. Anthropic needs explicit `cache_control`
/// breakpoints; OpenAI routes requests with the same key to the same cache. A
/// backend ignores the hint that belongs to another provider.
public struct PromptCaching: Sendable, Equatable {
  /// Where Anthropic places ephemeral `cache_control` markers.
  public var breakpoints: Set<CacheBreakpoint>
  /// How long Anthropic keeps what the breakpoints cache.
  public var lifetime: CacheLifetime
  /// OpenAI's `prompt_cache_key`, which groups requests that share a prefix.
  public var key: String?

  /// Creates caching hints.
  ///
  /// - Parameters:
  ///   - breakpoints: Anthropic breakpoints. Defaults to the system block and the last message.
  ///   - lifetime: How long the cached prefix lives. Defaults to one hour.
  ///   - key: An OpenAI cache routing key, such as a conversation identifier.
  public init(
    breakpoints: Set<CacheBreakpoint> = [.system, .lastMessage], lifetime: CacheLifetime = .oneHour,
    key: String? = nil
  ) {
    self.breakpoints = breakpoints
    self.lifetime = lifetime
    self.key = key
  }

  /// Breakpoints on the system block and the last message, as Harmony's C++
  /// gateway placed them, kept for one hour. Every request's default.
  public static let standard = PromptCaching()
}
