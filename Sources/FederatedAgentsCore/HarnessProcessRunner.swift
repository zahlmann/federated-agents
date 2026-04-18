import Foundation

public struct HarnessStartPayload: Sendable {
    public let model: String
    public let reasoningEffort: String
    public let packageMarkdown: String
    public let schemaMarkdown: String

    public init(
        model: String,
        reasoningEffort: String,
        packageMarkdown: String,
        schemaMarkdown: String
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.packageMarkdown = packageMarkdown
        self.schemaMarkdown = schemaMarkdown
    }
}

public enum HarnessEvent: Sendable {
    case status(String)
    case agentMessage(String)
    case toolRequest(HarnessToolRequest)
    case finalText(String)
    case error(String)
    case trace(HarnessTrace)
    case finished(Int32)
    case rawLine(String)
}

public struct HarnessToolRequest: @unchecked Sendable {
    public let id: String
    public let name: String
    public let arguments: [String: Any]

    public init(id: String, name: String, arguments: [String: Any]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var asString: String {
        (arguments["message"] as? String) ?? ""
    }

    public var asAskUser: (title: String, prompt: String, placeholder: String?) {
        (
            title: (arguments["title"] as? String) ?? "Question",
            prompt: (arguments["prompt"] as? String) ?? "",
            placeholder: arguments["placeholder"] as? String
        )
    }

    public var asSafeQuery: (sql: String, why: String?) {
        (
            sql: (arguments["sql"] as? String) ?? "",
            why: arguments["why"] as? String
        )
    }

    public var asSubmitResult: (summary: String, payloadJSON: String) {
        let summary = (arguments["summary"] as? String) ?? ""
        let payloadJSON: String

        if let payload = arguments["payload"] {
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )

            if let data, let string = String(data: data, encoding: .utf8) {
                payloadJSON = string
            } else {
                payloadJSON = String(describing: payload)
            }
        } else {
            payloadJSON = "{}"
        }

        return (summary: summary, payloadJSON: payloadJSON)
    }
}

public struct HarnessTrace: Sendable {
    public let channel: String
    public let payloadJSON: String
    public let timestamp: Date?
}

public enum HarnessProcessRunnerError: LocalizedError {
    case binaryNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let url):
            return "Receiver harness binary not found at \(url.path). Build the Go bridge with `scripts/open_receiver_app.sh` or set RECEIVER_HARNESS_BIN."
        }
    }
}

public final class HarnessProcessRunner: @unchecked Sendable {
    public typealias EventHandler = @MainActor (HarnessEvent) -> Void

    private let binaryURL: URL
    private let environment: [String: String]?
    private let eventHandler: EventHandler

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let writeQueue = DispatchQueue(label: "com.federated-agents.harness.stdin")

    public init(
        binaryURL: URL,
        environment: [String: String]? = nil,
        eventHandler: @escaping EventHandler
    ) {
        self.binaryURL = binaryURL
        self.environment = environment
        self.eventHandler = eventHandler
    }

    public var isRunning: Bool {
        process?.isRunning == true
    }

    public func start(with payload: HarnessStartPayload) throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw HarnessProcessRunnerError.binaryNotFound(binaryURL)
        }

        let process = Process()
        process.executableURL = binaryURL

        if let environment {
            process.environment = environment
        } else {
            process.environment = ProcessInfo.processInfo.environment
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            self?.consumeStdout(data)
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            self?.consumeStderr(data)
        }

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.eventHandler(.finished(finished.terminationStatus))
            }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting

        Task { @MainActor in
            eventHandler(.status("Harness process started"))
        }

        try sendStartMessage(payload: payload)
    }

    public func stop() {
        writeQueue.sync {
            try? stdinHandle?.close()
        }

        process?.terminate()
        process = nil
        stdinHandle = nil
    }

    public func sendToolResponse(
        id: String,
        ok: Bool,
        result: Any? = nil,
        error: String? = nil
    ) throws {
        var payload: [String: Any] = [
            "type": "tool_response",
            "id": id,
            "ok": ok,
        ]

        if let result {
            payload["result"] = result
        }

        if let error {
            payload["error"] = error
        }

        try sendJSON(payload)
    }

    private func sendStartMessage(payload: HarnessStartPayload) throws {
        let body: [String: Any] = [
            "type": "start",
            "start": [
                "model": payload.model,
                "reasoningEffort": payload.reasoningEffort,
                "packageMarkdown": payload.packageMarkdown,
                "schemaMarkdown": payload.schemaMarkdown,
            ],
        ]

        try sendJSON(body)
    }

    private func sendJSON(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var line = data
        line.append(0x0A)

        try writeQueue.sync {
            try stdinHandle?.write(contentsOf: line)
        }
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)

        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[..<newlineIndex]
            stdoutBuffer.removeSubrange(...newlineIndex)

            if lineData.isEmpty {
                continue
            }

            handleOutboundLine(Data(lineData))
        }
    }

    private func consumeStderr(_ data: Data) {
        stderrBuffer.append(data)

        while let newlineIndex = stderrBuffer.firstIndex(of: 0x0A) {
            let lineData = stderrBuffer[..<newlineIndex]
            stderrBuffer.removeSubrange(...newlineIndex)

            if lineData.isEmpty {
                continue
            }

            let line = String(decoding: lineData, as: UTF8.self)
            Task { @MainActor in
                eventHandler(.rawLine("[stderr] " + line))
            }
        }
    }

    private func handleOutboundLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                eventHandler(.rawLine(text))
            }
            return
        }

        guard let type = object["type"] as? String else {
            return
        }

        switch type {
        case "status":
            let message = (object["message"] as? String) ?? ""
            Task { @MainActor in
                eventHandler(.status(message))
            }

        case "final":
            let text = (object["text"] as? String) ?? ""
            Task { @MainActor in
                eventHandler(.finalText(text))
            }

        case "error":
            let message = (object["message"] as? String) ?? "unknown error"
            Task { @MainActor in
                eventHandler(.error(message))
            }

        case "tool_request":
            let id = (object["id"] as? String) ?? ""
            let name = (object["name"] as? String) ?? ""
            let arguments = (object["arguments"] as? [String: Any]) ?? [:]
            let request = HarnessToolRequest(id: id, name: name, arguments: arguments)

            if name == "send_message" {
                let message = request.asString
                Task { @MainActor in
                    eventHandler(.agentMessage(message))
                }

                try? sendToolResponse(id: id, ok: true, result: ["ok": true, "status": "sent"])
                return
            }

            Task { @MainActor in
                eventHandler(.toolRequest(request))
            }

        case "trace":
            let channel = (object["channel"] as? String) ?? ""
            let payload = object["payload"] ?? [:]
            let payloadData = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )

            let payloadJSON: String
            if let payloadData, let string = String(data: payloadData, encoding: .utf8) {
                payloadJSON = string
            } else {
                payloadJSON = ""
            }

            let timestamp = parseTimestamp(object["timestamp"] as? String)
            let trace = HarnessTrace(channel: channel, payloadJSON: payloadJSON, timestamp: timestamp)

            Task { @MainActor in
                eventHandler(.trace(trace))
            }

        default:
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                eventHandler(.rawLine(text))
            }
        }
    }

    private func parseTimestamp(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
