import AI
import AIGateway
import Foundation
import Testing

@Suite struct KeyPoolTests {
  @Test func rotatesOn401ThenSkipsCoolingKey() async throws {
    let transport = ScriptedTransport(byKey: [
      "a": [.body(401, [:], "bad key")], "b": [.body(200, [:], "ok")],
    ])
    let clock = TestClock()
    let gw = gateway([TestBackend(key: "a"), TestBackend(key: "b")], transport: transport, clock: clock)
    _ = try await gw.generate(testRequest)
    _ = try await gw.generate(testRequest)
    #expect(await transport.requestedKeys == ["a", "b", "b"])
    #expect(await clock.sleeps.isEmpty)
  }

  @Test func rotatesOn429WithoutBackoff() async throws {
    let transport = ScriptedTransport(byKey: [
      "a": [.body(429, [:], "limited")], "b": [.body(200, [:], "ok")],
    ])
    let clock = TestClock()
    let gw = gateway([TestBackend(key: "a"), TestBackend(key: "b")], transport: transport, clock: clock)
    _ = try await gw.generate(testRequest)
    #expect(await transport.requestedKeys == ["a", "b"])
    #expect(await clock.sleeps.isEmpty)
  }

  @Test func allKeysRejectedFailsWithoutRetryRounds() async {
    let transport = ScriptedTransport([.body(401, [:], "bad key")])
    let clock = TestClock()
    let gw = gateway([TestBackend(key: "a"), TestBackend(key: "b")], transport: transport, clock: clock)
    await #expect(throws: AIError.service(ServiceFailure(status: 401, message: "bad key"))) {
      try await gw.generate(testRequest)
    }
    #expect(await transport.requestedKeys == ["a", "b"])
    #expect(await clock.sleeps.isEmpty)
  }

  @Test func cooledKeyIsRetriedOnceCooldownExpires() async throws {
    let transport = ScriptedTransport(byKey: [
      "a": [.body(401, [:], "bad"), .body(200, [:], "ok-a")], "b": [.body(200, [:], "ok-b")],
    ])
    let clock = TestClock(date: Date(timeIntervalSince1970: 1000))
    let gw = gateway([TestBackend(key: "a"), TestBackend(key: "b")], transport: transport, clock: clock)
    _ = try await gw.generate(testRequest)
    await clock.advance(to: Date(timeIntervalSince1970: 1000 + 301))
    let response = try await gw.generate(testRequest)
    #expect(response.output == [.text(TextPart("ok-a"))])
    #expect(await transport.requestedKeys == ["a", "b", "a"])
  }
}

@Suite struct KeyPoolFailoverTests {
  @Test func firstByteTimeoutFailsOverToNextKey() async throws {
    let clock = TestClock(holding: .seconds(5))
    let transport = ScriptedTransport(byKey: ["a": [.hang], "b": [.body(200, [:], "ok")]])
    let gw = gateway([TestBackend(key: "a"), TestBackend(key: "b")], transport: transport,
      timeout: TimeoutPolicy(firstByte: .seconds(5), total: nil), clock: clock)
    let task = Task { try await gw.generate(testRequest) }
    while await transport.requestedKeys.isEmpty { await Task.yield() }
    await clock.fireTimers()
    _ = try await task.value
    #expect(await transport.requestedKeys == ["a", "b"])
  }

  @Test func serverErrorFailsOverThenRetriesRoundWithBackoff() async throws {
    let clock = TestClock()
    let transport = ScriptedTransport(byKey: [
      "a": [.body(503, [:], "x"), .body(200, [:], "ok-a")], "b": [.body(503, [:], "x")],
    ])
    let gw = gateway([TestBackend(key: "a"), TestBackend(key: "b")], transport: transport, clock: clock)
    let response = try await gw.generate(testRequest)
    #expect(response.output == [.text(TextPart("ok-a"))])
    #expect(await transport.requestedKeys == ["a", "b", "a"])
    #expect(await clock.sleeps == [.milliseconds(500)])
  }

  @Test func cooldownStateLivesInTheInjectedStore() async throws {
    let store = InMemoryKeyPoolStore()
    let transport = ScriptedTransport(byKey: ["a": [.body(401, [:], "bad")], "b": [.body(200, [:], "ok")]])
    let first = gateway([TestBackend(key: "a"), TestBackend(key: "b")], transport: transport,
      clock: TestClock(), store: store)
    _ = try await first.generate(testRequest)
    // A second gateway instance sharing the store skips the bad key at once.
    let second = gateway([TestBackend(key: "a"), TestBackend(key: "b")], transport: transport,
      clock: TestClock(), store: store)
    _ = try await second.generate(testRequest)
    #expect(await transport.requestedKeys == ["a", "b", "b"])
    #expect(await store.cooldownEnd(for: "0|custom|m") != nil)
  }

  @Test func poolInitConvenienceWorks() async throws {
    let transport = ScriptedTransport(byKey: ["a": [.body(429, [:], "x")], "b": [.body(200, [:], "ok")]])
    let gw = Gateway(
      pool: [TestBackend(key: "a"), TestBackend(key: "b")], transport: transport,
      resilience: Resilience(retry: RetryPolicy(), timeout: .none, clock: TestClock()))
    _ = try await gw.generate(testRequest)
    #expect(await transport.requestedKeys == ["a", "b"])
  }

  @Test func streamRotatesKeysOnNon2xx() async throws {
    let transport = ScriptedTransport(byKey: [
      "a": [.body(429, [:], "limited")],
      "b": [.sse(200, ["event: text\ndata: ok\n\n", "event: done\ndata: {}\n\n"])],
    ])
    let gw = gateway([TestBackend(key: "a"), TestBackend(key: "b")], transport: transport, clock: TestClock())
    var events: [StreamEvent] = []
    for try await event in gw.stream(testRequest) { events.append(event) }
    #expect(events.contains(.textDelta(TextPart("ok"))))
    #expect(await transport.requestedKeys == ["a", "b"])
  }
}
