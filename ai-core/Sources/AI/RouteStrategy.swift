import Foundation

/// Decides how a gateway runs one operation across its candidate routes.
///
/// Core ships `RetryStrategy` (first route, opt-in retry). The AIGateway
/// package provides key-pool rotation and cross-backend failover.
///
/// Implementations receive raw attempt errors, classify them with `ClassifiedFailure(_:)`,
/// and must throw an AIError (or CancellationError) when giving up.
public protocol RouteStrategy: Sendable {
  /// Runs `operation`, choosing among `routes` and deciding about retries.
  func run<T: Sendable>(
    routes: [Route], resilience: Resilience,
    operation: @Sendable (Route) async throws -> T
  ) async throws -> T
}

/// Uses the first route and retries transient failures per `Resilience.retry`.
public struct RetryStrategy: RouteStrategy {
  /// Creates the default strategy.
  public init() {}

  /// Runs the operation on the first route with backoff and Retry-After handling.
  public func run<T: Sendable>(
    routes: [Route], resilience: Resilience,
    operation: @Sendable (Route) async throws -> T
  ) async throws -> T {
    let clock = resilience.clock
    let rounds = max(1, resilience.retry.maxAttempts)
    guard let route = routes.first else { throw AIError.transport("No route available.") }
    var last = AIError.transport("No attempt was made.")
    for round in 0..<rounds {
      do {
        return try await operation(route)
      } catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        let failure = ClassifiedFailure(error)
        last = failure.error
        if failure.action == .fatal || round == rounds - 1 { throw last }
        var delay = resilience.retry.delay(afterRound: round, random: await clock.randomUnit())
        if let after = failure.retryAfter {
          if after > resilience.retry.maxRetryAfter { throw last }
          delay = max(delay, after)
        }
        try await clock.sleep(for: delay)
      }
    }
    throw last
  }
}
