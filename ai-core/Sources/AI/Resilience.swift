import Foundation

/// Retry behaviour for transient failures (429, 408, 5xx, overloaded, network errors).
public struct RetryPolicy: Sendable, Equatable {
  /// Total rounds, including the first. Each round tries every available key/backend once.
  public var maxAttempts: Int
  /// Delay before the first retry.
  public var initialDelay: Duration
  /// Growth factor applied per retry.
  public var multiplier: Double
  /// Upper bound for the computed backoff.
  public var maxDelay: Duration
  /// Fraction (0...1) of each delay that is randomized downward.
  public var jitter: Double
  /// Longest Retry-After the gateway will wait; a longer one stops retrying.
  public var maxRetryAfter: Duration

  /// Creates a policy. Defaults: 3 rounds, 0.5 s doubling to 30 s, 50% jitter, 60 s Retry-After cap.
  public init(
    maxAttempts: Int = 3, initialDelay: Duration = .milliseconds(500), multiplier: Double = 2,
    maxDelay: Duration = .seconds(30), jitter: Double = 0.5, maxRetryAfter: Duration = .seconds(60)
  ) {
    self.maxAttempts = maxAttempts
    self.initialDelay = initialDelay
    self.multiplier = multiplier
    self.maxDelay = maxDelay
    self.jitter = jitter
    self.maxRetryAfter = maxRetryAfter
  }

  /// A policy that never retries.
  public static let none = RetryPolicy(maxAttempts: 1)

  /// Backoff before the retry that follows round `round` (0-based), given a random value in 0...1.
  public func delay(afterRound round: Int, random: Double) -> Duration {
    let base = min(initialDelay.timeInterval * pow(multiplier, Double(round)), maxDelay.timeInterval)
    let spread = min(max(jitter, 0), 1)
    return .seconds(base * (1 - spread * random))
  }
}

/// Per-request time limits.
public struct TimeoutPolicy: Sendable, Equatable {
  /// Longest wait for response headers on one attempt. Nil disables.
  public var firstByte: Duration?
  /// Longest time for the whole call, retries and streaming included. Nil disables.
  public var total: Duration?

  /// Creates a policy. Defaults: 60 s to first byte, 600 s overall.
  public init(firstByte: Duration? = .seconds(60), total: Duration? = .seconds(600)) {
    self.firstByte = firstByte
    self.total = total
  }

  /// No limits.
  public static let none = TimeoutPolicy(firstByte: nil, total: nil)
}

/// Time and randomness used by timeouts, backoff, and cooldowns.
///
/// Inject a test double to make retry and timeout behaviour deterministic.
public protocol ResilienceClock: Sendable {
  /// Suspends for a duration; throws CancellationError when the task is cancelled.
  func sleep(for duration: Duration) async throws
  /// The current wall-clock time.
  func now() async -> Date
  /// A random value in 0...1 used for jitter.
  func randomUnit() async -> Double
}

/// The system clock: `Task.sleep(for:)`, `Date()`, and system randomness.
public struct SystemClock: ResilienceClock {
  /// Creates the system clock.
  public init() {}

  /// Suspends with `Task.sleep(for:)`.
  public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }

  /// The current date.
  public func now() async -> Date { Date() }

  /// A uniformly random value in 0...1.
  public func randomUnit() async -> Double { Double.random(in: 0...1) }
}

extension ResilienceClock where Self == SystemClock {
  /// The system clock.
  public static var system: SystemClock { SystemClock() }
}

/// All resilience settings for a Gateway. Retry is opt-in (default `.none`); timeouts are on by default.
public struct Resilience: Sendable {
  /// Retry and backoff settings.
  public var retry: RetryPolicy
  /// Time limits.
  public var timeout: TimeoutPolicy
  /// Time source.
  public var clock: any ResilienceClock

  /// Creates settings; every part has a sensible default.
  public init(
    retry: RetryPolicy = .none, timeout: TimeoutPolicy = TimeoutPolicy(),
    clock: any ResilienceClock = SystemClock()
  ) {
    self.retry = retry
    self.timeout = timeout
    self.clock = clock
  }
}

extension Duration {
  /// The duration in seconds, with sub-second precision.
  public var timeInterval: TimeInterval {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
