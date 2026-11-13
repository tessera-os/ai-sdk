import Foundation
import Testing

@testable import AI
import ModelBoard

/// A backend that lists a fixed set of models, or fails.
private struct ListingBackend: AIBackend {
  var key: String
  var models: [String]
  var service: Service { .openAI }
  var apiProtocol: AIProtocol { .openAI }
  var region: Region? { .global }

  func encode(modelID: String, request: Request, stream: Bool) throws -> URLRequest {
    URLRequest(url: URL(string: "https://example.test")!)
  }
  func decode(status: Int, body: Data, model: Model) throws -> Response {
    throw AIError.status(status)
  }
  func decodeEvent(_ event: ServerSentEvent, assembly: inout StreamAssembly) throws -> [StreamEvent] { [] }

  func listModelsRequest(after cursor: String?) throws -> URLRequest {
    var wire = URLRequest(url: URL(string: "https://example.test/models")!)
    wire.setValue(key, forHTTPHeaderField: "x-key")
    return wire
  }
  func decodeModelPage(status: Int, body: Data) throws -> ModelPage {
    guard status == 200 else { throw AIError.status(status) }
    return ModelPage(models: models.map { ModelListing(service: .openAI, id: $0) })
  }
}

@Suite struct GatewayListModelsTests {
  @Test func backendsWithoutListingAreSkipped() async {
    let gateway = Gateway(backends: [TestBackend(key: "a")], transport: ScriptedTransport([.body(200, [:], "")]))
    let list = await gateway.listModels()
    #expect(list == ModelList(models: []))
  }

  @Test func nextKeyIsTriedWhenOneIsRevokedAndDuplicatesCollapse() async {
    let transport = ScriptedTransport(byKey: [
      "bad": [.body(401, [:], "no")], "good": [.body(200, [:], "{}")],
    ])
    let gateway = Gateway(backends: [
      ListingBackend(key: "bad", models: []), ListingBackend(key: "good", models: ["m", "m", "n"]),
    ], transport: transport)
    let list = await gateway.listModels()
    #expect(list.failures.isEmpty)
    #expect(list.models.map(\.id) == ["m", "n"])
    #expect(await transport.requestedKeys == ["bad", "good"])
  }

  @Test func failureIsReportedPerServiceAndCatalogFillsKnown() async {
    let transport = ScriptedTransport([.body(500, [:], "x")])
    let failing = await Gateway(backends: [ListingBackend(key: "a", models: [])], transport: transport)
      .listModels()
    #expect(failing.failures == [ModelListFailure(service: .openAI, error: .status(500))])

    let ok = Gateway(
      backends: [ListingBackend(key: "a", models: ["gpt-5.6-sol"])],
      transport: ScriptedTransport([.body(200, [:], "{}")]))
    let list = await ok.listModels()
    #expect(list.models.first?.known == Providers.OpenAI.GPT.V5_6.sol)
  }

  @Test func requestDefaultsLeaveTypedOptionsUnset() {
    #expect(testRequest.toolChoice == nil && testRequest.reasoningEffort == nil && testRequest.caching == .standard)
    #expect(PromptCaching.standard.breakpoints == [.system, .lastMessage])
    #expect(ReasoningEffort.off.disablesReasoning && !ReasoningEffort.budget(1).disablesReasoning)
  }
}
