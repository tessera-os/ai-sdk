import AI
import Foundation
import ModelBoard

/// Decodes an OpenAI-style `/models` response (`data` array of `id`, `created`, `owned_by`).
///
/// - Parameters:
///   - status: The HTTP status code.
///   - body: The response body.
///   - service: The service to record on each entry.
/// - Returns: A single page; OpenAI does not paginate this endpoint.
/// - Throws: AIError for service failures or malformed bodies.
func decodeOpenAIModelPage(status: Int, body: Data, service: Service) throws -> ModelPage {
  let document = try jsonObject(body)
  if let error = document["error"], error != .null {
    throw openAIServiceError(status: status, error: error)
  }
  guard (200..<300).contains(status) else { throw AIError.status(status) }
  guard case .array(let entries)? = document["data"] else {
    throw AIError.malformed("The model list has no data array.")
  }
  var models: [ModelListing] = []
  for case .object(let entry) in entries {
    guard let id = entry["id"]?.stringValue else { continue }
    models.append(
      ModelListing(
        service: service, id: id, created: listedDate(entry["created"]),
        owner: entry["owned_by"]?.stringValue))
  }
  return ModelPage(models: models)
}
