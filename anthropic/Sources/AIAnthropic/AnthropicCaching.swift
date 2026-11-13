import AI
import Foundation

/// An ephemeral `cache_control` marker that lives for `lifetime`.
func anthropicCacheControl(_ lifetime: CacheLifetime) -> JSONValue {
  let ttl = switch lifetime {
  case .fiveMinutes: "5m"
  case .oneHour: "1h"
  }
  return .object(["type": .string("ephemeral"), "ttl": .string(ttl)])
}

/// Adds an ephemeral `cache_control` marker to a content block.
///
/// Thinking blocks cannot carry a marker, so they come back unchanged.
func anthropicMarkedForCache(_ block: JSONValue, lifetime: CacheLifetime) -> JSONValue {
  guard case .object(var fields) = block else { return block }
  let type = fields["type"]?.stringValue
  if type == "thinking" || type == "redacted_thinking" { return block }
  fields["cache_control"] = anthropicCacheControl(lifetime)
  return .object(fields)
}

/// Marks the last content block of the last message.
func anthropicMarkingLastMessage(_ messages: [JSONValue], lifetime: CacheLifetime) -> [JSONValue] {
  guard let last = messages.last, case .object(var fields) = last,
    case .array(var blocks)? = fields["content"], let tail = blocks.last
  else { return messages }
  blocks[blocks.count - 1] = anthropicMarkedForCache(tail, lifetime: lifetime)
  fields["content"] = .array(blocks)
  var result = messages
  result[result.count - 1] = .object(fields)
  return result
}

/// Builds the `system` field: a string, or a block array when it carries a cache marker.
func anthropicSystem(_ text: String, cachedFor lifetime: CacheLifetime?) -> JSONValue {
  guard let lifetime else { return .string(text) }
  return .array([
    anthropicMarkedForCache(.object(["type": .string("text"), "text": .string(text)]), lifetime: lifetime)
  ])
}
