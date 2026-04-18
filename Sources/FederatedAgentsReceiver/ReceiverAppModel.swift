import AppKit
import FederatedAgentsCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct TraceEntry: Identifiable {
    let id = UUID()
    let channel: String
    let payloadJSON: String
    let timestamp: Date
}

@MainActor
final class ReceiverAppModel: ObservableObject {
    @Published var loadedPackage: AgentPackage?
    @Published var capabilityApprovals: [String: Bool] = [:]
    @Published var approvedSources: [ApprovedDataSource] = []
    @Published var packageSummaryMessage = "Load a packaged request to begin."
    @Published var logs: [String] = []
    @Published var agentMessages: [String] = []
    @Published var pendingQuestions: [PendingQuestion] = []
    @Published var stagedOutbound: OutboundDraft?
    @Published var verificationMessage = "No package loaded."
    @Published var sessionStatus = "Idle"
    @Published var lastDispatchLocation: String?
    @Published var traceEntries: [TraceEntry] = []
    @Published var harnessBinaryStatus: String = "Harness binary: not located"
    @Published var apiKeyStatus: String = "API key: unknown"
    @Published var traceLogPath: String?

    private let packageLoader = AgentPackageLoader()
    private let privacyEngine = PrototypePrivacyEngine()

    private var catalog: ApprovedDataCatalog?
    private var outboundWorkspace: HarnessOutboundWorkspace?
    private var runner: HarnessProcessRunner?
    private var pendingQuestionToolIDs: [String: String] = [:]
    private var stagedOutboundToolID: String?

    init() {
        refreshHarnessBinaryStatus()
        refreshAPIKeyStatus()
    }

    func loadBundledSample() {
        guard let sampleURL = Bundle.module.url(
            forResource: "PeopleOpsCompensationAudit",
            withExtension: "fagent",
            subdirectory: "Resources/Samples"
        ) else {
            packageSummaryMessage = "The bundled sample package could not be found."
            return
        }

        loadPackage(at: sampleURL)
    }

    func importPackage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Package"
        panel.message = "Choose a packaged agent directory."

        if panel.runModal() == .OK, let url = panel.url {
            loadPackage(at: url)
        }
    }

    func loadPackage(at url: URL) {
        do {
            let package = try packageLoader.load(from: url)
            loadedPackage = package
            capabilityApprovals = Dictionary(
                uniqueKeysWithValues: package.requestedCapabilities.map { capability in
                    (capability.id, capability.required)
                }
            )
            approvedSources = []
            catalog = try ApprovedDataCatalog()
            pendingQuestions = []
            stagedOutbound = nil
            logs = []
            agentMessages = []
            traceEntries = []
            sessionStatus = "Package loaded"
            packageSummaryMessage = package.summary
            verificationMessage = package.verification.message
            lastDispatchLocation = nil
        } catch {
            packageSummaryMessage = error.localizedDescription
            sessionStatus = "Failed to load package"
        }
    }

    func addDataSource() {
        guard loadedPackage != nil else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType.commaSeparatedText,
            UTType(filenameExtension: "parquet")!,
        ]

        guard panel.runModal() == .OK else {
            return
        }

        guard let catalog else {
            sessionStatus = "The local data catalog is not ready."
            return
        }

        do {
            for url in panel.urls {
                let source = try catalog.registerFile(at: url)
                approvedSources.append(source)
                logs.append("Approved data source: \(url.lastPathComponent) as \(source.alias)")
            }

            sessionStatus = "Approved \(approvedSources.count) data source(s)"
        } catch {
            sessionStatus = error.localizedDescription
            logs.append("Failed to add data source: \(error.localizedDescription)")
        }
    }

    func startSession() {
        guard let package = loadedPackage else {
            sessionStatus = "Load a package first."
            return
        }

        guard !approvedSources.isEmpty else {
            sessionStatus = "Approve at least one CSV or Parquet source first."
            return
        }

        stopSession()

        guard let binaryURL = HarnessBinaryLocator.locate() else {
            sessionStatus = "Harness binary not found. Build it with `scripts/open_receiver_app.sh` or set RECEIVER_HARNESS_BIN."
            return
        }

        refreshAPIKeyStatus()
        let resolvedEnvironment = HarnessEnvironmentLoader.resolvedEnvironment()

        guard let apiKey = resolvedEnvironment["OPENAI_API_KEY"],
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            sessionStatus = "OPENAI_API_KEY missing. Export it in your shell and relaunch with scripts/open_receiver_app.sh, or write it to ~/.config/federated-agents/env."
            return
        }

        do {
            let outboundWorkspace = try HarnessOutboundWorkspaceFactory.make(packageID: package.id)
            let traceLogURL = HarnessTraceLog.makeSessionLogURL(packageID: package.id)
            HarnessTraceLog.refreshLatestSymlink(pointingAt: traceLogURL)
            self.traceLogPath = traceLogURL.path

            let runner = HarnessProcessRunner(
                binaryURL: binaryURL,
                environment: resolvedEnvironment,
                traceLogURL: traceLogURL
            ) { [weak self] event in
                self?.handle(event: event)
            }

            self.outboundWorkspace = outboundWorkspace
            self.runner = runner
            self.logs = []
            self.agentMessages = []
            self.traceEntries = []
            self.pendingQuestions = []
            self.stagedOutbound = nil
            self.pendingQuestionToolIDs = [:]
            self.stagedOutboundToolID = nil
            self.sessionStatus = "Starting session"

            let packageMarkdown = HarnessPayloadBuilder.buildPackageMarkdown(package)
            let schemaMarkdown = HarnessPayloadBuilder.buildApprovedSchemaMarkdown(from: approvedSources)

            try runner.start(with: HarnessStartPayload(
                model: "gpt-5.4",
                reasoningEffort: "xhigh",
                packageMarkdown: packageMarkdown,
                schemaMarkdown: schemaMarkdown
            ))
        } catch {
            sessionStatus = error.localizedDescription
        }
    }

    func stopSession() {
        runner?.stop()
        runner = nil
    }

    func answer(question: PendingQuestion, answer: String) {
        guard let runner, let toolID = pendingQuestionToolIDs[question.id] else {
            pendingQuestions.removeAll { $0.id == question.id }
            return
        }

        do {
            try runner.sendToolResponse(
                id: toolID,
                ok: true,
                result: ["answer": answer]
            )
        } catch {
            sessionStatus = "Failed to deliver answer: \(error.localizedDescription)"
        }

        pendingQuestionToolIDs.removeValue(forKey: question.id)
        pendingQuestions.removeAll { $0.id == question.id }
    }

    func approveOutboundDraft() {
        guard let stagedOutbound, let toolID = stagedOutboundToolID, let runner else {
            return
        }

        let dispatchLocation = dispatch(payload: stagedOutbound.payload)
        lastDispatchLocation = dispatchLocation

        do {
            try runner.sendToolResponse(
                id: toolID,
                ok: true,
                result: [
                    "status": "approved",
                    "message": "Receiver approved the outbound result. Saved to \(dispatchLocation).",
                ]
            )
        } catch {
            sessionStatus = "Failed to signal approval: \(error.localizedDescription)"
        }

        stagedOutboundToolID = nil
        self.stagedOutbound = nil
    }

    func rejectOutboundDraft() {
        guard let stagedOutbound, let toolID = stagedOutboundToolID, let runner else {
            return
        }

        _ = stagedOutbound

        do {
            try runner.sendToolResponse(
                id: toolID,
                ok: true,
                result: [
                    "status": "rejected",
                    "message": "Receiver rejected the outbound result.",
                ]
            )
        } catch {
            sessionStatus = "Failed to signal rejection: \(error.localizedDescription)"
        }

        stagedOutboundToolID = nil
        self.stagedOutbound = nil
    }

    func isCapabilityApproved(_ capability: CapabilityRequest) -> Bool {
        capabilityApprovals[capability.id] ?? capability.required
    }

    func setCapability(_ capability: CapabilityRequest, approved: Bool) {
        capabilityApprovals[capability.id] = approved
    }

    private func refreshHarnessBinaryStatus() {
        if let binaryURL = HarnessBinaryLocator.locate() {
            harnessBinaryStatus = "Harness binary: \(binaryURL.path)"
        } else {
            harnessBinaryStatus = "Harness binary: not located. Set RECEIVER_HARNESS_BIN or run `scripts/open_receiver_app.sh`."
        }
    }

    private func refreshAPIKeyStatus() {
        if HarnessEnvironmentLoader.hasOpenAIKey() {
            apiKeyStatus = "API key: present"
        } else {
            apiKeyStatus = "API key: missing. Export OPENAI_API_KEY and relaunch, or write KEY=VALUE to ~/.config/federated-agents/env."
        }
    }

    private func handle(event: HarnessEvent) {
        switch event {
        case .status(let message):
            logs.append(message)
            sessionStatus = message

        case .agentMessage(let message):
            agentMessages.append(message)

        case .finalText(let text):
            if !text.isEmpty {
                agentMessages.append(text)
            }

            sessionStatus = "Session finished"

        case .error(let message):
            logs.append("error: \(message)")
            sessionStatus = "Session error"

        case .rawLine(let line):
            logs.append(line)

        case .trace(let trace):
            traceEntries.append(
                TraceEntry(
                    channel: trace.channel,
                    payloadJSON: trace.payloadJSON,
                    timestamp: trace.timestamp ?? Date()
                )
            )

        case .finished(let exitCode):
            logs.append("Harness exited with status \(exitCode)")
            if exitCode != 0 {
                sessionStatus = "Session ended with exit \(exitCode)"
            }

        case .toolRequest(let request):
            handleToolRequest(request)
        }
    }

    private func handleToolRequest(_ request: HarnessToolRequest) {
        switch request.name {
        case "ask_user":
            let decoded = request.asAskUser
            let questionID = UUID().uuidString
            pendingQuestionToolIDs[questionID] = request.id

            pendingQuestions.append(
                PendingQuestion(
                    id: questionID,
                    title: decoded.title,
                    prompt: decoded.prompt,
                    placeholder: decoded.placeholder,
                    requestPath: URL(fileURLWithPath: "/dev/null")
                )
            )

            sessionStatus = "Waiting for receiver answer"

        case "run_safe_query":
            runSafeQuery(
                toolID: request.id,
                sql: request.asSafeQuery.sql,
                rationale: request.asSafeQuery.why
            )

        case "submit_result":
            let decoded = request.asSubmitResult
            stagedOutboundToolID = request.id
            stagedOutbound = OutboundDraft(
                id: request.id,
                summary: decoded.summary,
                payload: decoded.payloadJSON,
                requestPath: URL(fileURLWithPath: "/dev/null")
            )
            sessionStatus = "Waiting for outbound review"

        default:
            logs.append("Unknown tool request: \(request.name)")
            try? runner?.sendToolResponse(
                id: request.id,
                ok: false,
                error: "Unknown tool: \(request.name)"
            )
        }
    }

    private func runSafeQuery(toolID: String, sql: String, rationale: String?) {
        guard let runner, let catalog else {
            try? runner?.sendToolResponse(
                id: toolID,
                ok: false,
                error: "No approved data catalog is ready."
            )
            return
        }

        if sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? runner.sendToolResponse(
                id: toolID,
                ok: true,
                result: [
                    "status": "rejected",
                    "message": "No SQL was provided.",
                ]
            )
            return
        }

        do {
            let (decision, result) = try catalog.executeSafeQuery(sql, using: privacyEngine)

            if let result {
                let payload: [String: Any] = [
                    "status": "approved",
                    "message": decision.message,
                    "columns": result.columns,
                    "rows": result.rows,
                ]

                try runner.sendToolResponse(id: toolID, ok: true, result: payload)
                sessionStatus = "Returned privacy-safe query result"

                if let rationale, !rationale.isEmpty {
                    logs.append("run_safe_query rationale: \(rationale)")
                }
            } else {
                try runner.sendToolResponse(
                    id: toolID,
                    ok: true,
                    result: [
                        "status": "rejected",
                        "message": decision.message,
                    ]
                )
                sessionStatus = "Rejected unsafe query"
            }
        } catch {
            try? runner.sendToolResponse(
                id: toolID,
                ok: false,
                error: error.localizedDescription
            )
            sessionStatus = "Query failed"
        }
    }

    private func dispatch(payload: String) -> String {
        guard let outboundWorkspace else {
            return "No workspace"
        }

        let destination = outboundWorkspace.approvedResultURL

        do {
            try payload.write(to: destination, atomically: true, encoding: .utf8)
            sessionStatus = "Saved approved result to \(destination.path)"
            return destination.path
        } catch {
            sessionStatus = "Failed to save approved result: \(error.localizedDescription)"
            return "Save failed"
        }
    }
}
