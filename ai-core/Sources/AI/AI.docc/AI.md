# ``AI``

Use the AI package to build provider-independent generation requests and route
them through a configured backend. The model types come from the `ModelBoard`
package, which this package imports: models carry their identity, capabilities,
and known endpoints as separate values, so a service-specific route does not
change what a model is.

## Build a request

Create a ``Request`` from a model and a chronological conversation. The
`ModelBoard` package defines the model types and provides built-in model definitions.

~~~swift
import AI
import ModelBoard

let model = Providers.OpenAI.GPT.V5_6.sol
let request = Request(
    model: model,
    messages: [.user(text: "Summarize the attached report.")]
)
~~~

Messages preserve their role and content type. User messages contain ``Input``
parts; assistant messages contain ``Output`` parts; tool results refer to the call
identifier that requested them. Image, audio, video, and file content carry
their bytes as Data together with a media type.

## Route and generate

An ``AIBackend`` encodes and decodes one service protocol. A ``Router`` checks
service, protocol, and region compatibility in endpoint declaration order.
The ``Gateway`` validates capabilities before resolving a route or performing
network I/O.

~~~swift
let gateway = Gateway(backends: [
    OpenAIBackend(apiKey: apiKey),
    OpenRouterBackend(apiKey: openRouterKey)
])
let response = try await gateway.generate(request)
~~~

Custom endpoints can be registered through ``RemoteCatalog``. This keeps
application-specific URLs out of the canonical model identity.

## Stream events

Call ``Gateway/stream(_:)`` to consume typed events from a streamed response.
Text, reasoning, and tool calls have start, delta, and end events. The final
``StreamEvent/completed(_:)`` contains the assembled ``Response``.

~~~swift
for try await event in gateway.stream(request) {
    if case .textDelta(let part) = event {
        print(part.text, terminator: "")
    }
}
~~~

If a service returns a complete JSON response after a streaming request, the
gateway expands it into the same event sequence. Cancelling the consuming task
cancels the associated URLSession request.

## Errors and diagnostics

Gateway methods throw ``AIError`` for unsupported capabilities, missing routes,
invalid endpoints, transport failures, provider errors, and malformed response
data. ``Gateway/generateWithExchange(_:)`` also returns an ``Exchange`` with request
and response details. Known credential headers are redacted in that exchange.

## Topics

### Requests and responses

- ``Request``
- ``Message``
- ``Input``
- ``Output``
- ``Response``
- ``Usage``
- ``Tool``
- ``ToolCall``
- ``ToolResult``

### Models and routing

- ``Router``
- ``RemoteCatalog``
- ``ModelListing``
- ``ModelList``

### Providers and streaming

- ``AIBackend``
- ``Gateway``
- ``StreamEvent``
- ``StreamAssembly``
- ``AIError``

The model types (`Model`, `ModelIdentity`, `ModelCapabilities`, `RemoteModelID`, `Service`, `Region`) and the built-in catalog live in the `ModelBoard` package.
