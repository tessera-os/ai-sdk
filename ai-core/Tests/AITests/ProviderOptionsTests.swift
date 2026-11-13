import AI
import Testing

@Suite struct ProviderOptionsTests {
  @Test func coreFieldsAndReservedKeysWin() {
    var document: [String: JSONValue] = ["model": .string("core")]
    document.merge(
      providerOptions: .object(["model": .string("evil"), "tools": .string("x"), "extra": .integer(1)]),
      reserving: ["tools"])
    #expect(document["model"] == .string("core"))
    #expect(document["tools"] == nil)
    #expect(document["extra"] == .integer(1))
  }
}
