import AI
import Foundation
import ModelBoard

/// Shared state for a key pool: which slots are cooling down, and until when.
///
/// A slot is one backend/key position, identified by `Route.keyPoolSlot`.
/// Conform to this protocol to share cooldowns across gateway instances
/// (for example through a database or cache). `InMemoryKeyPoolStore` keeps
/// state in one process.
public protocol KeyPoolStore: Sendable {
  /// Returns when the slot may be used again, or nil if it is healthy.
  func cooldownEnd(for slot: String) async -> Date?
  /// Marks a slot unusable until `date`.
  func setCooldown(for slot: String, until date: Date) async
  /// Marks a slot healthy again.
  func clearCooldown(for slot: String) async
}

/// A process-local `KeyPoolStore`.
public actor InMemoryKeyPoolStore: KeyPoolStore {
  private var cooldowns: [String: Date] = [:]

  /// Creates an empty store.
  public init() {}

  /// Returns when the slot may be used again, or nil if it is healthy.
  public func cooldownEnd(for slot: String) -> Date? { cooldowns[slot] }

  /// Marks a slot unusable until `date`.
  public func setCooldown(for slot: String, until date: Date) { cooldowns[slot] = date }

  /// Marks a slot healthy again.
  public func clearCooldown(for slot: String) { cooldowns[slot] = nil }
}

extension Route {
  /// The route's key slot in a `KeyPoolStore`: backend position, service, and remote model.
  ///
  /// Instances sharing a store must configure backends in the same order.
  public var keyPoolSlot: String {
    "\(backendIndex)|\(remoteID.service.rawValue)|\(remoteID.id)"
  }
}
