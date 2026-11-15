# AI SDK

Swift 6 packages (`ai-core`, `ai-gateway`, `anthropic`, `openai`, `openrouter`) on top of ModelBoard. See `README.md`.

## Errors

Handle every single error. An error is either thrown on to the caller or caught and turned into something a person or the log sees: the actual error, with what failed. Nothing fails silently.

- No `try?`, ever: use `try` and let it throw, or `do`/`catch` and handle it.
- No empty `catch`: every `catch` does something with the error (throws it on, returns a typed error or value that says what failed).
- This is a library with no logger: make the function `throws` and propagate, or return a typed error, rather than swallowing or logging.
- A message for a failure carries the real error (`"\(error)"` or its `localizedDescription`), never a vague "something went wrong".
- Where nil is the legitimate "not this one" answer of a probe (for example trying one JSON type after another), catch the one specific error by name and answer nil, with a comment saying why it is expected. Anything else still throws.
- Cancellation is an error too: catch `CancellationError` by name where stopping is expected, and say so.
- The `SwallowedErrorCheck` build plugin (`../../swallowed-error-check`) runs on every target of every package here, tests included, and fails the build on `try?` and on an empty `catch`. Never turn it off or route around it.
