import AI
import Foundation
import Testing

@Suite struct TimeoutCancellationTests {
  @Test func firstByteTimeoutIsRetriedWhenRetryIsEnabled() async throws {
    let clock = TestClock(holding: .seconds(5))
    let transport = ScriptedTransport([.hang, .body(200, [:], "ok")])
    let gw = gateway([TestBackend(key: "a")], transport: transport,
      timeout: TimeoutPolicy(firstByte: .seconds(5), total: nil), clock: clock)
    let task = Task { try await gw.generate(testRequest) }
    while await transport.requestedKeys.isEmpty { await Task.yield() }
    await clock.fireTimers()
    _ = try await task.value
    #expect(await transport.requestedKeys.count == 2)
  }

  @Test func firstByteTimeoutIsReportedWhenNothingElseWorks() async {
    let clock = TestClock(holding: .seconds(5))
    let transport = ScriptedTransport([.hang])
    let gw = gateway([TestBackend(key: "a")], transport: transport, retry: .none,
      timeout: TimeoutPolicy(firstByte: .seconds(5), total: nil), clock: clock)
    let task = Task { try await gw.generate(testRequest) }
    while await transport.requestedKeys.isEmpty { await Task.yield() }
    await clock.fireTimers()
    await #expect(throws: AIError.transport("The request timed out waiting for the first byte.")) {
      try await task.value
    }
  }

  @Test func totalTimeoutBoundsTheWholeCall() async {
    let clock = TestClock(holding: .seconds(1))
    let transport = ScriptedTransport([.hang])
    let gw = gateway([TestBackend(key: "a")], transport: transport,
      timeout: TimeoutPolicy(firstByte: nil, total: .seconds(1)), clock: clock)
    let task = Task { try await gw.generate(testRequest) }
    while await transport.requestedKeys.isEmpty { await Task.yield() }
    await clock.fireTimers()
    await #expect(throws: AIError.transport("The request exceeded its total time limit.")) {
      try await task.value
    }
  }

  @Test func cancellationPropagatesFromTransport() async throws {
    let transport = ScriptedTransport([.hang])
    let gw = gateway([TestBackend(key: "a")], transport: transport, clock: .system)
    let task = Task { try await gw.generate(testRequest) }
    while await transport.requestedKeys.isEmpty { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func cancellationPropagatesFromBackoffSleep() async throws {
    let transport = ScriptedTransport([.body(503, [:], "down")])
    let gw = gateway([TestBackend(key: "a")], transport: transport, clock: .system)
    let task = Task { try await gw.generate(testRequest) }
    while await transport.requestedKeys.isEmpty { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.requestedKeys.count == 1)
  }

  @Test func cancellingStreamConsumerStopsTheRequest() async throws {
    let transport = ScriptedTransport([.hang])
    let gw = gateway([TestBackend(key: "a")], transport: transport, clock: .system)
    let task = Task { () -> Int in
      var count = 0
      for try await _ in gw.stream(testRequest) { count += 1 }
      return count
    }
    while await transport.requestedKeys.isEmpty { await Task.yield() }
    task.cancel()
    _ = try? await task.value
    #expect(await transport.requestedKeys.count == 1)
  }
}
