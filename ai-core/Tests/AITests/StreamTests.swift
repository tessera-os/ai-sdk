import AI
import Foundation
import Testing

@Suite struct StreamTests {
  private func collect(_ gw: Gateway) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in gw.stream(testRequest) { events.append(event) }
    return events
  }

  @Test func parsesEventsSplitAcrossChunksAndKeepsBlankSeparators() async throws {
    let transport = ScriptedTransport([
      .sse(200, ["event: text\nda", "ta: hel", "lo\n\nevent: do", "ne\ndata: {}\n\n"])
    ])
    let gw = gateway([TestBackend(key: "a")], transport: transport, clock: .system)
    let events = try await collect(gw)
    #expect(events.contains(.textDelta(TextPart("hello"))))
    if case .completed? = events.last {} else { Issue.record("no completed event") }
  }

  @Test func retriesWhenErrorEventArrivesBeforeAnyOutput() async throws {
    let transport = ScriptedTransport([
      .sse(200, ["event: error\ndata: busy\n\n"]),
      .sse(200, ["event: text\ndata: ok\n\n", "event: done\ndata: {}\n\n"]),
    ])
    let gw = gateway([TestBackend(key: "a")], transport: transport, clock: TestClock())
    let events = try await collect(gw)
    #expect(events.contains(.textDelta(TextPart("ok"))))
    #expect(await transport.requestedKeys.count == 2)
  }

  @Test func doesNotRetryAfterOutputWasDelivered() async {
    let transport = ScriptedTransport([
      .sse(200, ["event: text\ndata: part\n\n", "event: error\ndata: busy\n\n"]),
      .sse(200, ["event: text\ndata: ok\n\n", "event: done\ndata: {}\n\n"]),
    ])
    let gw = gateway([TestBackend(key: "a")], transport: transport,
      clock: TestClock())
    await #expect(throws: AIError.self) { try await collect(gw) }
    #expect(await transport.requestedKeys.count == 1)
  }
}
