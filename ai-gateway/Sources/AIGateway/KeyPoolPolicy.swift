import Foundation

/// How long a key or backend is skipped after it fails.
public struct KeyPoolPolicy: Sendable, Equatable {
  /// Cooldown after a 401 (bad or revoked key).
  public var authCooldown: Duration
  /// Cooldown after a 429 when the response gave no Retry-After.
  public var rateLimitCooldown: Duration

  /// Creates a policy. Defaults: 300 s after 401, 30 s after 429.
  public init(authCooldown: Duration = .seconds(300), rateLimitCooldown: Duration = .seconds(30)) {
    self.authCooldown = authCooldown
    self.rateLimitCooldown = rateLimitCooldown
  }
}
