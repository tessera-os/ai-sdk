import AI
import Foundation
import ModelBoard

private func fields(_ value: JSONValue?) -> [String: JSONValue] {
  if case .object(let object)? = value { return object }
  return [:]
}

private func modalities(_ value: JSONValue?) -> Set<Modality>? {
  guard case .array(let names)? = value else { return nil }
  var result = Set<Modality>()
  for name in names.compactMap(\.stringValue) {
    switch name {
    case "text": result.insert(.text)
    case "image": result.insert(.image)
    case "audio": result.insert(.audio)
    case "video": result.insert(.video)
    case "file": result.insert(.file)
    default: break
    }
  }
  return result
}

/// OpenRouter reports prices as decimal strings of dollars per token.
private func price(_ value: JSONValue?) -> Double? {
  switch value {
  case .string(let text)?: Double(text)
  case .integer(let number)?: Double(number)
  case .number(let number)?: number
  default: nil
  }
}

/// Decodes OpenRouter's `/models` response.
///
/// - Parameters:
///   - status: The HTTP status code.
///   - body: The response body.
/// - Returns: A single page; the endpoint returns the whole catalog.
/// - Throws: AIError for service failures or malformed bodies.
func decodeOpenRouterModelPage(status: Int, body: Data) throws -> ModelPage {
  let document = try jsonObject(body)
  if case .object(let error)? = document["error"], let message = error["message"]?.stringValue {
    throw AIError.service(
      ServiceFailure(status: status, kind: error["code"]?.stringValue, message: message))
  }
  guard (200..<300).contains(status) else { throw AIError.status(status) }
  guard case .array(let entries)? = document["data"] else {
    throw AIError.malformed(
      "The OpenRouter model list has no data array (status \(status)): \(String(decoding: body.prefix(500), as: UTF8.self))")
  }
  var models: [ModelListing] = []
  for case .object(let entry) in entries {
    guard let id = entry["id"]?.stringValue else { continue }
    let architecture = fields(entry["architecture"])
    let provider = fields(entry["top_provider"])
    let pricing = fields(entry["pricing"])
    var supportsTools: Bool?
    var supportsStructured: Bool?
    var thinking: ThinkingSupport?
    if case .array(let parameters)? = entry["supported_parameters"] {
      let names = Set(parameters.compactMap(\.stringValue))
      supportsTools = names.contains("tools")
      supportsStructured = names.contains("structured_outputs")
      if names.contains("reasoning") || names.contains("include_reasoning") {
        thinking = ThinkingSupport(adaptive: true, budget: true)
      }
    }
    models.append(
      ModelListing(
        service: .openRouter, id: id, displayName: entry["name"]?.stringValue,
        created: listedDate(entry["created"]),
        contextWindow: jsonInt(entry, "context_length") ?? jsonInt(provider, "context_length"),
        maxOutputTokens: jsonInt(provider, "max_completion_tokens"),
        inputModalities: modalities(architecture["input_modalities"]),
        outputModalities: modalities(architecture["output_modalities"]),
        supportsTools: supportsTools, supportsStructuredOutput: supportsStructured,
        thinking: thinking,
        pricing: pricing.isEmpty
          ? nil : ListedPricing(input: price(pricing["prompt"]), output: price(pricing["completion"]))))
  }
  return ModelPage(models: models)
}
