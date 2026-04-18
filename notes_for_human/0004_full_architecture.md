# The Receiver, End To End

This is the single note you should read if you want the full picture of what this app does, how the pieces fit together, and — most importantly — how the privacy story actually works.

It is written to be skimmable. Every section has one idea. You can read only the headings and come away with 80% of the understanding.

---

## The one-sentence version

A hospital (or any data holder) loads a signed request from a remote sender, lets a local LLM agent analyse approved data through a narrow app-owned tool surface, and reviews the final answer before it leaves the machine.

---

## The three layers you should keep in your head

There are only three layers. Everything else is detail.

1. **The Swift macOS app** is the control plane. It owns every trust decision. It is the only layer that touches the filesystem, the user, and the outbound transport.
2. **The Go harness** is the model loop. It talks to OpenAI's Responses API, enforces that only four tools exist, and forwards every tool call back to Swift over NDJSON.
3. **The OpenAI Responses API** is the reasoning engine. It produces tool calls; it never touches data.

That is the whole system.

If you are reading code and feel lost, ask yourself: *which of the three am I in right now?* That's usually enough to orient.

---

## The contract the receiver app enforces

The entire point of the system is that the agent only gets four actions:

- `send_message` — append one short status line to the Activity pane.
- `ask_user` — ask the receiver a multiple-choice question and wait for a click.
- `run_safe_query` — submit an SQL query for privacy review. If approved, execute and return sanitised rows. If rejected, return a rejection.
- `submit_result` — stage a JSON payload for receiver approval. The receiver can approve (save locally) or reject.

The agent has no shell, no file system, no network, no arbitrary tool use, no ability to read or list anything. Every capability it needs has to travel through one of those four.

This is the **action surface**. If the action is not in that list, the agent cannot do it.

---

## What is on disk and where

Brief map of the repo so you can navigate without grepping:

- `Sources/FederatedAgentsCore/` — reusable Swift core. Package loading, DuckDB catalog, privacy gate, harness runner.
- `Sources/FederatedAgentsReceiver/` — the SwiftUI macOS app. `ReceiverAppModel` is the session coordinator; `ReceiverRootView` is the UI.
- `go/receiverharness/` — the Go model loop. Client, session loop, bridge runner, CLI entry points.
- `go/receiverharness/cmd/receiver-bridge/` — the binary the Swift app spawns.
- `Sources/FederatedAgentsReceiver/Resources/Samples/*.fagent/` — signed sample packages. Current one is the cardiac readmission study.
- `notes_for_human/` — these notes, for humans.

Every session also creates a trace log at `~/Library/Logs/federated-agents/<timestamp>-<package-id>.ndjson` with a symlink at `latest.ndjson`. That file is bidirectional — it has every API request, every API response, every tool call, every stderr line. If a session behaved oddly, open that file.

---

## The end-to-end session flow

Imagine the hospital loads the cardiac readmission sample and clicks **Start Agent Session**.

```
1. Swift: verify package signature + file digests (ed25519 over a signing payload)
2. Swift: build package markdown + approved schema markdown in memory
3. Swift: spawn the Go bridge as a subprocess
4. Swift → bridge:  start { model, reasoningEffort, packageMarkdown, schemaMarkdown }
5. Bridge → OpenAI: POST /v1/responses (instructions, input, tools)
6. OpenAI → Bridge: response with function_calls (e.g. ask_user)
7. Bridge → Swift:  tool_request { name: "ask_user", arguments: { title, prompt, choices } }
8. Swift: render a question card; user clicks a choice
9. Swift → Bridge:  tool_response { ok: true, result: { answer, contextUpdate? } }
10. Bridge → OpenAI: follow-up with function_call_output
    (repeat 5–9 for run_safe_query and any further ask_user)
11. OpenAI → Bridge: response with submit_result
12. Bridge → Swift: tool_request { name: "submit_result", arguments: { summary, payload } }
13. Swift: render the Outbound Review; user approves or rejects
14. Swift → Bridge: tool_response
15. Bridge: session ends; emits final + trace events
16. Swift: saves approved JSON to the outbound folder; disables restart
```

Every step after 3 is also written to the trace log in both directions.

---

## The bridge protocol (NDJSON, one line one object)

Swift → bridge (stdin):

| type            | fields                               |
|-----------------|--------------------------------------|
| `start`         | `start: { model, reasoningEffort, packageMarkdown, schemaMarkdown }` |
| `tool_response` | `id, ok, result?, error?`            |

Bridge → Swift (stdout):

| type          | fields                                                      |
|---------------|-------------------------------------------------------------|
| `status`      | `message` — one-line lifecycle update                       |
| `tool_request`| `id, name, arguments` — model called a tool                 |
| `trace`       | `channel, payload` — full API bodies, tool events, nudges   |
| `final`       | `text` — session ended with this assistant text             |
| `error`       | `message` — fatal                                           |

The Swift `HarnessProcessRunner` owns the framing and also the per-session trace log. Nothing about this protocol is secret; you can drive the bridge manually with `python3` to reproduce a session.

---

## The privacy layer — read this carefully

This is the part where the architecture earns its keep. It has four independent gates, in series. The agent must pass all four before any data leaves the receiver.

### Gate 1 — The signed package

A `.fagent` package is a directory with a manifest, a purpose, instructions, and an Ed25519 signature over a signing payload. The signing payload contains the sha256 of every tracked file plus the package id and expiry. Swift verifies the signature and the digests on load. If either fails, the package is shown as *invalid* and the user sees a red shield.

This gate does not prevent the model from doing anything — it makes it possible to know *which* sender to trust. The hospital can refuse to even open a package whose signature does not check out.

### Gate 2 — The approved data catalog

The receiver must explicitly approve each CSV or Parquet file through the macOS file picker. Each approval registers a view in an in-memory DuckDB database using a sanitised alias. The agent never sees the filesystem path — only the alias and the column list.

Columns whose names match a sensitive pattern (`id`, `email`, `name`, `phone`, `address`, `ssn`, `dob`, `patient`, `employee`, `customer`, `account`) are flagged as *sensitive-looking* in the schema markdown. The agent sees the flag. The privacy gate uses it.

This gate does not prevent the agent from referring to those columns in SQL; it annotates them so the next gate can reject.

### Gate 3 — The prototype privacy engine

Every `run_safe_query` call goes through `PrototypePrivacyEngine.evaluate` before it executes. The engine is intentionally strict and intentionally not-yet-Qrlew. It rejects:

- any query that is not a `SELECT` or `WITH` prefix
- any query containing `insert`, `update`, `delete`, `drop`, `alter`, `create`, `attach`, `copy`, `pragma`, `install`, `load`, `export`
- any query that uses `read_csv` / `read_parquet` to open a file directly
- any query that does not call an aggregate function (`count(`, `sum(`, `avg(`, `min(`, `max(`)
- any query that references a sensitive-looking column name

If the query passes, the engine wraps it in a bounded outer `SELECT` with `LIMIT 100` and hands the rewrite back. DuckDB then executes only the rewritten SQL. The result is converted to string rows before it reaches the bridge. The bridge never sees live DuckDB objects.

This is the gate the agent will actually crash into in the cardiac sample. Try to group by `patient_id` → rejected. Try to `SELECT patient_id, readmitted_within_30d` → rejected. Try to fetch the top 10 sickest patients → rejected twice, once for raw identifiers and once for missing aggregates. The agent has to reformulate at a coarser granularity.

> This is the layer that a real deployment would replace with Qrlew-style differential privacy rewriting. The abstraction (`PrivacyEngine` protocol) exists specifically so this swap is one file.

### Gate 4 — The outbound review

Even after the agent has called `submit_result`, nothing leaves the device yet. Swift stages the payload in the Outbound Review pane. The receiver sees the exact JSON the sender would see. The receiver can approve (saves to the session's outbound folder) or reject. Only then does the tool response resolve and the session end.

The current build saves locally rather than POSTing to a callback URL — on purpose. You want the review boundary in place before you optimise transport.

### Why four gates in series is the point

Each gate answers a different question:

1. *Do I trust this request at all?* → signature gate
2. *Which data is in scope?* → catalog gate
3. *Is this specific query safe?* → privacy engine
4. *Is this specific answer safe to send?* → outbound review

If any one of them is bypassed, the others still apply. That is the whole design.

---

## The model contract

The Go harness sends strict instructions with every request. The short version:

- Every externally visible output must be a tool call. Plain assistant text is forbidden.
- `send_message` is one per turn, never repeat the same message.
- `ask_user` must have 2 to 5 multiple-choice options — there is no free text on the receiver side.
- `run_safe_query` emits aggregate-only SQL; the receiver's gate is the authority.
- `submit_result` stages the final JSON, which the receiver approves or rejects.
- If the model replies with plain text instead of calling `submit_result`, the bridge nudges up to 2 times with a user message telling it to use tools.

This contract is in `go/receiverharness/receiver_prompt.go` and is the first thing to tune if the model misbehaves.

---

## The Debug Trace pane

The pane at the bottom of the app window renders every trace event in one-line summaries:

```
14:38:27  api_request    → api request tools=[send_message,ask_user,run_safe_query,submit_result] input=1
14:38:29  api_response   ← api response calls=[run_safe_query]
14:38:29  tool_request   → tool run_safe_query(sql="SELECT procedure_category, AVG(readmitted_within_30d)…")
14:38:30  tool_response  ← tool run_safe_query: ok rows=5
…
```

Click any row to expand the full JSON. The same data lives in the trace file on disk (`~/Library/Logs/federated-agents/…`).

If the agent is misbehaving, the debug trace and the log are almost always enough to figure out why. They are a full, symmetric record of the IPC boundary.

---

## What you can change where

Quick map from "I want to change X" to "edit this file":

| Want to change                                            | File                                                     |
|-----------------------------------------------------------|----------------------------------------------------------|
| The rules the agent is given                              | `go/receiverharness/receiver_prompt.go`                  |
| The four tool schemas                                     | `go/receiverharness/session.go`                          |
| The OpenAI transport                                      | `go/receiverharness/client.go`                           |
| What the agent sees about the packaged request            | `Sources/FederatedAgentsCore/HarnessPayloadBuilder.swift`|
| The privacy gate                                          | `Sources/FederatedAgentsCore/PrivacyEngine.swift`        |
| Which columns are flagged sensitive                       | `Sources/FederatedAgentsCore/ApprovedDataCatalog.swift`  |
| The bridge IPC protocol                                   | `Sources/FederatedAgentsCore/HarnessProcessRunner.swift` + `go/receiverharness/bridge.go` |
| The session controls UI                                   | `Sources/FederatedAgentsReceiver/ReceiverRootView.swift` |
| The session state machine                                 | `Sources/FederatedAgentsReceiver/ReceiverAppModel.swift` |

---

## The sample package currently in the repo

**Cardiac 30-day readmission study design.**

- Sender: Vienna Cardiac Research Consortium (Dr. Elena Marchetti).
- Receiver: the hospital.
- Data: an 80-row synthetic cardiac admissions CSV with obvious identifiers (`patient_id`, `mrn`, `full_name`, `date_of_birth`, `postal_code`, dates) and safe aggregate dimensions (`procedure_category`, `age_group`, `gender`, comorbidity flags, `ejection_fraction_band`, `ward`, `readmitted_within_30d`).
- Question design: the agent must ask *which segmentation*, *which minimum cell size*, and *is there more data* — each as multiple choice — before producing any numbers.
- Privacy friction is natural: any query touching identifiers or dates gets rejected; the agent has to land on segment-level aggregates to get anything useful out.

The purpose of the sample is to exercise all four gates on a scenario you would actually recognise from a real hospital.

---

## When the agent misbehaves

Order of operations for debugging:

1. Open the Debug Trace pane.
2. If a tool call went out and came back with an error, read the `error` field in the `tool_response` line.
3. If the privacy gate rejected a query, the rejection message says why. That is the signal to the agent to reformulate.
4. If the session ended with empty final text and no `submit_result`, the nudge retry ran twice and the model still would not comply. Look at the last `final_text` trace to see what it said.
5. If none of the above, open the `.ndjson` trace log and read it end-to-end. It is the ground truth.

---

## Why this repo is arranged this way

One rule: the Swift app is the only place that owns trust, consent, and data. Everything else is a tool that Swift calls and controls. Most refactors worth doing make this rule *more* true, not less.

If you remember that, the rest reads itself.
