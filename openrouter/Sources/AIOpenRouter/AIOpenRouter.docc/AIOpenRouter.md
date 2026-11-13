# ``AIOpenRouter``

The AIOpenRouter package routes canonical AI requests through OpenRouter.
It reuses the AIOpenAI chat-completions codec and adds OpenRouter's upstream
provider controls.

## Configure provider selection

~~~swift
let backend = OpenRouterBackend(
    apiKey: apiKey,
    options: OpenRouterOptions(
        order: ["Anthropic", "OpenAI"],
        allowFallbacks: true,
        dataCollection: false
    )
)
let gateway = Gateway(backends: [backend])
~~~

Each option is optional. Leaving it nil allows OpenRouter's own default to
apply. Caller-supplied provider options can add fields or override the backend
provider block for one request.

OpenRouter uses the reasoning field when replaying reasoning output, sends
the configured title in the X-Title header, and preserves reported cost in AI Usage.

## Topics

### Backend and routing options

- ``OpenRouterBackend``
- ``OpenRouterOptions``
