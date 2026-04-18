import AppKit
import FederatedAgentsCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

    private let packageLoader = AgentPackageLoader()
    private let privacyEngine = PrototypePrivacyEngine()
    private let workspaceBuilder = SessionWorkspaceBuilder()

    private var catalog: ApprovedDataCatalog?
    private var workspace: LocalSessionWorkspace?
    private var runner: CodexProcessRunner?
    private var requestPollTask: Task<Void, Never>?
    private var seenRequestIDs: Set<String> = []

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
            }

            sessionStatus = "Approved \(approvedSources.count) data source(s)"
        } catch {
            sessionStatus = error.localizedDescription
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

        do {
            let workspace = try workspaceBuilder.makeWorkspace(
                for: package,
                approvedSources: approvedSources
            )

            let runner = CodexProcessRunner(workspace: workspace) { [weak self] event in
                self?.handle(event: event)
            }

            self.workspace = workspace
            self.runner = runner
            self.seenRequestIDs = []
            self.logs = []
            self.agentMessages = []
            self.pendingQuestions = []
            self.stagedOutbound = nil
            self.sessionStatus = "Starting session"

            try runner.start()
            startPollingRequests()
        } catch {
            sessionStatus = error.localizedDescription
        }
    }

    func stopSession() {
        requestPollTask?.cancel()
        requestPollTask = nil
        runner?.stop()
        runner = nil
    }

    func answer(question: PendingQuestion, answer: String) {
        writeResponse(
            SessionResponseEnvelope(
                id: question.id,
                status: "answered",
                message: "Receiver answered the question.",
                answer: answer,
                resultJSON: nil
            )
        )
        pendingQuestions.removeAll { $0.id == question.id }
    }

    func approveOutboundDraft() {
        guard let stagedOutbound else {
            return
        }

        let dispatchLocation = dispatch(payload: stagedOutbound.payload)
        lastDispatchLocation = dispatchLocation

        writeResponse(
            SessionResponseEnvelope(
                id: stagedOutbound.id,
                status: "approved",
                message: "The receiver approved the outbound result. Saved to \(dispatchLocation).",
                answer: nil,
                resultJSON: nil
            )
        )

        self.stagedOutbound = nil
    }

    func rejectOutboundDraft() {
        guard let stagedOutbound else {
            return
        }

        writeResponse(
            SessionResponseEnvelope(
                id: stagedOutbound.id,
                status: "rejected",
                message: "The receiver rejected the outbound result.",
                answer: nil,
                resultJSON: nil
            )
        )

        self.stagedOutbound = nil
    }

    func isCapabilityApproved(_ capability: CapabilityRequest) -> Bool {
        capabilityApprovals[capability.id] ?? capability.required
    }

    func setCapability(_ capability: CapabilityRequest, approved: Bool) {
        capabilityApprovals[capability.id] = approved
    }

    private func startPollingRequests() {
        requestPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.processPendingRequests()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func processPendingRequests() {
        guard let workspace else {
            return
        }

        let requestURLs = (try? FileManager.default.contentsOfDirectory(
            at: workspace.requestDirectoryURL,
            includingPropertiesForKeys: nil
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for requestURL in requestURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !seenRequestIDs.contains(requestURL.deletingPathExtension().lastPathComponent) else {
                continue
            }

            guard
                let data = try? Data(contentsOf: requestURL),
                let envelope = try? decoder.decode(SessionRequestEnvelope.self, from: data)
            else {
                continue
            }

            seenRequestIDs.insert(envelope.id)
            handle(envelope: envelope, requestURL: requestURL)
        }
    }

    private func handle(event: CodexEvent) {
        switch event {
        case .status(let message):
            logs.append(message)
            sessionStatus = message
        case .agentMessage(let message):
            agentMessages.append(message)
        case .rawLine(let line):
            logs.append(line)
        case .finished(let exitCode):
            logs.append("Codex exited with status \(exitCode)")
            sessionStatus = "Session finished"
            requestPollTask?.cancel()
            requestPollTask = nil
        }
    }

    private func handle(envelope: SessionRequestEnvelope, requestURL: URL) {
        switch envelope.kind {
        case .askUser:
            pendingQuestions.append(
                PendingQuestion(
                    id: envelope.id,
                    title: envelope.title ?? "Question",
                    prompt: envelope.prompt ?? "No prompt provided.",
                    placeholder: envelope.placeholder,
                    requestPath: requestURL
                )
            )
            sessionStatus = "Waiting for receiver answer"

        case .safeQuery:
            runSafeQuery(envelope: envelope)

        case .submitResult:
            stagedOutbound = OutboundDraft(
                id: envelope.id,
                summary: envelope.summary ?? "Pending outbound payload",
                payload: envelope.resultJSON ?? "{}",
                requestPath: requestURL
            )
            sessionStatus = "Waiting for outbound review"

        case .log:
            logs.append(envelope.message ?? "Agent logged an empty message.")
            writeResponse(
                SessionResponseEnvelope(
                    id: envelope.id,
                    status: "logged",
                    message: "Receiver log recorded.",
                    answer: nil,
                    resultJSON: nil
                )
            )
        }
    }

    private func runSafeQuery(envelope: SessionRequestEnvelope) {
        guard let sql = envelope.sql, let catalog else {
            writeResponse(
                SessionResponseEnvelope(
                    id: envelope.id,
                    status: "rejected",
                    message: "No SQL was provided.",
                    answer: nil,
                    resultJSON: nil
                )
            )
            return
        }

        do {
            let (decision, result) = try catalog.executeSafeQuery(sql, using: privacyEngine)

            if let result {
                let payload = SafeQueryPayload(
                    message: decision.message,
                    columns: result.columns,
                    rows: result.rows
                )
                let resultJSONData = try JSONEncoder.prettyPrintedString.encode(payload)
                let resultJSON = String(decoding: resultJSONData, as: UTF8.self)

                writeResponse(
                    SessionResponseEnvelope(
                        id: envelope.id,
                        status: "approved",
                        message: decision.message,
                        answer: nil,
                        resultJSON: resultJSON
                    )
                )
                sessionStatus = "Returned privacy-safe query result"
            } else {
                writeResponse(
                    SessionResponseEnvelope(
                        id: envelope.id,
                        status: "rejected",
                        message: decision.message,
                        answer: nil,
                        resultJSON: nil
                    )
                )
                sessionStatus = "Rejected unsafe query"
            }
        } catch {
            writeResponse(
                SessionResponseEnvelope(
                    id: envelope.id,
                    status: "rejected",
                    message: error.localizedDescription,
                    answer: nil,
                    resultJSON: nil
                )
            )
            sessionStatus = "Query failed"
        }
    }

    private func writeResponse(_ response: SessionResponseEnvelope) {
        guard let workspace else {
            return
        }

        let url = workspace.responseDirectoryURL.appendingPathComponent("\(response.id).json")

        do {
            let data = try JSONEncoder.iso8601.encode(response)
            try data.write(to: url)
        } catch {
            sessionStatus = "Failed to write response: \(error.localizedDescription)"
        }
    }

    private func dispatch(payload: String) -> String {
        guard let workspace else {
            return "No workspace"
        }

        let destination = workspace.outboundDirectoryURL.appendingPathComponent("approved-result.json")

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

private struct SafeQueryPayload: Encodable {
    let message: String
    let columns: [String]
    let rows: [[String]]
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var prettyPrintedString: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
