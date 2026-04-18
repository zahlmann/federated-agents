# Project Overview

One-page explainer for the question "what is this repo and why."

## What it is

A local macOS application that lets a remote party (a sender) request an analysis from a data holder (a receiver) without the underlying data ever leaving the receiver's machine.

The sender prepares a signed request package. The receiver opens it in the local app, approves which data the agent may touch, and reviews the final result before any answer goes back.

## Who the two parties are

```
┌──────────────────────────┐                   ┌──────────────────────────┐
│  Sender                  │                   │  Receiver                │
│  (researcher, analyst,   │                   │  (data holder:           │
│   auditor, vendor)       │                   │   hospital, company,     │
│                          │                   │   institution)           │
│                          │                   │                          │
│  Prepares a signed       │   ── package ──►  │  Runs the app, loads    │
│  request package.        │   .fagent dir     │  the package, approves   │
│                          │                   │  data, reviews output.   │
└──────────────────────────┘                   └──────────────────────────┘
```

The sender never accesses the receiver's environment directly. They submit a well-defined question along with an output contract. The receiver stays in control of what is approved, what is executed, and what is returned.

## End-to-end flow

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ SENDER                                                                        │
│                                                                               │
│  1. Write purpose.md + instructions.md                                        │
│  2. Declare an output contract (JSON fields)                                  │
│  3. Sign the package (ed25519)                                                │
│  4. Deliver the .fagent directory                                             │
│                                                                               │
└───────────────────────────────────────────────────┬───────────────────────────┘
                                                    │
                                                    ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│ RECEIVER                                                                      │
│                                                                               │
│   ┌─────────────────┐                                                         │
│   │ Load package    │  Verify signature + tracked file digests                │
│   └────────┬────────┘                                                         │
│            ▼                                                                  │
│   ┌─────────────────┐                                                         │
│   │ Approve data    │  CSV / Parquet file pickers, or Postgres connection.    │
│   │                 │  Approved sources are registered in a local             │
│   │                 │  in-memory DuckDB.                                      │
│   └────────┬────────┘                                                         │
│            ▼                                                                  │
│   ┌─────────────────┐                                                         │
│   │ Start session   │  The app spawns a local agent harness. The agent        │
│   │                 │  sees the packaged request, the approved schema,        │
│   │                 │  and exactly four tools.                                │
│   └────────┬────────┘                                                         │
│            ▼                                                                  │
│   ┌────────────────────────────────────────────────────────────────┐          │
│   │                         Agent loop                             │          │
│   │                                                                │          │
│   │  send_message      →  status line shown to the receiver        │          │
│   │  ask_user          →  multiple-choice question card            │          │
│   │  run_safe_query    →  SQL goes through privacy gate before     │          │
│   │                       it runs against DuckDB                   │          │
│   │  submit_result     →  stages JSON for receiver review          │          │
│   │                                                                │          │
│   └────────────┬───────────────────────────────────────────────────┘          │
│                ▼                                                              │
│   ┌─────────────────┐                                                         │
│   │ Outbound review │  Receiver sees the exact JSON the sender would          │
│   │                 │  see. Approve → saved. Reject → discarded.              │
│   └────────┬────────┘                                                         │
│            ▼                                                                  │
│    (approved result is the only thing that leaves the device)                 │
└───────────────────────────────────────────────────────────────────────────────┘
```

## What the agent can and cannot do

```
  Agent has                                   Agent does not have
  ─────────                                   ───────────────────
  send_message                                shell / code execution
  ask_user  (multiple-choice)                 file system read or write
  run_safe_query  (SQL → privacy gate)        network access
  submit_result  (JSON → human review)        direct database access
                                              any tool not on the left
```

The tool surface is fixed by the app. The agent cannot add tools; the sender cannot add tools. Everything the agent wants to do must go through one of the four.

## The privacy layer

Four gates stacked in series. The request must pass all of them before a row of data informs the answer, and the answer must pass the last one before it goes back to the sender.

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │  1. Signed package        (trust the sender at all?)                │
  │     └─ ed25519 over a signing payload that includes file digests    │
  ├─────────────────────────────────────────────────────────────────────┤
  │  2. Approved data catalog (what data is in scope?)                  │
  │     └─ Receiver approves each file or Postgres table explicitly     │
  │       Sensitive-looking columns are flagged in the schema           │
  ├─────────────────────────────────────────────────────────────────────┤
  │  3. Privacy gate          (is this specific query safe?)            │
  │     └─ Aggregate-only, no identifier columns, no file readers,      │
  │       bounded result, executed against DuckDB only if approved      │
  ├─────────────────────────────────────────────────────────────────────┤
  │  4. Outbound review       (is this specific answer safe to send?)   │
  │     └─ Receiver sees final JSON, approves or rejects                │
  └─────────────────────────────────────────────────────────────────────┘
```

The prototype privacy gate is a strict aggregate-only rule engine. It is intentionally a drop-in replacement point — swap it for a differential-privacy rewriter (e.g. Qrlew) without changing anything else.

## Why it is built this way

Most privacy-preserving-analytics designs come from one of two starting points: strong central governance with weak user control, or strong cryptography with limited practical usefulness. This project starts from a different assumption — that the data holder is a single organisation running software they already trust, and that the missing piece is a narrow, auditable boundary between the remote request and the local data.

The trade-off of that choice is that the system depends on the receiver's app being honest. The gain is that the receiver keeps full control of their data, can inspect exactly what runs, and the sender can ask complex analytical questions without handing over raw data or waiting on a data-sharing agreement.

## Components, briefly

| Layer            | Role                                          | Lives in                                 |
|------------------|-----------------------------------------------|------------------------------------------|
| Receiver app     | UI, consent, orchestration                    | `Sources/FederatedAgentsReceiver/`       |
| Core library     | Package loading, DuckDB, privacy gate         | `Sources/FederatedAgentsCore/`           |
| Agent harness    | OpenAI Responses API loop, tool contract      | `go/receiverharness/`                    |
| Sample package   | Signed `.fagent` used in the demo             | `Sources/FederatedAgentsReceiver/Resources/Samples/` |
| Sender skill     | Codex CLI skill that drops a package in the   | `~/.codex/skills/send-analysis-request/` |
|                  | receiver's inbox                              |                                          |

## When this setup is appropriate

- The receiver is willing to host and run the application.
- The sender's question can be expressed as an aggregate-level result.
- The receiver has a clear policy on what counts as safe output.
- The receiver's trust in the sender is non-zero but limited.

## When it is not

- The sender needs row-level data.
- The analysis cannot be expressed as aggregates or approved analytical queries.
- The receiver has no ability to run software locally.
- Regulatory regimes require formal differential privacy guarantees (this prototype does not yet provide them).

## Current status

This repository is a working prototype. The agent loop, tool contract, privacy gate, signed packaging, and receiver review are all implemented end-to-end. The remaining work — real differential privacy, outbound transport, additional data-source types, deeper capability enforcement — is listed in the individual architecture notes.
