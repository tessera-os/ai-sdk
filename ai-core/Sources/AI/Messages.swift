import Foundation
import ModelBoard

/// A text segment sent to or returned by a model.
public struct TextPart: Codable, Sendable, Equatable {
  /// The segment's text.
  public var text: String

  /// Creates a text segment.
  public init(_ text: String) {
    self.text = text
  }
}

/// Image bytes and their media type.
public struct ImagePart: Codable, Sendable, Equatable {
  /// The image media type, such as image/png: the type the bytes show when
  /// they are PNG, JPEG, GIF or WebP, whatever type the part was given.
  /// Providers check the bytes against it and refuse a mismatch, such as a
  /// PNG screenshot saved as `image/jpeg`.
  public var mediaType: String
  /// The encoded image bytes.
  public var data: Data

  /// Creates an image input or output part.
  public init(mediaType: String, data: Data) {
    self.mediaType = Self.mediaType(of: data) ?? mediaType
    self.data = data
  }

  private enum CodingKeys: String, CodingKey { case mediaType, data }

  /// Decodes a part, correcting a stored media type its bytes contradict.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      mediaType: try values.decode(String.self, forKey: .mediaType),
      data: try values.decode(Data.self, forKey: .data))
  }

  /// The media type the image bytes show, or nil when they are none of PNG,
  /// JPEG, GIF or WebP.
  public static func mediaType(of data: Data) -> String? {
    let head = [UInt8](data.prefix(12))
    if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
    if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
    if head.count == 12, head.starts(with: Array("RIFF".utf8)), Array(head[8..<12]) == Array("WEBP".utf8) {
      return "image/webp"
    }
    return nil
  }
}

/// Audio bytes and their media type.
public struct AudioPart: Codable, Sendable, Equatable {
  /// The audio media type, such as audio/wav.
  public var mediaType: String
  /// The encoded audio bytes.
  public var data: Data

  /// Creates an audio input or output part.
  public init(mediaType: String, data: Data) {
    self.mediaType = mediaType
    self.data = data
  }
}

/// Video bytes and their media type.
public struct VideoPart: Codable, Sendable, Equatable {
  /// The video media type, such as video/mp4.
  public var mediaType: String
  /// The encoded video bytes.
  public var data: Data

  /// Creates a video input part.
  public init(mediaType: String, data: Data) {
    self.mediaType = mediaType
    self.data = data
  }
}

/// A named file attached to a user message.
public struct FilePart: Codable, Sendable, Equatable {
  /// The name presented to the model.
  public var name: String
  /// The file media type.
  public var mediaType: String
  /// The file's encoded bytes.
  public var data: Data

  /// Creates a file input part.
  public init(name: String, mediaType: String, data: Data) {
    self.name = name
    self.mediaType = mediaType
    self.data = data
  }
}

/// Reasoning content returned separately from the model's user-facing answer.
public struct Reasoning: Codable, Sendable, Equatable {
  /// The reasoning text.
  public var text: String
  /// Opaque provider data required to replay the block: an Anthropic thinking
  /// signature, or OpenAI's `encrypted_content`.
  public var signature: String?
  /// The service that produced the signature. A backend replays the block
  /// only when the signature came from its own service; nil means unknown.
  public var source: Service?

  /// Creates a reasoning block, optionally preserving its provider signature.
  ///
  /// - Parameters:
  ///   - text: The reasoning text or summary.
  ///   - signature: Opaque replay data from the provider.
  ///   - source: The service that issued the signature.
  public init(text: String, signature: String? = nil, source: Service? = nil) {
    self.text = text
    self.signature = signature
    self.source = source
  }
}

/// A JSON Schema document used for tool inputs or structured model output.
public struct Schema: Codable, Sendable, Equatable {
  /// The schema document.
  public var json: JSONValue
  /// A name for the schema, required by OpenAI's structured output. Backends
  /// that need one use "response" when this is nil.
  public var name: String?
  /// Whether the provider should enforce the schema strictly, where it offers that.
  public var strict: Bool?

  /// Wraps a JSON schema value.
  ///
  /// - Parameters:
  ///   - json: The schema document.
  ///   - name: Optional schema name for structured output.
  ///   - strict: Optional strict-adherence flag for structured output.
  public init(_ json: JSONValue, name: String? = nil, strict: Bool? = nil) {
    self.json = json
    self.name = name
    self.strict = strict
  }
}

/// A function the model may call, described by its input schema.
public struct Tool: Codable, Sendable, Equatable {
  /// The function name sent to the model.
  public var name: String
  /// Guidance describing when the model should call the function.
  public var description: String
  /// The JSON Schema for the function arguments.
  public var inputSchema: Schema

  /// Creates a tool definition.
  public init(name: String, description: String, inputSchema: Schema) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}

/// A complete tool invocation returned by a model.
public struct ToolCall: Codable, Sendable, Equatable {
  /// The identifier used to match this call with its result.
  public var id: String
  /// The function name.
  public var name: String
  /// The parsed JSON arguments selected by the model.
  public var input: JSONValue

  /// Creates a tool call with parsed arguments.
  public init(id: String, name: String, input: JSONValue) {
    self.id = id
    self.name = name
    self.input = input
  }
}

/// The result of executing a tool call, ready to be added to conversation history.
public struct ToolResult: Codable, Sendable, Equatable {
  /// The identifier of the call this result answers.
  public var id: String
  /// The tool's JSON output.
  public var output: JSONValue

  /// Creates a result associated with a previous tool call.
  public init(id: String, output: JSONValue) {
    self.id = id
    self.output = output
  }
}

/// One typed content part supplied in a user message.
public enum Input: Codable, Sendable, Equatable {
  /// Plain text.
  case text(TextPart)
  /// An image.
  case image(ImagePart)
  /// Audio.
  case audio(AudioPart)
  /// Video.
  case video(VideoPart)
  /// A named file.
  case file(FilePart)

  private enum CodingKeys: String, CodingKey { case type, value }
  private enum Kind: String, Codable { case text, image, audio, video, file }

  /// Decodes a tagged input part from its Codable representation.
  ///
  /// - Parameter decoder: The decoder containing the type tag and value.
  /// - Throws: A decoding error for an unknown tag or invalid payload.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .type) {
    case .text: self = .text(try values.decode(TextPart.self, forKey: .value))
    case .image: self = .image(try values.decode(ImagePart.self, forKey: .value))
    case .audio: self = .audio(try values.decode(AudioPart.self, forKey: .value))
    case .video: self = .video(try values.decode(VideoPart.self, forKey: .value))
    case .file: self = .file(try values.decode(FilePart.self, forKey: .value))
    }
  }

  /// Encodes the input with a type tag and its associated payload.
  ///
  /// - Parameter encoder: The encoder receiving the tagged part.
  /// - Throws: An encoding error if the payload cannot be encoded.
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let value):
      try values.encode(Kind.text, forKey: .type)
      try values.encode(value, forKey: .value)
    case .image(let value):
      try values.encode(Kind.image, forKey: .type)
      try values.encode(value, forKey: .value)
    case .audio(let value):
      try values.encode(Kind.audio, forKey: .type)
      try values.encode(value, forKey: .value)
    case .video(let value):
      try values.encode(Kind.video, forKey: .type)
      try values.encode(value, forKey: .value)
    case .file(let value):
      try values.encode(Kind.file, forKey: .type)
      try values.encode(value, forKey: .value)
    }
  }
}

/// One typed content part returned by a model.
public enum Output: Codable, Sendable, Equatable {
  /// Plain text.
  case text(TextPart)
  /// An image.
  case image(ImagePart)
  /// Audio.
  case audio(AudioPart)
  /// Structured JSON output.
  case object(JSONValue)
  /// A request for the caller to invoke a tool.
  case call(ToolCall)
  /// Reasoning returned separately from user-facing text.
  case reasoning(Reasoning)

  private enum CodingKeys: String, CodingKey { case type, value }
  private enum Kind: String, Codable { case text, image, audio, object, call, reasoning }

  /// Decodes a tagged output part from its Codable representation.
  ///
  /// - Parameter decoder: The decoder containing the type tag and value.
  /// - Throws: A decoding error for an unknown tag or invalid payload.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .type) {
    case .text: self = .text(try values.decode(TextPart.self, forKey: .value))
    case .image: self = .image(try values.decode(ImagePart.self, forKey: .value))
    case .audio: self = .audio(try values.decode(AudioPart.self, forKey: .value))
    case .object: self = .object(try values.decode(JSONValue.self, forKey: .value))
    case .call: self = .call(try values.decode(ToolCall.self, forKey: .value))
    case .reasoning: self = .reasoning(try values.decode(Reasoning.self, forKey: .value))
    }
  }

  /// Encodes the output with a type tag and its associated payload.
  ///
  /// - Parameter encoder: The encoder receiving the tagged part.
  /// - Throws: An encoding error if the payload cannot be encoded.
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let value):
      try values.encode(Kind.text, forKey: .type)
      try values.encode(value, forKey: .value)
    case .image(let value):
      try values.encode(Kind.image, forKey: .type)
      try values.encode(value, forKey: .value)
    case .audio(let value):
      try values.encode(Kind.audio, forKey: .type)
      try values.encode(value, forKey: .value)
    case .object(let value):
      try values.encode(Kind.object, forKey: .type)
      try values.encode(value, forKey: .value)
    case .call(let value):
      try values.encode(Kind.call, forKey: .type)
      try values.encode(value, forKey: .value)
    case .reasoning(let value):
      try values.encode(Kind.reasoning, forKey: .type)
      try values.encode(value, forKey: .value)
    }
  }
}

/// A conversation turn, modeled by its role and the content that role may carry.
public enum Message: Codable, Sendable, Equatable {
  /// User-provided input parts.
  case user([Input])
  /// Assistant output from an earlier response.
  case assistant([Output])
  /// Tool outputs paired with earlier tool calls.
  case toolResults([ToolResult])

  /// Creates a user turn containing one text part.
  public static func user(text: String) -> Message {
    .user([.text(TextPart(text))])
  }
}

/// The reason a model stopped generating.
public enum FinishReason: String, Codable, Equatable, Sendable {
  /// The model completed its answer normally.
  case completed
  /// The answer reached the configured output-token limit.
  case length
  /// The model returned one or more tool calls.
  case toolCall
  /// The model refused the request.
  case refusal
  /// The provider reported a generation error.
  case error
  /// Generation was cancelled by the caller.
  case cancelled
}

/// The identifier and name announced when a streamed tool call begins.
public struct ToolCallOpened: Sendable, Equatable {
  /// The provider's call identifier.
  public var id: String
  /// The function name selected by the model.
  public var name: String

  /// Creates a tool-call start value.
  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

/// A fragment of the JSON arguments for a streamed tool call.
public struct ToolInputDelta: Sendable, Equatable {
  /// The identifier of the call receiving this fragment.
  public var id: String
  /// A partial JSON string; it may not parse until the call ends.
  public var json: String

  /// Creates an argument fragment.
  public init(id: String, json: String) {
    self.id = id
    self.json = json
  }
}

/// A typed update emitted while a model response is being streamed.
public enum StreamEvent: Sendable, Equatable {
  /// Begins a run of generated text.
  case textStart
  /// Adds a fragment to the current text run.
  case textDelta(TextPart)
  /// Ends the current text run.
  case textEnd
  /// Begins a reasoning run.
  case reasoningStart
  /// Adds a fragment to the current reasoning run.
  case reasoningDelta(Reasoning)
  /// Ends the current reasoning run.
  case reasoningEnd
  /// Begins a tool call before its arguments are complete.
  case toolCallStart(ToolCallOpened)
  /// Adds a fragment to a tool call's JSON arguments.
  case toolCallDelta(ToolInputDelta)
  /// Completes a tool call with parsed JSON arguments.
  case toolCallEnd(ToolCall)
  /// Reports the usage values received so far.
  case usage(Usage)
  /// Completes the stream with its assembled response.
  case completed(Response)
  /// Terminates the stream with an SDK error.
  case failed(AIError)
}

/// Wraps input parts in the one-turn conversation commonly used for prompts.
///
/// - Parameter input: The parts in the user message.
/// - Returns: A one-element message array containing the user turn.
public func userTurn(_ input: [Input]) -> [Message] {
  [.user(input)]
}

/// Returns the modality represented by an input part.
///
/// - Parameter input: The input value to inspect.
/// - Returns: Its matching modality case.
public func inputModality(_ input: Input) -> Modality {
  switch input {
  case .text: .text
  case .image: .image
  case .audio: .audio
  case .video: .video
  case .file: .file
  }
}
