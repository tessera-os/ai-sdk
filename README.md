# Kira AI SDK for Swift

The AI SDK is published as five independent Swift Package Manager packages,
on top of the separate ModelBoard package, which owns the model types and registry:

| Package directory | Product | Purpose |
| --- | --- | --- |
| core | AI | Typed messages, routing, transport, and streaming |
| openai | AIOpenAI | OpenAI chat-completions and compatible endpoints |
| anthropic | AIAnthropic | Anthropic Messages API |
| openrouter | AIOpenRouter | OpenRouter routing on the shared OpenAI codec |
| ai-gateway | AIGateway | Opinionated layer: key pools, 401/429 key rotation, failover across backends |
| ../model-board | ModelBoard | Model, identity, capability and endpoint types, plus the complete built-in registry (no dependencies) |

Each directory has its own Package.swift (swift-tools-version 6.4, Swift 6 language mode,
with NonisolatedNonsendingByDefault, InferIsolatedConformances, ExistentialAny and
MemberImportVisibility enabled). The
core package depends on ModelBoard, which depends on nothing in the SDK; the
provider packages depend on core and ModelBoard, and OpenRouter also depends on
the OpenAI package. Files that use `Model`, `Service`, `Region` and the other
registry types import ModelBoard explicitly; AI does not re-export it.

## Add a package

Use local package dependencies while working inside this repository. A target
that calls Anthropic can declare:

~~~swift
dependencies: [
    .package(path: "../swift-packages/ai-sdk/ai-core"),
    .package(path: "../swift-packages/ai-sdk/anthropic"),
    .package(path: "../swift-packages/model-board")
]
~~~

Then add the AI, AIAnthropic, and ModelBoard products to the target dependencies.
OpenAI and OpenRouter use products named AIOpenAI and AIOpenRouter.

## Generate a response

~~~swift
import Foundation
import AI
import AIAnthropic
import ModelBoard

let model = Providers.Anthropic.Claude.V5_6.fable
let request = Request(
    model: model,
    messages: [.user(text: "Why is the sky blue?")]
)
let gateway = Gateway(backends: [
    AnthropicBackend(apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
])

let response = try await gateway.generate(request)
for output in response.output {
    if case .text(let part) = output {
        print(part.text)
    }
}
~~~

The gateway validates the model's capabilities before routing or sending the
request. Provider failures, transport problems, malformed responses, and local
validation errors are surfaced as AIError.

## Stream a response

~~~swift
for try await event in gateway.stream(request) {
    switch event {
    case .textDelta(let part):
        print(part.text, terminator: "")
    case .completed(let response):
        print("\nFinished with \(response.finishReason).")
    case .failed(let error):
        print("Generation failed: \(error.localizedDescription)")
    default:
        break
    }
}
~~~

Text, reasoning, and tool calls arrive as typed start, delta, and end events.
The stream also supports usage reports and a final assembled response. Cancelling
the task consuming the stream cancels its URLSession request.

## Route the same model through another service

A model describes what the model is and can do. Its remoteIDs describe where
it can be reached. The router selects a backend by matching service, protocol,
and region; it does not change the model identity.

~~~swift
import Foundation
import AI
import AIOpenAI
import AIOpenRouter
import ModelBoard

let model = Providers.OpenAI.GPT.V5_6.sol
let gateway = Gateway(backends: [
    OpenAIBackend(
        apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    ),
    OpenRouterBackend(
        apiKey: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
    )
])
let request = Request(
    model: model,
    messages: [.user(text: "Summarize the attached report.")]
)

let response = try await gateway.generate(request)
~~~

Applications can add internal endpoints with RemoteCatalog.register without
changing the shipped model definitions.

## Timeouts, retry, and cancellation

`Gateway` takes a `Resilience` value. Timeouts are on by default (60 s to first
byte, 600 s overall); retry is opt-in.

~~~swift
let gateway = Gateway(
    backends: [AnthropicBackend(apiKey: key)],
    resilience: Resilience(
        retry: RetryPolicy(maxAttempts: 4),            // backoff 0.5 s doubling to 30 s, 50% jitter
        timeout: TimeoutPolicy(firstByte: .seconds(30), total: .seconds(300))
    )
)
~~~

Transient failures (429, 408, 5xx, overloaded, network errors, first-byte
timeouts) are retried and `Retry-After` is honored, up to
`RetryPolicy.maxRetryAfter`. A stream is retried only before its first event is
delivered. Cancelling the calling task throws `CancellationError` from
`generate` and stops the request. Inject a `ResilienceClock` (and an
`HTTPTransport`) to test without waiting or touching the network. Errors that
arrive inside a 200 event stream carry a status derived from the provider's error
type (for example Anthropic `overloaded_error` is 529).

Provider options never override core fields: model, messages, token limits,
tools, and streaming flags always win.

## Key pools and failover (AIGateway)

The `ai-gateway` package adds multi-key behaviour on top of the SDK. List one
backend per API key; a 401 or 429 cools that key and moves to the next, and
transient failures fail over before a backoff round starts.

~~~swift
import AIGateway

let gateway = Gateway(
    pool: [AnthropicBackend(apiKey: keyA), AnthropicBackend(apiKey: keyB)],
    store: InMemoryKeyPoolStore(),                      // or your own KeyPoolStore
    policy: KeyPoolPolicy(authCooldown: .seconds(300), rateLimitCooldown: .seconds(30))
)
~~~

Cooldown state lives behind the `KeyPoolStore` protocol so several gateway
instances can share it; instances sharing a store must configure backends in the
same order.

## Model registry

The complete built-in registry lives in the sibling `swift-packages/model-board`
package. `ModelBoard` depends on this SDK and defines models using the shared
`AI.Model`, capability, identity, and endpoint types. Its model files retain the
provider, family, and release organization of the original Kira registry.

Add both packages to a client target and import `AI` and `ModelBoard` to use the
request APIs with built-in model constants.

See the DocC guides in each package's Sources/<Module>/<Module>.docc directory
for API-specific details.

## Reasoning, tools, caching, and model lists

~~~swift
let request = Request(
    model: model,
    messages: [.user(text: "Plan the trip.")],
    tools: [weather],
    outputSchema: Schema(tripSchema, name: "trip", strict: true),
    toolChoice: .required,                    // .auto, .disabled, .required, .tool(named:)
    reasoningEffort: .high,                   // .off ... .max, or .budget(tokens)
    caching: PromptCaching(key: "chat-42")    // Anthropic cache_control + OpenAI prompt_cache_key
)
let models = await gateway.listModels()   // fills ModelListing.known from ModelCatalog
~~~

- OpenAI reasoning models (GPT-5 and later, o-series) use the Responses API
  (`OpenAIEndpoint.automatic`): stateless (`store: false`), reasoning summaries
  stream as reasoning events, and `reasoning.encrypted_content` is stored in
  `Reasoning.signature` (with `source: .openAI`) and replayed on the next turn.
  Chat Completions remains the path for other models, OpenRouter, and compatible servers.
- A reasoning block is replayed only to the service that issued its signature.
- Prompt caching is on by default (`PromptCaching.standard`: Anthropic breakpoints on
  the system block and last message, one-hour `ttl`). Pass `PromptCaching(lifetime: .fiveMinutes)`
  for the short cache, or `caching: nil` to turn it off.
- `listModels` follows pages, tries the next key of a service when one fails, and
  reports per-service failures in `ModelList.failures`.
