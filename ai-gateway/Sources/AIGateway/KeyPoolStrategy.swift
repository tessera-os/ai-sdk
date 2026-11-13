import AI
import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A route strategy that fails over across every backend serving a model.
///
/// List several backends for one service (for example one per API key) on the
/// gateway. Each round tries healthy slots in order, then cooling ones. A 401
/// or 429 cools the slot (429 honors Retry-After) and moves to the next slot
/// immediately. Transient failures (429, 408, 5xx, overloaded, network,
/// first-byte timeout) also fail over; once every slot has failed, the round is
/// retried after backoff per `Resilience.retry`. When every slot failed with
/// 401 only, the error is surfaced without a retry round.
public struct KeyPoolStrategy: RouteStrategy {
  /// Shared cooldown state.
  public var store: any KeyPoolStore
  /// Cooldown durations.
  public var policy: KeyPoolPolicy

  /// Creates a strategy over a store.
  public init(store: any KeyPoolStore = InMemoryKeyPoolStore(), policy: KeyPoolPolicy = KeyPoolPolicy()) {
    self.store = store
    self.policy = policy
  }

  /// Runs the operation with rotation, failover, and backoff.
  public func run<T: Sendable>(
    routes: [Route], resilience: Resilience,
    operation: @Sendable (Route) async throws -> T
  ) async throws -> T {
    let clock = resilience.clock
    let rounds = max(1, resilience.retry.maxAttempts)
    var last = AIError.transport("No attempt was made.")
    for round in 0..<rounds {
      try Task.checkCancellation()
      var retryable = false
      var retryAfter: Duration?
      for route in await ordered(routes, now: await clock.now()) {
        do {
          return try await operation(route)
        } catch {
          if error is CancellationError || Task.isCancelled { throw CancellationError() }
          let failure = ClassifiedFailure(error)
          last = failure.error
          let slot = route.keyPoolSlot
          if failure.status == 401 {
            let until = await clock.now().addingTimeInterval(policy.authCooldown.timeInterval)
            await store.setCooldown(for: slot, until: until)
          } else if failure.action == .fatal {
            throw failure.error
          } else {
            retryable = true
            if failure.status == 429 {
              let cooldown = failure.retryAfter ?? policy.rateLimitCooldown
              let until = await clock.now().addingTimeInterval(cooldown.timeInterval)
              await store.setCooldown(for: slot, until: until)
            }
            if let after = failure.retryAfter, after > (retryAfter ?? .zero) { retryAfter = after }
          }
        }
      }
      if !retryable || round == rounds - 1 { throw last }
      var delay = resilience.retry.delay(afterRound: round, random: await clock.randomUnit())
      if let retryAfter {
        if retryAfter > resilience.retry.maxRetryAfter { throw last }
        delay = max(delay, retryAfter)
      }
      try await clock.sleep(for: delay)
    }
    throw last
  }

  /// Healthy routes first (original order), then cooling routes soonest-first.
  private func ordered(_ routes: [Route], now: Date) async -> [Route] {
    var healthy: [Route] = []
    var cooling: [(Route, Date)] = []
    for route in routes {
      if let until = await store.cooldownEnd(for: route.keyPoolSlot), until > now {
        cooling.append((route, until))
      } else {
        healthy.append(route)
      }
    }
    return healthy + cooling.sorted { $0.1 < $1.1 }.map(\.0)
  }
}

extension Gateway {
  /// Creates a gateway that rotates across a pool of backends.
  ///
  /// - Parameters:
  ///   - pool: Backends in preference order, typically one per API key.
  ///   - catalog: Application-specific model endpoint bindings.
  ///   - store: Cooldown state; pass a shared implementation for multi-instance use.
  ///   - policy: Cooldown durations.
  ///   - transport: Optional network layer replacing URLSession.
  ///   - resilience: Timeouts and retry. Set `retry` to allow backoff rounds.
  public init(
    pool: [any AIBackend], catalog: RemoteCatalog = RemoteCatalog(),
    store: any KeyPoolStore = InMemoryKeyPoolStore(), policy: KeyPoolPolicy = KeyPoolPolicy(),
    transport: (any HTTPTransport)? = nil, resilience: Resilience = Resilience(retry: RetryPolicy())
  ) {
    self.init(
      backends: pool, catalog: catalog, transport: transport, resilience: resilience,
      strategy: KeyPoolStrategy(store: store, policy: policy))
  }
}

