import Foundation

/// How long a provider keeps a cached prompt prefix after its last use.
///
/// Anthropic takes it as the `ttl` of each `cache_control` marker. OpenAI
/// caches every long prefix by itself and keeps it as long as its own
/// retention allows, so it has nothing to send.
public enum CacheLifetime: Sendable, Equatable, Hashable {
  /// Five minutes (`ttl` `5m`).
  case fiveMinutes
  /// One hour (`ttl` `1h`), the default.
  case oneHour
}
