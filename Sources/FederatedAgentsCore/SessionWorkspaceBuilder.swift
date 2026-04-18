import Foundation

public struct SessionWorkspaceBuilder {
    public init() {}

    public func makeWorkspace(
        for package: AgentPackage,
        approvedSources: [ApprovedDataSource]
    ) throws -> LocalSessionWorkspace {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("federated-agents")
            .appendingPathComponent(package.id)
            .appendingPathComponent(UUID().uuidString)

        let workspaceURL = rootURL.appendingPathComponent("workspace")
        let ipcURL = rootURL.appendingPathComponent("ipc")
        let requestDirectoryURL = ipcURL.appendingPathComponent("requests")
        let responseDirectoryURL = ipcURL.appendingPathComponent("responses")
        let outboundDirectoryURL = rootURL.appendingPathComponent("outbound")
        let skillsURL = workspaceURL.appendingPathComponent(".receiver/skills")
        let binURL = workspaceURL.appendingPathComponent("bin")
        let approvedSchemaURL = workspaceURL.appendingPathComponent("APPROVED_SCHEMA.md")

        try createDirectory(rootURL)
        try createDirectory(workspaceURL)
        try createDirectory(requestDirectoryURL)
        try createDirectory(responseDirectoryURL)
        try createDirectory(outboundDirectoryURL)
        try createDirectory(skillsURL)
        try createDirectory(binURL)

        try write(
            buildBaseAgentsMarkdown(),
            to: workspaceURL.appendingPathComponent("AGENTS.md")
        )

        try write(
            buildPackageMarkdown(package: package),
            to: workspaceURL.appendingPathComponent("PACKAGE.md")
        )

        try write(
            buildApprovedSchemaMarkdown(from: approvedSources),
            to: approvedSchemaURL
        )

        try write(
            skillAskUserMarkdown,
            to: skillsURL.appendingPathComponent("ask-user/SKILL.md"),
            createParent: true
        )

        try write(
            skillSafeQueryMarkdown,
            to: skillsURL.appendingPathComponent("run-safe-query/SKILL.md"),
            createParent: true
        )

        try write(
            skillSubmitResultMarkdown,
            to: skillsURL.appendingPathComponent("submit-result/SKILL.md"),
            createParent: true
        )

        let schemaJSON = try JSONEncoder.prettyPrinted.encode(
            approvedSources.map { $0.schema }
        )
        try schemaJSON.write(to: workspaceURL.appendingPathComponent(".receiver/approved-sources.json"))

        let agentctlURL = binURL.appendingPathComponent("agentctl")
        try write(
            buildAgentControlScript(
                requestDirectoryURL: requestDirectoryURL,
                responseDirectoryURL: responseDirectoryURL
            ),
            to: agentctlURL
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: agentctlURL.path
        )

        return LocalSessionWorkspace(
            rootURL: rootURL,
            workspaceURL: workspaceURL,
            requestDirectoryURL: requestDirectoryURL,
            responseDirectoryURL: responseDirectoryURL,
            outboundDirectoryURL: outboundDirectoryURL,
            approvedSchemaURL: approvedSchemaURL
        )
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    private func write(
        _ string: String,
        to url: URL,
        createParent: Bool = false
    ) throws {
        if createParent {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        try string.write(to: url, atomically: true, encoding: .utf8)
    }

    private func buildBaseAgentsMarkdown() -> String {
        """
        # Receiver Agent Rules

        You are running inside a consent-driven local receiver app.

        Your job is to complete the delegated analysis request while respecting these hard boundaries:

        - Never ask for raw rows, samples, identifiers, or unrestricted file contents.
        - Never try to open local files directly.
        - Never try to discover folders or database credentials on your own.
        - Use only the approved schema in `APPROVED_SCHEMA.md`.
        - If you need clarification, use the `ask-user` skill.
        - If you need analysis, use the `run-safe-query` skill.
        - If you are ready to hand back an answer, use the `submit-result` skill.

        Available commands:

        - `./bin/agentctl show-package`
        - `./bin/agentctl list-sources`
        - `./bin/agentctl ask-user --title "..." --prompt "..." [--placeholder "..."]`
        - `./bin/agentctl run-safe-query --sql "SELECT ..."`
        - `./bin/agentctl run-safe-query --sql-file query.sql`
        - `./bin/agentctl submit-result --summary "..." --json-file result.json`
        - `./bin/agentctl log --message "..."`

        Start by reading `PACKAGE.md`, `APPROVED_SCHEMA.md`, and the skill docs in `.receiver/skills/`.
        """
    }

    private func buildPackageMarkdown(package: AgentPackage) -> String {
        let capabilityLines = package.requestedCapabilities.map { capability in
            "- \(capability.kind.title): \(capability.reason)"
        }.joined(separator: "\n")

        return """
        # Packaged Agent Request

        ## Sender

        - Name: \(package.sender.name)
        - Email: \(package.sender.email)
        - Organization: \(package.sender.organization ?? "Not provided")

        ## Request

        - Title: \(package.title)
        - Summary: \(package.summary)
        - Expires at: \(ISO8601DateFormatter().string(from: package.expiresAt))
        - Callback URL: \(package.callbackURL?.absoluteString ?? "No remote callback configured")

        ## Requested capabilities

        \(capabilityLines)

        ## Purpose

        \(package.purposeMarkdown)

        ## Package-specific instructions

        \(package.instructionsMarkdown)

        ## Output contract

        - Description: \(package.outputContract.description)
        - Fields: \(package.outputContract.topLevelFields.joined(separator: ", "))
        """
    }

    private func buildApprovedSchemaMarkdown(from approvedSources: [ApprovedDataSource]) -> String {
        var lines = [
            "# Approved Schema",
            "",
            "This is the only dataset view you may reason over.",
            "Paths, raw rows, sample records, and unrestricted file contents are intentionally hidden from you.",
            "",
        ]

        for source in approvedSources {
            lines.append("## \(source.alias)")
            lines.append("")
            lines.append("- Kind: \(source.kind.title)")
            lines.append("- Display name: \(source.url.lastPathComponent)")
            lines.append("- Raw access: blocked")
            lines.append("")
            lines.append("| Column | Type | Sensitive-looking |")
            lines.append("| --- | --- | --- |")

            for column in source.schema.columns {
                lines.append("| \(column.name) | \(column.type) | \(column.looksSensitive ? "yes" : "no") |")
            }

            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func buildAgentControlScript(
        requestDirectoryURL: URL,
        responseDirectoryURL: URL
    ) -> String {
        """
        #!/bin/zsh
        set -euo pipefail

        REQUEST_DIR="\(requestDirectoryURL.path)"
        RESPONSE_DIR="\(responseDirectoryURL.path)"

        print_help() {
          cat <<'EOF'
        Usage:
          agentctl show-package
          agentctl list-sources
          agentctl ask-user --title "..." --prompt "..." [--placeholder "..."]
          agentctl run-safe-query --sql "SELECT ..."
          agentctl run-safe-query --sql-file path.sql [--why "..."]
          agentctl submit-result --summary "..." --json-file result.json
          agentctl log --message "..."
        EOF
        }

        request_file() {
          local request_id="$1"
          echo "$REQUEST_DIR/$request_id.json"
        }

        response_file() {
          local request_id="$1"
          echo "$RESPONSE_DIR/$request_id.json"
        }

        wait_for_response_path() {
          local request_id="$1"
          local response_path
          response_path="$(response_file "$request_id")"

          while [[ ! -f "$response_path" ]]; do
            sleep 0.2
          done

          echo "$response_path"
        }

        read_response_field() {
          local response_path="$1"
          local field_name="$2"
          local expected_status="${3:-}"
          local default_error="$4"

          python3 - "$response_path" "$field_name" "$expected_status" "$default_error" <<'PY'
        import json
        import sys
        from pathlib import Path

        response_path, field_name, expected_status, default_error = sys.argv[1:]
        payload = json.loads(Path(response_path).read_text(encoding="utf-8"))

        if expected_status and payload.get("status") != expected_status:
            print(payload.get("message", default_error), file=sys.stderr)
            sys.exit(1)

        value = payload.get(field_name, "")
        if value is None:
            value = ""

        sys.stdout.write(str(value))
        PY
        }

        read_response_message() {
          local response_path="$1"

          python3 - "$response_path" <<'PY'
        import json
        import sys
        from pathlib import Path

        response_path = sys.argv[1]
        payload = json.loads(Path(response_path).read_text(encoding="utf-8"))
        sys.stdout.write(str(payload.get("message", "")))
        PY
        }

        make_request() {
          local kind="$1"
          local title="${2:-}"
          local prompt="${3:-}"
          local placeholder="${4:-}"
          local sql="${5:-}"
          local rationale="${6:-}"
          local summary="${7:-}"
          local result_json="${8:-}"
          local message="${9:-}"

          local request_id
          request_id="$(python3 - <<'PY'
        import uuid
        print(uuid.uuid4())
        PY
        )"

          python3 - "$kind" "$request_id" "$title" "$prompt" "$placeholder" "$sql" "$rationale" "$summary" "$result_json" "$message" "$(request_file "$request_id")" <<'PY'
        import json
        import sys
        from datetime import datetime, timezone

        kind, request_id, title, prompt, placeholder, sql, rationale, summary, result_json, message, output_path = sys.argv[1:]

        payload = {
            "id": request_id,
            "kind": kind,
            "createdAt": datetime.now(timezone.utc).isoformat(),
        }

        if title:
            payload["title"] = title
        if prompt:
            payload["prompt"] = prompt
        if placeholder:
            payload["placeholder"] = placeholder
        if sql:
            payload["sql"] = sql
        if rationale:
            payload["rationale"] = rationale
        if summary:
            payload["summary"] = summary
        if result_json:
            payload["resultJSON"] = result_json
        if message:
            payload["message"] = message

        with open(output_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=True, indent=2)
        PY

          echo "$request_id"
        }

        if [[ $# -lt 1 ]]; then
          print_help
          exit 1
        fi

        command="$1"
        shift

        case "$command" in
          show-package)
            cat PACKAGE.md
            ;;
          list-sources)
            cat APPROVED_SCHEMA.md
            ;;
          ask-user)
            title=""
            prompt=""
            placeholder=""

            while [[ $# -gt 0 ]]; do
              case "$1" in
                --title)
                  title="$2"
                  shift 2
                  ;;
                --prompt)
                  prompt="$2"
                  shift 2
                  ;;
                --placeholder)
                  placeholder="$2"
                  shift 2
                  ;;
                *)
                  echo "Unknown option: $1" >&2
                  exit 1
                  ;;
              esac
            done

            request_id="$(make_request "ask_user" "$title" "$prompt" "$placeholder")"
            response_path="$(wait_for_response_path "$request_id")"
            read_response_field "$response_path" "answer" "answered" "The question was not answered."
            ;;
          run-safe-query)
            sql=""
            rationale=""
            sql_file=""

            while [[ $# -gt 0 ]]; do
              case "$1" in
                --sql)
                  sql="$2"
                  shift 2
                  ;;
                --sql-file)
                  sql_file="$2"
                  shift 2
                  ;;
                --why)
                  rationale="$2"
                  shift 2
                  ;;
                *)
                  echo "Unknown option: $1" >&2
                  exit 1
                  ;;
              esac
            done

            if [[ -n "$sql_file" ]]; then
              sql="$(cat "$sql_file")"
            fi

            request_id="$(make_request "safe_query" "" "" "" "$sql" "$rationale")"
            response_path="$(wait_for_response_path "$request_id")"
            read_response_field "$response_path" "resultJSON" "approved" "The safe query was rejected."
            ;;
          submit-result)
            summary=""
            json_file=""

            while [[ $# -gt 0 ]]; do
              case "$1" in
                --summary)
                  summary="$2"
                  shift 2
                  ;;
                --json-file)
                  json_file="$2"
                  shift 2
                  ;;
                *)
                  echo "Unknown option: $1" >&2
                  exit 1
                  ;;
              esac
            done

            result_json="$(cat "$json_file")"
            request_id="$(make_request "submit_result" "" "" "" "" "" "$summary" "$result_json")"
            response_path="$(wait_for_response_path "$request_id")"
            read_response_field "$response_path" "message" "approved" "Result sending was not approved."
            ;;
          log)
            message=""

            while [[ $# -gt 0 ]]; do
              case "$1" in
                --message)
                  message="$2"
                  shift 2
                  ;;
                *)
                  echo "Unknown option: $1" >&2
                  exit 1
                  ;;
              esac
            done

            request_id="$(make_request "log" "" "" "" "" "" "" "" "$message")"
            response_path="$(wait_for_response_path "$request_id")"
            read_response_message "$response_path" >/dev/null
            ;;
          *)
            print_help
            exit 1
            ;;
        esac
        """
    }

    private let skillAskUserMarkdown = """
    # ask-user

    Use this when you need clarification from the receiver.

    Rules:

    - Ask only one concrete question at a time.
    - Explain why the answer matters.
    - Do not ask for raw rows or unrestricted files.

    Command:

    `./bin/agentctl ask-user --title "Short title" --prompt "Full question" --placeholder "Optional answer hint"`
    """

    private let skillSafeQueryMarkdown = """
    # run-safe-query

    Use this when you need an analytical result from approved data.

    Rules:

    - Request only aggregate analysis.
    - Expect some queries to be rejected by the privacy gate.
    - If a query is rejected, reformulate it instead of asking for raw data.

    Commands:

    - `./bin/agentctl run-safe-query --sql "SELECT ..."`
    - `./bin/agentctl run-safe-query --sql-file query.sql --why "One-sentence rationale"`
    """

    private let skillSubmitResultMarkdown = """
    # submit-result

    Use this when you are ready for the receiver to review the outbound payload.

    Rules:

    - Produce a compact JSON object that matches the output contract.
    - Keep the payload privacy-safe and decision-ready.
    - Expect the receiver to approve or reject the staged result.

    Command:

    `./bin/agentctl submit-result --summary "What this result contains" --json-file result.json`
    """
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
