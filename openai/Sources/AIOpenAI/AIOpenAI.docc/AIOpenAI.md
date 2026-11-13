# ``AIOpenAI``

The AIOpenAI package implements the chat-completions wire format and maps its
requests, whole responses, and server-sent events to the canonical AI types.

## OpenAI

Create an ``OpenAIBackend`` with an API key and add it to an AI Gateway:

~~~swift
let gateway = Gateway(backends: [
    OpenAIBackend(apiKey: apiKey)
])
let answer = try await gateway.generate(request)
~~~

The backend sends credentials in an Authorization header and requires HTTPS.
The OpenAI dialect uses max_completion_tokens and applies a 4096-token
fallback when the request has no explicit output limit.

## Compatible endpoints

Use ``OpenAICompatibleBackend`` for a self-hosted server or proxy:

~~~swift
let backend = OpenAICompatibleBackend(
    baseURL: "https://models.example.net/v1",
    apiKey: serviceKey,
    service: .custom
)
let gateway = Gateway(backends: [backend], catalog: catalog)
~~~

Set service, apiProtocol, and region to match the endpoint binding used by the
model. ``OpenAIDialect`` can customize the output-token field, reasoning field,
and fallback token count.

The codec supports typed text, image, audio, video, and file inputs; tool
definitions and results; structured output; streamed text and reasoning; and
tool-call argument fragments.

## Topics

### Backends

- ``OpenAIBackend``
- ``OpenAICompatibleBackend``
- ``OpenAIDialect``
