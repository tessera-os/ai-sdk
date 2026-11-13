import AI
import Foundation
import Testing

@Suite struct RetryTests {
  @Test func retriesTransientStatusesWithExponentialBackoff() async throws {
    let clock = TestClock()
    let transport = ScriptedTransport([
      .body(503, [:], "down"), .body(500, [:], "down"), .body(200, [:], "ok"),
    ])
    let gw = gateway([TestBackend(key: "a")], transport: transport,
      retry: RetryPolicy(maxAttempts: 4), clock: clock)
    let response = try await gw.generate(testRequest)
    #expect(response.output == [.text(TextPart("ok"))])
    #expect(await transport.requestedKeys.count == 3)
    #expect(await clock.sleeps == [.milliseconds(500), .seconds(1)])
  }

  @Test func jitterShrinksDelay() async throws {
    let clock = TestClock(random: 1)
    let transport = ScriptedTransport([.body(503, [:], "x"), .body(200, [:], "ok")])
    let gw = gateway([TestBackend(key: "a")], transport: transport, clock: clock)
    _ = try await gw.generate(testRequest)
    #expect(await clock.sleeps == [.milliseconds(250)])
  }

  @Test func backoffIsCappedAtMaxDelay() {
    let policy = RetryPolicy(
      initialDelay: .seconds(10), multiplier: 4, maxDelay: .seconds(30), jitter: 0)
    #expect(policy.delay(afterRound: 3, random: 0) == .seconds(30))
  }

  @Test func honorsRetryAfterSeconds() async throws {
    let clock = TestClock()
    let transport = ScriptedTransport([
      .body(429, ["Retry-After": "7"], "slow down"), .body(200, [:], "ok"),
    ])
    let gw = gateway([TestBackend(key: "a")], transport: transport, clock: clock)
    _ = try await gw.generate(testRequest)
    #expect(await clock.sleeps == [.seconds(7)])
  }

  @Test func parsesRetryAfterHTTPDate() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let later = Date(timeIntervalSince1970: 1_700_000_012)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    #expect(RetryAfter(header: formatter.string(from: later), now: now)?.delay == .seconds(12))
    #expect(RetryAfter(header: "soon", now: now) == nil)
    #expect(RetryAfter(header: nil, now: now) == nil)
  }

  @Test func excessiveRetryAfterStopsRetrying() async {
    let clock = TestClock()
    let transport = ScriptedTransport([
      .body(429, ["Retry-After": "3600"], "no"), .body(200, [:], "ok"),
    ])
    let gw = gateway([TestBackend(key: "a")], transport: transport, clock: clock)
    await #expect(throws: AIError.self) { try await gw.generate(testRequest) }
    #expect(await transport.requestedKeys.count == 1)
    #expect(await clock.sleeps.isEmpty)
  }

  @Test func retriesOverloadedAndNetworkErrors() async throws {
    let transport = ScriptedTransport([
      .body(529, [:], "overloaded"), .fail(.networkConnectionLost), .body(200, [:], "ok"),
    ])
    let gw = gateway([TestBackend(key: "a")], transport: transport, clock: TestClock())
    _ = try await gw.generate(testRequest)
    #expect(await transport.requestedKeys.count == 3)
  }

  @Test func doesNotRetryClientErrors() async {
    let transport = ScriptedTransport([.body(400, [:], "bad"), .body(200, [:], "ok")])
    let gw = gateway([TestBackend(key: "a")], transport: transport, clock: TestClock())
    await #expect(throws: AIError.service(ServiceFailure(status: 400, message: "bad"))) {
      try await gw.generate(testRequest)
    }
    #expect(await transport.requestedKeys.count == 1)
  }

  @Test func givesUpAfterMaxAttempts() async {
    let clock = TestClock()
    let transport = ScriptedTransport([.body(503, [:], "down")])
    let gw = gateway([TestBackend(key: "a")], transport: transport,
      retry: RetryPolicy(maxAttempts: 3), clock: clock)
    await #expect(throws: AIError.self) { try await gw.generate(testRequest) }
    #expect(await transport.requestedKeys.count == 3)
    #expect(await clock.sleeps.count == 2)
  }

  @Test func noRetryPolicyFailsImmediately() async {
    let transport = ScriptedTransport([.body(503, [:], "down"), .body(200, [:], "ok")])
    let gw = gateway([TestBackend(key: "a")], transport: transport, retry: .none, clock: TestClock())
    await #expect(throws: AIError.self) { try await gw.generate(testRequest) }
    #expect(await transport.requestedKeys.count == 1)
  }

  @Test func coreUsesOnlyTheFirstBackendAndTreats401AsFatal() async {
    let transport = ScriptedTransport(byKey: [
      "a": [.body(401, [:], "bad")], "b": [.body(200, [:], "ok")],
    ])
    let gw = gateway([TestBackend(key: "a"), TestBackend(key: "b")], transport: transport,
      clock: TestClock())
    await #expect(throws: AIError.self) { try await gw.generate(testRequest) }
    #expect(await transport.requestedKeys == ["a"])
  }

  @Test func retryIsOptIn() async {
    let transport = ScriptedTransport([.body(503, [:], "down"), .body(200, [:], "ok")])
    let gw = Gateway(
      backends: [TestBackend(key: "a")], transport: transport,
      resilience: Resilience(timeout: .none, clock: TestClock()))
    await #expect(throws: AIError.self) { try await gw.generate(testRequest) }
    #expect(await transport.requestedKeys.count == 1)
  }
}
