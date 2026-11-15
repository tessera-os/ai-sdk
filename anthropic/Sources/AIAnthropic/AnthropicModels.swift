import AI
import Foundation
import ModelBoard

/// Decodes one page of Anthropic's `/v1/models` response.
///
/// - Parameters:
///   - status: The HTTP status code.
///   - body: The response body.
/// - Returns: Typed entries and the `last_id` cursor when `has_more` is true.
/// - Throws: AIError for service failures or malformed bodies.
func decodeAnthropicModelPage(status: Int, body: Data) throws -> ModelPage {
  let document = try jsonObject(body)
  if document["type"]?.stringValue == "error" || !(200..<300).contains(status) {
    if case .object(let error)? = document["error"], let message = error["message"]?.stringValue {
      throw AIError.service(
        ServiceFailure(status: status, kind: error["type"]?.stringValue, message: message))
    }
    throw AIError.status(status)
  }
  guard case .array(let entries)? = document["data"] else {
    throw AIError.malformed(
      "The Anthropic model list has no data array (status \(status)): \(String(decoding: body.prefix(500), as: UTF8.self))")
  }
  var models: [ModelListing] = []
  for case .object(let entry) in entries {
    guard let id = entry["id"]?.stringValue else { continue }
    let capabilities = entry["capabilities"].flatMap(objectFields) ?? [:]
    var inputs: Set<Modality> = [.text]
    if supported(capabilities["image_input"]) { inputs.insert(.image) }
    if supported(capabilities["pdf_input"]) { inputs.insert(.file) }
    models.append(
      ModelListing(
        service: .anthropic, id: id, displayName: entry["display_name"]?.stringValue,
        created: listedDate(entry["created_at"]), contextWindow: jsonInt(entry, "max_input_tokens"),
        maxOutputTokens: jsonInt(entry, "max_tokens"),
        inputModalities: capabilities.isEmpty ? nil : inputs,
        thinking: thinkingSupport(capabilities)))
  }
  let more = document["has_more"] == .bool(true)
  return ModelPage(models: models, next: more ? document["last_id"]?.stringValue : nil)
}

private func objectFields(_ value: JSONValue) -> [String: JSONValue]? {
  if case .object(let fields) = value { return fields }
  return nil
}

private func supported(_ value: JSONValue?) -> Bool {
  guard let fields = value.flatMap(objectFields) else { return false }
  return fields["supported"] == .bool(true)
}

private func thinkingSupport(_ capabilities: [String: JSONValue]) -> ThinkingSupport? {
  guard let thinking = capabilities["thinking"].flatMap(objectFields) else { return nil }
  guard supported(.object(thinking)) else { return ThinkingSupport() }
  let types = thinking["types"].flatMap(objectFields) ?? [:]
  var efforts: [ReasoningEffort] = []
  if let effort = capabilities["effort"].flatMap(objectFields), supported(.object(effort)) {
    let levels: [(String, ReasoningEffort)] = [
      ("low", .low), ("medium", .medium), ("high", .high), ("xhigh", .xhigh), ("max", .max),
    ]
    for (name, level) in levels where supported(effort[name]) { efforts.append(level) }
  }
  return ThinkingSupport(
    adaptive: supported(types["adaptive"]), budget: supported(types["enabled"]), efforts: efforts)
}
