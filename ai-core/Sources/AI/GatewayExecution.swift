import Foundation

/// Runs `operation` under the total timeout using the gateway's strategy.
func executeWithResilience<T: Sendable>(
  routes: [Route], resilience: Resilience, strategy: any RouteStrategy,
  operation: @escaping @Sendable (Route) async throws -> T
) async throws -> T {
  do {
    return try await withTimeout(
      resilience.timeout.total, clock: resilience.clock, error: GatewayTimeout.total
    ) {
      try await strategy.run(routes: routes, resilience: resilience, operation: operation)
    }
  } catch GatewayTimeout.total {
    throw AIError.transport("The request exceeded its total time limit.")
  }
}

/// Races `operation` against a sleep; the sleep wins with `error`.
func withTimeout<T: Sendable>(
  _ limit: Duration?, clock: any ResilienceClock, error: GatewayTimeout,
  _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  guard let limit else { return try await operation() }
  return try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await clock.sleep(for: limit)
      throw error
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else { throw error }
    return result
  }
}
