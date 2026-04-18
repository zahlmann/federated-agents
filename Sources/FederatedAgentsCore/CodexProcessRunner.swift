import Foundation

public final class CodexProcessRunner: @unchecked Sendable {
    public typealias EventHandler = @MainActor (CodexEvent) -> Void

    private let workspace: LocalSessionWorkspace
    private let eventHandler: EventHandler

    private var process: Process?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""

    public init(
        workspace: LocalSessionWorkspace,
        eventHandler: @escaping EventHandler
    ) {
        self.workspace = workspace
        self.eventHandler = eventHandler
    }

    public var isRunning: Bool {
        process?.isRunning == true
    }

    public func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        process.currentDirectoryURL = workspace.workspaceURL
        process.arguments = [
            "exec",
            "--json",
            "--sandbox",
            "workspace-write",
            "--skip-git-repo-check",
            "--ephemeral",
            "Carry out the packaged analysis request. Read AGENTS.md, PACKAGE.md, APPROVED_SCHEMA.md, and the skill docs in .receiver/skills before doing anything else.",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(workspace.workspaceURL.appendingPathComponent("bin").path):" + (environment["PATH"] ?? "")
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
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

        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor in
                self?.eventHandler(.finished(finishedProcess.terminationStatus))
            }
        }

        try process.run()
        self.process = process

        Task { @MainActor in
            eventHandler(.status("Codex headless session started."))
        }
    }

    public func stop() {
        process?.terminate()
    }

    private func consumeStdout(_ data: Data) {
        consume(data: data, into: &stdoutBuffer, isErrorStream: false)
    }

    private func consumeStderr(_ data: Data) {
        consume(data: data, into: &stderrBuffer, isErrorStream: true)
    }

    private func consume(
        data: Data,
        into buffer: inout String,
        isErrorStream: Bool
    ) {
        guard let chunk = String(data: data, encoding: .utf8) else {
            return
        }

        buffer += chunk
        let lines = buffer.components(separatedBy: "\n")
        buffer = lines.last ?? ""

        for line in lines.dropLast() where !line.isEmpty {
            handleLine(line, isErrorStream: isErrorStream)
        }
    }

    private func handleLine(_ line: String, isErrorStream: Bool) {
        if isErrorStream {
            Task { @MainActor in
                eventHandler(.rawLine(line))
            }
            return
        }

        guard let data = line.data(using: .utf8) else {
            Task { @MainActor in
                eventHandler(.rawLine(line))
            }
            return
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            Task { @MainActor in
                eventHandler(.rawLine(line))
            }
            return
        }

        if
            type == "item.completed",
            let item = object["item"] as? [String: Any],
            let itemType = item["type"] as? String,
            itemType == "agent_message",
            let text = item["text"] as? String
        {
            Task { @MainActor in
                eventHandler(.agentMessage(text))
            }
            return
        }

        Task { @MainActor in
            eventHandler(.status(type))
        }
    }
}
