# ``AIAnthropic``

The AIAnthropic package maps canonical AI requests and responses to the
Anthropic Messages API, including its content blocks and event stream.

## Configure the backend

~~~swift
let backend = AnthropicBackend(apiKey: apiKey)
let gateway = Gateway(backends: [backend])
let response = try await gateway.generate(request)
~~~

``AnthropicOptions`` customizes the API root, default output-token limit, and
version header. The API key is sent in x-api-key; keyed requests require HTTPS.

## Supported content and capabilities

User text, images, and documents are encoded as native Anthropic content blocks.
Audio and video input produce a local unsupported-modality error. Assistant
reasoning is replayed only when its provider signature is present, and tool
results are encoded as user-role tool_result blocks.

The Messages API path implemented here does not expose a structured-output
field. Requests with an output schema fail with an unsupported-capability error
before an HTTP request is sent.

## Topics

### Backend and endpoint settings

- ``AnthropicBackend``
- ``AnthropicOptions``
- ``anthropicDocument(modelID:request:fallbackMaxTokens:stream:)``
