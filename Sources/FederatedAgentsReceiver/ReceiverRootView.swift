import FederatedAgentsCore
import SwiftUI

struct ReceiverRootView: View {
    @EnvironmentObject private var model: ReceiverAppModel

    var body: some View {
        NavigationSplitView {
            List {
                Section("Inbox") {
                    Button("Load Bundled Sample") {
                        model.loadBundledSample()
                    }

                    Button("Import Package") {
                        model.importPackage()
                    }
                }

                Section("Session") {
                    Button("Add Data Source") {
                        model.addDataSource()
                    }
                    .disabled(model.loadedPackage == nil)

                    Button("Start Agent Session") {
                        model.startSession()
                    }
                    .disabled(model.loadedPackage == nil || model.approvedSources.isEmpty)
                }
            }
            .listStyle(.sidebar)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        packageHeader
                        capabilitySection
                        dataSection
                        questionSection
                        reviewSection
                        activitySection
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                debugTraceSection
                    .frame(height: 240)
            }
        }
    }

    private var debugTraceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Debug Trace")
                    .font(.headline)

                Text(model.apiKeyStatus)
                    .font(.caption)
                    .foregroundStyle(model.apiKeyStatus.hasPrefix("API key: present") ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(model.harnessBinaryStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if model.traceEntries.isEmpty {
                            Text("No trace events yet. Start a session to see harness API calls, tool requests, and tool responses.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                        } else {
                            ForEach(model.traceEntries) { entry in
                                traceEntryView(entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: model.traceEntries.count) { _, _ in
                    if let last = model.traceEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
    }

    private func traceEntryView(_ entry: TraceEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.channel)
                    .font(.caption.monospaced().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.18))
                    )

                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text(entry.payloadJSON)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var packageHeader: some View {
        GroupBox("Request") {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.loadedPackage?.title ?? "No packaged request loaded")
                    .font(.title2.weight(.semibold))

                Text(model.packageSummaryMessage)
                    .foregroundStyle(.secondary)

                if let package = model.loadedPackage {
                    Label("Sender: \(package.sender.name) <\(package.sender.email)>", systemImage: "person.crop.rectangle")
                    Label("Verification: \(model.verificationMessage)", systemImage: "checkmark.shield")
                    Label("Expires: \(package.expiresAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                }

                Text("Status: \(model.sessionStatus)")
                    .font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var capabilitySection: some View {
        GroupBox("Capabilities") {
            VStack(alignment: .leading, spacing: 10) {
                if let package = model.loadedPackage {
                    ForEach(package.requestedCapabilities) { capability in
                        Toggle(
                            capability.kind.title,
                            isOn: Binding(
                                get: { model.isCapabilityApproved(capability) },
                                set: { model.setCapability(capability, approved: $0) }
                            )
                        )
                        .toggleStyle(.switch)

                        Text(capability.reason)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    }
                } else {
                    Text("Load a package to review requested capabilities.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dataSection: some View {
        GroupBox("Approved Data") {
            VStack(alignment: .leading, spacing: 12) {
                if model.approvedSources.isEmpty {
                    Text("No files approved yet. Add CSV or Parquet data sources.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.approvedSources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(source.alias) · \(source.kind.title)")
                                .font(.headline)
                            Text(source.url.lastPathComponent)
                                .foregroundStyle(.secondary)
                            Text(source.schema.columns.map(\.name).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var questionSection: some View {
        GroupBox("Questions") {
            VStack(alignment: .leading, spacing: 16) {
                if model.pendingQuestions.isEmpty {
                    Text("The agent has not asked anything yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.pendingQuestions) { question in
                        QuestionAnswerCard(question: question) { answer in
                            model.answer(question: question, answer: answer)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var reviewSection: some View {
        GroupBox("Outbound Review") {
            VStack(alignment: .leading, spacing: 12) {
                if let draft = model.stagedOutbound {
                    Text(draft.summary)
                        .font(.headline)

                    ScrollView(.horizontal) {
                        Text(draft.payload)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 180)

                    HStack {
                        Button("Approve & Save") {
                            model.approveOutboundDraft()
                        }

                        Button("Reject") {
                            model.rejectOutboundDraft()
                        }
                    }

                    if let lastDispatchLocation = model.lastDispatchLocation {
                        Text("Saved to \(lastDispatchLocation)")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Nothing staged for review.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activitySection: some View {
        GroupBox("Activity") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Agent Messages")
                    .font(.headline)

                if model.agentMessages.isEmpty {
                    Text("No agent messages yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.agentMessages.enumerated()), id: \.offset) { _, message in
                        Text(message)
                            .textSelection(.enabled)
                            .padding(.bottom, 6)
                    }
                }

                Divider()

                Text("System Log")
                    .font(.headline)

                if model.logs.isEmpty {
                    Text("No log lines yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct QuestionAnswerCard: View {
    let question: PendingQuestion
    let onSubmit: (String) -> Void

    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.title)
                .font(.headline)

            Text(question.prompt)

            TextField(question.placeholder ?? "Type your answer", text: $answer, axis: .vertical)
                .textFieldStyle(.roundedBorder)

            Button("Send Answer") {
                onSubmit(answer)
                answer = ""
            }
            .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
