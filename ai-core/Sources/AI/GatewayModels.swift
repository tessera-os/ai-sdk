import Foundation
import ModelBoard

extension Gateway {
  /// Lists the models every configured service reports live.
  ///
  /// Each distinct service is asked once: its backends are tried in order
  /// until one answers, so a revoked key in a pool does not hide the list.
  /// Services answer concurrently. Pages are followed to the end. Backends
  /// that cannot list models are skipped; any other failure is reported in
  /// `ModelList.failures` instead of aborting the call.
  ///
  /// Each entry's `known` property holds the matching ``ModelCatalog`` model,
  /// found by service and identifier, or nil when the catalog has none.
  ///
  /// - Returns: Entries deduplicated by service and identifier, in service order.
  public func listModels() async -> ModelList {
    var services: [Service] = []
    for backend in router.backends where !services.contains(backend.service) {
      services.append(backend.service)
    }
    let context = self
    let outcomes = await withTaskGroup(of: (Int, Result<[ModelListing], AIError>?).self) { group in
      for (index, service) in services.enumerated() {
        group.addTask { (index, await context.listModels(of: service)) }
      }
      var collected: [Int: Result<[ModelListing], AIError>?] = [:]
      for await (index, outcome) in group { collected[index] = outcome }
      return collected
    }
    var models: [ModelListing] = []
    var failures: [ModelListFailure] = []
    var seen = Set<String>()
    for (index, service) in services.enumerated() {
      guard let outcome = outcomes[index] ?? nil else { continue }
      switch outcome {
      case .success(let listed):
        for var entry in listed where seen.insert("\(service.rawValue)/\(entry.id)").inserted {
          entry.known = ModelCatalog.model(service: service, id: entry.id)
          models.append(entry)
        }
      case .failure(let error):
        failures.append(ModelListFailure(service: service, error: error))
      }
    }
    return ModelList(models: models, failures: failures)
  }

  /// Lists one service's models with the first backend that answers.
  ///
  /// - Returns: Nil when no backend of the service can list models.
  public func listModels(of service: Service) async -> Result<[ModelListing], AIError>? {
    var last: AIError?
    for backend in router.backends where backend.service == service {
      do {
        return .success(try await listAllPages(of: backend))
      } catch AIError.unsupportedCapability {
        continue
      } catch let error as AIError {
        last = error
      } catch {
        last = .wrapping(error)
      }
    }
    return last.map { .failure($0) }
  }

  private func listAllPages(of backend: any AIBackend) async throws -> [ModelListing] {
    var models: [ModelListing] = []
    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      let wire = try backend.listModelsRequest(after: cursor)
      let response = try await send(wire)
      let body = try await collect(response)
      let page = try backend.decodeModelPage(status: response.head.status, body: body)
      models += page.models
      cursor = page.next
    } while cursor.map({ seenCursors.insert($0).inserted }) ?? false
    return models
  }
}
