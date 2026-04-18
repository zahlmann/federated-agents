# Wiring The Go Harness Into The Swift App

The previous two notes described where we were going.
This note describes the state after the integration is done.

The macOS receiver no longer launches Codex CLI.
It launches the Go harness directly and talks to it over stdin/stdout.

## The one-sentence update

Codex CLI is gone from the runtime.
The Go harness from [0002_responses_harness.md](/Users/johann/code/federated-agents/notes_for_human/0002_responses_harness.md) is now the live agent loop, and the Swift app owns the four tool callbacks end to end.

## Where the code lives now

- `go/receiverharness/bridge.go`
  New bridge runner that wraps `RunSession` with an NDJSON stdin/stdout protocol.

- `go/receiverharness/bridge_test.go`
  A pipe-backed test that drives the bridge through a full request/response cycle.

- `go/receiverharness/cmd/receiver-bridge/main.go`
  The binary that the Swift app spawns. It is tiny on purpose.

- `Sources/FederatedAgentsCore/HarnessProcessRunner.swift`
  Swift wrapper around the subprocess. Owns the NDJSON framing.

- `Sources/FederatedAgentsCore/HarnessPayloadBuilder.swift`
  Pure helpers that build the `PACKAGE` and `APPROVED_SCHEMA` markdown strings.
  No more files written to disk for the agent to read.

- `Sources/FederatedAgentsReceiver/ReceiverAppModel.swift`
  Now holds the pending tool IDs for `ask_user` and `submit_result` and dispatches
  `run_safe_query` through the existing privacy gate.

- `Sources/FederatedAgentsReceiver/ReceiverRootView.swift`
  Adds the Debug Trace pane at the bottom of the window.

- `scripts/open_receiver_app.sh`
  Builds the Go bridge alongside the Swift binary and symlinks it into the app bundle.

## Why this shape

The win is that there is now exactly one place that decides what the model can do: the Swift app.

The Go bridge owns the model loop, but every tool call reaches back through the bridge into Swift before anything happens. That means:

- `send_message` becomes an entry in the Activity pane.
- `ask_user` becomes a question card; the model waits until the human answers.
- `run_safe_query` runs through the existing `PrototypePrivacyEngine` and `ApprovedDataCatalog`.
- `submit_result` stages an `OutboundDraft`; the model waits for approval or rejection.

There is no shell tool, no file search tool, no filesystem tool. The Go process has no opinion about what any of these tools should return; it only forwards to Swift and waits.

## The NDJSON protocol

The bridge is one process, one stdin, one stdout, one JSON object per line.

Swift writes one `start` message and then only `tool_response` messages.
The bridge writes `status`, `trace`, `tool_request`, `final`, or `error` events.

### Swift → bridge

- `{"type":"start","start":{"model":"...","reasoningEffort":"...","packageMarkdown":"...","schemaMarkdown":"..."}}`
- `{"type":"tool_response","id":"<tool id>","ok":true,"result":{...}}`
- `{"type":"tool_response","id":"<tool id>","ok":false,"error":"..."}`

### Bridge → Swift

- `{"type":"status","message":"..."}` — lifecycle ("session starting").
- `{"type":"tool_request","id":"...","name":"ask_user","arguments":{...}}` — the model called a tool.
- `{"type":"trace","channel":"api_request","payload":{...}}` — full API request body.
- `{"type":"trace","channel":"api_response","payload":{...}}` — full API response body.
- `{"type":"trace","channel":"tool_request" | "tool_response" | "initial_input" | "instructions" | "final_text" | "api_error","payload":{...}}`
- `{"type":"final","text":"..."}` — session finished.
- `{"type":"error","message":"..."}` — fatal error.

Every message carries a `timestamp` in RFC3339 nanoseconds.

This is enough detail to reproduce or replay a session from the trace alone.

## The Debug Trace pane

There is now a fixed 240pt debug pane at the bottom of the receiver window.

It renders every `trace` event the bridge emits with:

- the channel label (`api_request`, `api_response`, `tool_request`, etc.)
- a monospaced pretty-printed JSON payload
- the event timestamp

It auto-scrolls to the newest entry.

This is intentional. When something behaves strangely, you should not have to open Go logs to see why. The app surface already knows everything the bridge knows.

## How tool responses actually close the loop

The subtle part of the integration is that `ask_user` and `submit_result` are not synchronous from the human's perspective.

The Go bridge emits a `tool_request` and blocks a goroutine waiting for the matching `tool_response`. Swift stores the tool ID, shows UI, and only sends the response after the human interacts.

In the Swift app model:

- `pendingQuestionToolIDs[questionID] = request.id`
- `stagedOutboundToolID = request.id`

When `answer(...)`, `approveOutboundDraft()`, or `rejectOutboundDraft()` runs, it looks the tool ID back up and calls `runner.sendToolResponse(...)`.

That is the thin seam between UI events and bridge acknowledgements.

## Locating the harness binary

Swift finds the binary in two ways:

1. `RECEIVER_HARNESS_BIN` env var, if set.
2. `Bundle.main.executableURL.deletingLastPathComponent().appendingPathComponent("receiver-bridge")`, which is what `scripts/open_receiver_app.sh` sets up.

The launcher script now:

1. runs `swift build`
2. runs `go build -o .build/.../receiver-bridge ./cmd/receiver-bridge`
3. symlinks both binaries into the generated `.app` bundle
4. opens the bundle

If the binary is missing, the app shows a clear status message in the Debug Trace header instead of failing silently.

## What we removed from the session workspace

Generating `AGENTS.md`, `PACKAGE.md`, `APPROVED_SCHEMA.md`, the `.receiver/skills/` tree, and `bin/agentctl` is no longer necessary for a live session.

`SessionWorkspaceBuilder` is still in the repo because an existing test exercises the script generation and because the package/schema markdown helpers it held have been extracted to `HarnessPayloadBuilder` — but nothing the runtime does touches those files anymore.

The only filesystem artifact a session still produces is the outbound result file in `temporaryDirectory/federated-agents/<packageID>/<uuid>/outbound/approved-result.json`. That is the receiver's dispatch record, not something the agent can read.

## What to verify in a clean session

1. Load the bundled sample package.
2. Add the sample CSV as an approved data source.
3. Click "Start Agent Session".
4. The Activity pane should show `send_message` updates. The Questions pane should show any clarifications. The Outbound Review pane should show the proposed payload.
5. The Debug Trace pane should show `api_request`, `api_response`, `tool_request`, and `tool_response` events, plus an `initial_input` and `instructions` trace at the very start.

If any of those do not appear, the Debug Trace is the first place to look.

## What still applies from the earlier notes

Everything in [0001_receiver_architecture.md](/Users/johann/code/federated-agents/notes_for_human/0001_receiver_architecture.md) about package loading, signature verification, DuckDB, the privacy gate, the Outbound Review trust boundary, and "the app owns trust" is still correct.

Everything in [0002_responses_harness.md](/Users/johann/code/federated-agents/notes_for_human/0002_responses_harness.md) about *why* we moved off Codex CLI is still correct.

What changed is only that section "What is not wired yet" at the bottom of 0002: it is now wired.
