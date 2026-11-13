import Foundation

struct ServerSentEventParser {
  private var dataLines: [String] = []
  private var eventName: String?
  private var lastID: String?
  private var hasFields = false

  mutating func consume(_ line: String) -> ServerSentEvent? {
    if line.isEmpty { return takeEvent() }
    if line.hasPrefix(":") { return nil }
    let split = line.firstIndex(of: ":")
    let name = split.map { String(line[..<$0]) } ?? line
    var value = split.map { String(line[line.index(after: $0)...]) } ?? ""
    if value.first == " " { value.removeFirst() }
    hasFields = true
    switch name {
    case "data": dataLines.append(value)
    case "event": eventName = value
    case "id": if !value.contains("\0") { lastID = value }
    default: break
    }
    return nil
  }

  mutating func finish() -> ServerSentEvent? { takeEvent() }

  private mutating func takeEvent() -> ServerSentEvent? {
    guard hasFields else { return nil }
    let event = ServerSentEvent(
      event: eventName, id: lastID, data: dataLines.joined(separator: "\n"))
    dataLines.removeAll(keepingCapacity: true)
    eventName = nil
    hasFields = false
    return event
  }
}
