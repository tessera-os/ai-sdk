import Foundation
import ModelBoard

/// A runtime-added endpoint binding for one canonical model identity.
public struct CatalogEntry: Sendable, Equatable {
  /// The canonical identity that owns the endpoint.
  public var identity: ModelIdentity
  /// The additional service endpoint available for that identity.
  public var remoteID: RemoteModelID

  /// Creates a runtime catalog entry.
  public init(identity: ModelIdentity, remoteID: RemoteModelID) {
    self.identity = identity
    self.remoteID = remoteID
  }
}

/// Additional model endpoints registered by an application at runtime.
///
/// Built-in endpoints remain on Model values. This catalog adds deployment-
/// specific routes without changing a model's identity or capability data.
public struct RemoteCatalog: Sendable, Equatable {
  /// The endpoints registered by this application.
  public private(set) var additions: [CatalogEntry] = []

  /// Creates an empty runtime catalog.
  public init() {}

  /// Registers an endpoint for a canonical model identity.
  ///
  /// - Parameters:
  ///   - identity: The model identity that may use the endpoint.
  ///   - remoteID: The service, protocol, region, and provider model ID to add.
  public mutating func register(identity: ModelIdentity, remoteID: RemoteModelID) {
    additions.append(CatalogEntry(identity: identity, remoteID: remoteID))
  }

  /// Returns the model's built-in endpoints followed by matching additions.
  ///
  /// - Parameter model: The model whose endpoints are requested.
  /// - Returns: All endpoints registered for its canonical identity.
  public func remoteIDs(for model: Model) -> [RemoteModelID] {
    model.remoteIDs + additions.filter { $0.identity == model.identity }.map(\.remoteID)
  }
}

/// A routing decision pairing one backend with one provider model identifier.
public struct Route: Sendable {
  /// The backend selected for this route.
  public let backend: any AIBackend
  /// The model endpoint binding selected on the backend.
  public let remoteID: RemoteModelID

  /// Position of the backend in the router's ordered list; identifies a key/backend slot.
  public let backendIndex: Int

  /// Creates a route result.
  public init(backend: any AIBackend, remoteID: RemoteModelID, backendIndex: Int = 0) {
    self.backend = backend
    self.remoteID = remoteID
    self.backendIndex = backendIndex
  }
}

/// Selects the first configured backend compatible with a model endpoint.
public struct Router: Sendable {
  /// Backends are considered in this order.
  public var backends: [any AIBackend]
  /// Runtime endpoint additions considered alongside model-declared bindings.
  public var catalog: RemoteCatalog

  /// Creates a router with ordered backends and optional endpoint additions.
  ///
  /// - Parameters:
  ///   - backends: Candidate backends, in preference order.
  ///   - catalog: Additional model endpoint bindings.
  public init(backends: [any AIBackend], catalog: RemoteCatalog = RemoteCatalog()) {
    self.backends = backends
    self.catalog = catalog
  }

  /// Resolves a model to the first service, protocol, and region match.
  ///
  /// - Parameter model: The model selected by a generation request.
  /// - Returns: The matching backend and endpoint.
  /// - Throws: AIError.noRoute when none of the configured backends can serve it.
  public func resolve(_ model: Model) throws -> Route {
    guard let first = try candidates(for: model).first else {
      throw AIError.noRoute(model.identity)
    }
    return first
  }

  /// Lists every compatible route for a model, in preference order.
  ///
  /// Several backends for the same service (for example one per API key)
  /// produce several candidates; the gateway fails over across them.
  ///
  /// - Parameter model: The model selected by a generation request.
  /// - Returns: All matching backend and endpoint pairs, never empty.
  /// - Throws: AIError.noRoute when none of the configured backends can serve it.
  public func candidates(for model: Model) throws -> [Route] {
    var routes: [Route] = []
    for remote in catalog.remoteIDs(for: model) {
      for (index, backend) in backends.enumerated()
      where backend.service == remote.service && backend.apiProtocol == remote.protocol {
        if Region.isCompatible(backend: backend.region, remote: remote.region) {
          routes.append(Route(backend: backend, remoteID: remote, backendIndex: index))
        }
      }
    }
    if routes.isEmpty { throw AIError.noRoute(model.identity) }
    return routes
  }
}
