# federated-agents

Bring your agent to the data, not the data to the agent.

This repo contains a receiver-side prototype:

- a native SwiftUI macOS app shell
- a Go harness that drives the OpenAI Responses API directly
- a human-readable packaged-agent format
- a strict app-owned question / query / review boundary
- a DuckDB-backed approved-data layer
- a prototype privacy gate with a clean replacement point for Qrlew
- a live debug trace pane that surfaces every API and tool event

## What the prototype does

The receiver app can:

- load a packaged request from a `.fagent` directory
- verify a sender signature and file digests when present
- show sender identity, purpose, and requested capabilities
- let the receiver approve CSV or Parquet files
- map approved files into DuckDB without exposing raw paths or rows to the model
- launch the Go harness locally and stream events over NDJSON
- expose only four app-mediated tools to the model (`send_message`, `ask_user`, `run_safe_query`, `submit_result`)
- let the agent ask the receiver questions
- let the agent request privacy-gated aggregate queries
- stage the final outbound JSON for receiver approval
- save the approved result locally
- show the full API + tool trace in a debug pane at the bottom of the window

## Runtime shape

The Swift app owns the trust boundary. The Go harness owns the model loop. They talk over stdin/stdout NDJSON.

For each session the Swift app:

- builds the package and approved-schema markdown in memory
- spawns the `receiver-bridge` Go binary
- sends it one `start` message with model, reasoning effort, and both markdown strings
- receives `status`, `trace`, `tool_request`, `final`, and `error` events back
- replies with one `tool_response` for each `tool_request`

The model never receives raw rows, filesystem paths, or shell access. It only receives:

- sender instructions
- approved schema metadata
- receiver answers
- privacy-gated analytical results

## Prototype privacy note

The current privacy layer is intentionally strict but not yet differentially private.

Today it:

- rejects non-aggregate SQL
- rejects mutating or direct file-reading SQL
- rejects queries that mention sensitive-looking columns
- wraps approved queries in a bounded result set

The code is structured around a `PrivacyEngine` protocol so the next step is to replace `PrototypePrivacyEngine` with a real Qrlew-backed rewriter.

## Build and run

The macOS app and the Go bridge are built together. The launcher script handles both:

```bash
./scripts/open_receiver_app.sh
```

The script:

1. runs `swift build`
2. builds the Go bridge to `.build/.../receiver-bridge`
3. symlinks both binaries into a minimal `.app` bundle
4. opens the bundle

For manual builds:

```bash
swift build
(cd go/receiverharness && go build -o ../../.build/arm64-apple-macosx/debug/receiver-bridge ./cmd/receiver-bridge)
swift run FederatedAgentsReceiver
```

Set `RECEIVER_HARNESS_BIN` if you want the app to use a bridge binary from somewhere other than the default location. The app needs `OPENAI_API_KEY` in the environment the bridge sees.

## Tests

```bash
swift test
(cd go/receiverharness && go test ./...)
```

## Debug trace pane

The bottom 240pt of the receiver window renders every bridge trace event live:

- `api_request` / `api_response` — full Responses API request and response bodies
- `tool_request` / `tool_response` — each model-initiated tool call and its reply
- `initial_input` / `instructions` — what the session opened with
- `final_text` / `api_error` — terminal events

This is the first place to look when a session behaves unexpectedly.

## Human notes

Longer-form architectural walkthroughs live under `notes_for_human/`:

- [0001 — Receiver prototype architecture](notes_for_human/0001_receiver_architecture.md)
- [0002 — Moving off Codex CLI onto the Responses API harness](notes_for_human/0002_responses_harness.md)
- [0003 — Wiring the Go harness into the Swift app](notes_for_human/0003_harness_integration.md)

## Open questions left for the next pass

- real Qrlew integration instead of the aggregate-only gate
- a stronger sender toolchain for package creation
- a real outbound transport instead of local save-first delivery
- one or more database connector flows beyond CSV / Parquet
- deeper capability-toggle enforcement at runtime
