# Receiver Harness With The Responses API

This note explains the direction shift away from Codex CLI and toward a small receiver-owned harness built on the OpenAI Responses API.

The short version is:

- Codex CLI is great when you want a local coding agent with shell access.
- Our receiver product wants the opposite.
- We want a model that can think and call only the tools we expose.
- The clean way to get that is to own the tool loop ourselves.

That is what the new Go harness in [go/receiverharness](/Users/johann/code/federated-agents/go/receiverharness) is for.

## The core insight

The real problem was never "how do we make Codex behave better with prompts?"

The real problem was "how do we make the system boundary itself enforce what the model can and cannot do?"

With Codex CLI, the shell is part of the product. We can sandbox it, we can warn it, we can shape the prompt, but we are still starting from a tool surface that includes general command execution.

That is the wrong default for this product.

Our receiver app is not trying to give the agent a workstation.
It is trying to give the agent a very small desk with four buttons:

1. send a short status update
2. ask the receiver a question
3. run a privacy-safe query
4. stage a result for approval

If those are the only things the model should do, then those should literally be the only tools in the API request.

That is what the Responses API gives us.

## Why the Responses API fits

The Responses API is the right primitive because it is an agent loop, not just a text completion endpoint.

That matters because our receiver flow is inherently multi-step:

- the model reads the packaged request,
- maybe asks one clarifying question,
- maybe runs several safe aggregate queries,
- then stages a final result.

That is not one prompt and one answer.
It is a tool-using conversation with state.

The important architectural win is that we control the `tools` array ourselves.

If we define only:

- `send_message`
- `ask_user`
- `run_safe_query`
- `submit_result`

then that is the entire action surface.

No shell tool.
No file search tool.
No arbitrary computer use.
No hidden "well, it can still bash around a little bit."

This is a much cleaner security story than trying to retrofit constraints onto a shell-first agent.

## The prompt layering becomes clean

Earlier we were trying to express three layers of information:

1. the receiver runtime's general rules
2. the packaged request content
3. the approved schema

In the CLI version, those became files:

- `AGENTS.md`
- `PACKAGE.md`
- `APPROVED_SCHEMA.md`

That works, but it leaks too much of the runtime model into local files and encourages a "read files and roam around" style.

With the Responses API harness, the mapping becomes much more natural:

### Layer 1: developer instructions

This is where the harness-owned rules belong.

Examples:

- never ask for raw rows
- never assume shell access
- use progress messages sparingly
- use only the provided tools

In the Go code, this lives in `BuildReceiverInstructions()` in [receiver_prompt.go](/Users/johann/code/federated-agents/go/receiverharness/receiver_prompt.go).

This is the conceptual replacement for the old "general AGENTS.md."

### Layer 2: packaged request plus approved schema

This is the session-specific payload.

It belongs in the initial `input` we send to the model.

In the Go code, this is built by `BuildReceiverInput(packageMarkdown, approvedSchemaMarkdown)`.

This is the conceptual replacement for:

- `PACKAGE.md`
- `APPROVED_SCHEMA.md`

The important shift is that these are now first-class request inputs, not files the model must discover and read.

## The four-tool contract

The harness currently defines four custom functions in [session.go](/Users/johann/code/federated-agents/go/receiverharness/session.go).

### 1. `send_message`

This is for the Activity pane.

We want the user-facing progress messages in the app to be intentional, short, and sparse.
So instead of scraping raw model chatter, we make progress updates an explicit tool call.

The model has to decide to send one.
The app can record exactly when it happened.
The UI can trust that these messages are part of the product contract.

### 2. `ask_user`

This is the guided clarification path.

The model cannot rummage through files to resolve ambiguity.
It must either proceed from the approved schema or ask the human.

That is exactly what we want.

### 3. `run_safe_query`

This is the privacy boundary.

The model never touches raw rows.
It emits an analytical request.
The receiver-owned data layer decides whether that request is safe and executable.

Today our Swift app has a prototype privacy gate around DuckDB.
Tomorrow that could become Qrlew-backed rewriting.

The key point is that the model only sees the sanitized result.

### 4. `submit_result`

This stages the outbound payload for human review.

Again, this is not just a UI nicety.
It is a trust boundary.

The model can propose a result.
The receiver app decides whether that result can actually leave the machine.

## Why structured function arguments are better than shell commands

This is a subtle but important improvement.

In the CLI version, even app-owned actions had to be squeezed through shell syntax.
That created little product distortions:

- JSON had to be written to files or crammed into quoted arguments.
- SQL sometimes had to be moved to `--sql-file` because shell quoting got annoying.
- progress updates were inferred from generic Codex output instead of being explicit product actions.

With the Responses API, the model calls a function with structured JSON arguments.

That means:

- `submit_result` can accept a real JSON `payload` object
- `ask_user` can take `{title, prompt, placeholder}`
- `run_safe_query` can take `{sql, why}`
- `send_message` can take `{message}`

This is simpler for the model, simpler for us, and easier to validate.

## How the loop works

The new harness has three main pieces.

### 1. A tiny raw HTTP client

See [client.go](/Users/johann/code/federated-agents/go/receiverharness/client.go).

This file does one thing:

- POST a JSON body to `/v1/responses`
- decode the response
- surface API errors clearly

I intentionally kept this raw instead of using a big generated SDK surface because the first prototype should be easy to read end to end.

For this repo, simplicity matters more than abstraction density.

### 2. A tool registry

Also in [session.go](/Users/johann/code/federated-agents/go/receiverharness/session.go).

The registry owns:

- the function definitions we send to OpenAI
- the Go callbacks that run when the model calls one of those functions

This is the key control point.

The model can only call tools that are registered here.

If we never register shell, shell does not exist.

That is the important guarantee.

### 3. The session loop

`RunSession(...)` is the heart of the harness.

The loop is:

1. send initial request with:
   - `model`
   - `instructions`
   - initial `input`
   - `tools`
2. inspect the response
3. if there are function calls:
   - execute each one locally
   - append `function_call_output` items
   - call `/v1/responses` again with `previous_response_id`
4. if there are no function calls:
   - return the final text

That is the whole agent runtime in a small amount of code.

## One subtle but very important detail

When you chain requests with `previous_response_id`, you should not assume your instructions magically persist forever in exactly the way you want.

So the harness repeats:

- `instructions`
- `tools`

on every follow-up turn.

That keeps the session contract explicit and local to each request.
It also makes the code easier to reason about: every request is fully described by the request object you are looking at.

## Why Go is a good fit here

You mentioned you are a Python/Go backend and AI person and not a Swift person.
That is exactly why I think this split is healthy.

Swift should own:

- native macOS UI
- file pickers
- local permissions
- receiver experience
- staging and review UI

Go can own:

- the model loop
- the Responses API calls
- the tool registry
- request/response tracing
- eventually retry logic and telemetry

That gives you a small, ordinary backend-shaped core that is easy to inspect and test.

## What is implemented right now

The new Go module contains:

- [client.go](/Users/johann/code/federated-agents/go/receiverharness/client.go)
  A minimal Responses API client and the small JSON structs we need.

- [receiver_prompt.go](/Users/johann/code/federated-agents/go/receiverharness/receiver_prompt.go)
  The mapping from "general runtime rules" plus "package/schema payload" into the API request shape.

- [session.go](/Users/johann/code/federated-agents/go/receiverharness/session.go)
  The tool registry, receiver-specific tool definitions, and the multi-turn agent loop.

- [session_test.go](/Users/johann/code/federated-agents/go/receiverharness/session_test.go)
  Unit tests that prove the loop handles function calls and reissues follow-up requests correctly.

- [cmd/receiver-harness/main.go](/Users/johann/code/federated-agents/go/receiverharness/cmd/receiver-harness/main.go)
  A tiny standalone CLI for manually exercising the harness outside the Swift app.

The CLI is intentionally just a demo driver.
It prints progress messages to stdout, asks questions in the terminal, and can return a canned safe-query response file.

It is not the production app bridge.

## What is not wired yet

Nothing, as of the integration that followed this note.

The Swift receiver app no longer launches Codex CLI. It spawns the Go harness directly and talks to it over NDJSON on stdin/stdout. The file-based `agentctl` bridge is gone from the runtime path.

See [0003_harness_integration.md](/Users/johann/code/federated-agents/notes_for_human/0003_harness_integration.md) for the integrated shape: binary layout, protocol, tool-response plumbing, and the Debug Trace pane.

The architecture is now:

- Swift app owns the receiver experience
- Go harness owns the model loop
- OpenAI Responses API owns the reasoning model
- only receiver-defined functions exist as tools

## The clean integration shape from here

If we keep going in this direction, I would build the next layer like this:

### Step 1: keep the current Swift app UI

Do not throw away the working receiver screens.

They already give us:

- package loading
- data source approval
- question cards
- outbound review
- activity log

That is useful product work we should keep.

### Step 2: replace `CodexProcessRunner`

Instead of spawning `codex exec`, Swift should spawn the Go harness.

The Go harness should receive:

- the base instructions
- the package markdown
- the approved schema markdown
- a session identifier

### Step 3: replace file-polling IPC

Right now the app and agent talk through request/response JSON files.

That was a fine prototype trick, but once we own the harness we can simplify.

Good next options are:

- newline-delimited JSON over stdin/stdout
- a local Unix domain socket
- a tiny localhost HTTP server owned by Swift

For a first clean integration, stdin/stdout JSON is probably the simplest.

### Step 4: keep DuckDB and privacy gating behind Swift

This part of the product idea is still good.

The harness should not know how to open raw data.
It should call `run_safe_query`.
Swift should dispatch that request into the approved data catalog and privacy engine.

That keeps the privacy boundary in the app-owned layer where it belongs.

## My recommendation

I think this is the right architecture direction.

Not because it is theoretically purer, but because it matches the product requirement more honestly.

The receiver app is not a shell harness with extra guardrails.
It is a consent-driven local analysis runner.

Owning the tool loop directly is the simplest way to make the system behave like that product.
