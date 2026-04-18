# federated-agents

Bring your agent to the data, not the data to the agent.

This repo now contains a first receiver-side prototype:

- a native SwiftUI macOS app shell
- a local Codex headless runner
- a human-readable packaged-agent format
- a strict app-owned question / query / review boundary
- a DuckDB-backed approved-data layer
- a prototype privacy gate with a clean replacement point for Qrlew

## What the prototype does

The receiver app can:

- load a packaged request from a `.fagent` directory
- verify a sender signature and file digests when present
- show sender identity, purpose, and requested capabilities
- let the receiver approve CSV or Parquet files
- map approved files into DuckDB without exposing raw paths or rows to the model
- run `codex exec` locally in a generated workspace
- expose only app-mediated actions through `./bin/agentctl`
- let the agent ask the receiver questions
- let the agent request privacy-gated aggregate queries
- stage the final outbound JSON for receiver approval
- save the approved result locally

## Runtime shape

The session workspace is generated on the fly and contains:

- `AGENTS.md` with receiver rules
- `PACKAGE.md` with the packaged request
- `APPROVED_SCHEMA.md` with schema-only visibility
- `.receiver/skills/*/SKILL.md` docs for app-owned actions
- `bin/agentctl` which bridges Codex to the app through request/response files

The model never receives raw rows through the app boundary. It only receives:

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

## Run

```bash
swift build
swift run FederatedAgentsReceiver
```

For a normal macOS app launch experience, use:

```bash
./scripts/open_receiver_app.sh
```

The raw executable in `.build/.../FederatedAgentsReceiver` is not a full `.app` bundle, so launching it directly from the shell can leave you with a running process and no obvious app window.

## Open questions left for the next pass

- real Qrlew integration instead of the aggregate-only gate
- a stronger sender toolchain for package creation
- a real outbound transport instead of local save-first delivery
- one or more database connector flows beyond CSV / Parquet
