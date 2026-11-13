import AI
import Foundation
import ModelBoard

private func fields(_ value: JSONValue?) -> [String: JSONValue] {
  if case .object(let object)? = value { return object }
  return [:]
}

private func responsesUsage(_ value: JSONValue?) -> Usage {
  let usage = fields(value)
  return Usage(
    inputTokens: jsonInt(usage, "input_tokens"), outputTokens: jsonInt(usage, "output_tokens"),
    cacheReadTokens: jsonInt(fields(usage["input_tokens_details"]), "cached_tokens"),
    reasoningTokens: jsonInt(fields(usage["output_tokens_details"]), "reasoning_tokens"))
}

private func responsesFailure(_ error: [String: JSONValue]) -> AIError {
  let code = error["code"]?.stringValue
  let message = error["message"]?.stringValue ?? ""
  let shaped: JSONValue = .object([
    "message": .string(message.isEmpty ? "OpenAI reported a \(code ?? "response") error." : message),
    "type": code.map(JSONValue.string) ?? .null,
    "code": code.map(JSONValue.string) ?? .null,
  ])
  return openAIServiceError(status: 200, error: shaped)
}

/// How a finished Responses document should be reported.
private func responsesFinish(_ response: [String: JSONValue], hasCalls: Bool) -> FinishReason {
  if response["status"]?.stringValue == "incomplete" {
    switch fields(response["incomplete_details"])["reason"]?.stringValue {
    case "content_filter": return .refusal
    default: return .length
    }
  }
  return hasCalls ? .toolCall : .completed
}

/// Decodes a complete Responses API document.
///
/// - Throws: AIError.service for a failed response, AIError.malformed for a bad item.
func decodeResponsesDocument(_ document: [String: JSONValue], model: Model) throws -> Response {
  if document["status"]?.stringValue == "failed" {
    throw responsesFailure(fields(document["error"]))
  }
  var output: [Output] = []
  var refused = false
  if case .array(let items)? = document["output"] {
    for case .object(let item) in items {
      switch item["type"]?.stringValue {
      case "reasoning":
        var text = ""
        if case .array(let parts)? = item["summary"] {
          text = parts.compactMap { fields($0)["text"]?.stringValue }.joined(separator: "\n\n")
        }
        output.append(
          .reasoning(
            Reasoning(
              text: text, signature: item["encrypted_content"]?.stringValue,
              source: item["encrypted_content"] == nil ? nil : .openAI)))
      case "message":
        guard case .array(let parts)? = item["content"] else { break }
        for case .object(let part) in parts {
          if part["type"]?.stringValue == "refusal" {
            refused = true
            output.append(.text(TextPart(part["refusal"]?.stringValue ?? "")))
          } else if let text = part["text"]?.stringValue {
            output.append(.text(TextPart(text)))
          }
        }
      case "function_call":
        let name = item["name"]?.stringValue ?? ""
        let arguments = item["arguments"]?.stringValue ?? "{}"
        let input: JSONValue
        do { input = try JSONValue.parse(Data((arguments.isEmpty ? "{}" : arguments).utf8)) } catch {
          throw AIError.malformed(
            "Arguments for \(name) are not valid JSON: \(error.localizedDescription)")
        }
        output.append(
          .call(ToolCall(id: item["call_id"]?.stringValue ?? "", name: name, input: input)))
      default: break
      }
    }
  }
  let hasCalls = output.contains { if case .call = $0 { true } else { false } }
  return Response(
    model: model, output: output, usage: responsesUsage(document["usage"]),
    finishReason: refused ? .refusal : responsesFinish(document, hasCalls: hasCalls),
    servedModel: document["model"]?.stringValue)
}

/// Decodes one Responses API stream event.
///
/// Reasoning summaries stream as reasoning events; the encrypted reasoning
/// content arrives with the finished item and is attached as the block's
/// signature. The stream ends at `response.completed` or `response.incomplete`.
func decodeResponsesEvent(
  type: String, chunk: [String: JSONValue], assembly: inout StreamAssembly
) throws -> [StreamEvent] {
  let itemID = chunk["item_id"]?.stringValue ?? "item"
  var events: [StreamEvent] = []
  switch type {
  case "response.created", "response.in_progress":
    if let served = fields(chunk["response"])["model"]?.stringValue { assembly.servedModel = served }
  case "response.output_item.added":
    let item = fields(chunk["item"])
    let key = item["id"]?.stringValue ?? "item-\(jsonInt(chunk, "output_index") ?? 0)"
    switch item["type"]?.stringValue {
    case "reasoning": events += assembly.beginReasoning(key: key)
    case "function_call":
      events += assembly.beginTool(
        key: key, id: item["call_id"]?.stringValue ?? "", name: item["name"]?.stringValue ?? "")
    default: break
    }
  case "response.reasoning_summary_part.added":
    if (jsonInt(chunk, "summary_index") ?? 0) > 0 {
      events += assembly.appendReasoning("\n\n", key: itemID)
    }
  case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
    events += assembly.appendReasoning(chunk["delta"]?.stringValue ?? "", key: itemID)
  case "response.output_text.delta":
    events += assembly.appendText(chunk["delta"]?.stringValue ?? "", key: itemID)
  case "response.refusal.delta":
    assembly.finishReason = .refusal
    events += assembly.appendText(chunk["delta"]?.stringValue ?? "", key: itemID)
  case "response.function_call_arguments.delta":
    events += assembly.appendToolJSON(chunk["delta"]?.stringValue ?? "", key: itemID)
  case "response.output_item.done":
    let item = fields(chunk["item"])
    let key = item["id"]?.stringValue ?? "item-\(jsonInt(chunk, "output_index") ?? 0)"
    switch item["type"]?.stringValue {
    case "reasoning":
      if let secret = item["encrypted_content"]?.stringValue {
        assembly.setReasoningSignature(secret, source: .openAI, key: key)
      }
      events += assembly.endReasoning(key: key)
    case "message": events += assembly.endText(key: key)
    case "function_call":
      if assembly.toolInput(key: key)?.isEmpty == true, let arguments = item["arguments"]?.stringValue {
        events += assembly.appendToolJSON(arguments, key: key)
      }
      events += try assembly.endTool(key: key)
    default: break
    }
  case "response.completed", "response.incomplete":
    let response = fields(chunk["response"])
    if let served = response["model"]?.stringValue { assembly.servedModel = served }
    events += assembly.recordUsage(responsesUsage(response["usage"]))
    let hasCalls = assembly.output.contains { if case .call = $0 { true } else { false } }
    let reason =
      assembly.finishReason == .refusal ? FinishReason.refusal : responsesFinish(response, hasCalls: hasCalls)
    events += try assembly.complete(reason)
  case "response.failed":
    throw responsesFailure(fields(fields(chunk["response"])["error"]))
  case "error":
    throw responsesFailure(chunk)
  default: break
  }
  return events
}
