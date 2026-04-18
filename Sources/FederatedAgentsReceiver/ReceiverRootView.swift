import AppKit
import FederatedAgentsCore
import SwiftUI

struct ReceiverRootView: View {
    @EnvironmentObject private var model: ReceiverAppModel

    var body: some View {
        NavigationSplitView {
            List {
                Section("Inbox") {
                    Button {
                        model.loadBundledSample()
                    } label: {
                        Label("Load Bundled Sample", systemImage: "tray.and.arrow.down")
                    }

                    Button {
                        model.importPackage()
                    } label: {
                        Label("Import Package", systemImage: "folder")
                    }
                }
            }
            .listStyle(.sidebar)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        packageHeader
                        sessionControlSection
                        capabilitySection
                        dataSection
                        questionSection
                        reviewSection
                        activitySection
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                debugTraceSection
                    .frame(height: 240)
            }
        }
    }

    private var sessionControlSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        model.addDataSource()
                    } label: {
                        Label("Add Data Source", systemImage: "plus.circle")
                            .font(.body.weight(.medium))
                            .padding(.vertical, 4)
                    }
                    .controlSize(.large)
                    .disabled(model.loadedPackage == nil)

                    Button {
                        model.startSession()
                    } label: {
                        Label(model.canStartSession ? "Start Agent Session" : model.sessionButtonLabel,
                              systemImage: model.canStartSession ? "play.fill" : "checkmark.circle")
                            .font(.body.weight(.medium))
                            .padding(.vertical, 4)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartSession)

                    if model.isSessionActive {
                        Button(role: .destructive) {
                            model.stopSession()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.body.weight(.medium))
                                .padding(.vertical, 4)
                        }
                        .controlSize(.large)
                    }

                    Spacer()
                }

                Text(model.sessionStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            Text("Session")
                .font(.headline)
        }
    }

    private var debugTraceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
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

                if let path = model.traceLogPath {
                    Text("Trace log: \(path)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
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
        TraceEntryRow(entry: entry)
    }

    private var packageHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.loadedPackage?.title ?? "No packaged request loaded")
                .font(.largeTitle.weight(.bold))

            Text(model.packageSummaryMessage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let package = model.loadedPackage {
                HStack(spacing: 16) {
                    Label {
                        Text("\(package.sender.name)")
                            .fontWeight(.medium) + Text(" <\(package.sender.email)>").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "person.crop.rectangle")
                    }
                    .font(.callout)

                    Label {
                        Text(model.verificationMessage)
                    } icon: {
                        Image(systemName: "checkmark.shield")
                    }
                    .font(.callout)
                    .foregroundStyle(verificationColor(for: package))

                    Label(package.expiresAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verificationColor(for package: AgentPackage) -> Color {
        switch package.verification.status {
        case .verified: return .green
        case .unsigned: return .orange
        case .invalid: return .red
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
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if let draft = model.stagedOutbound {
                    Text(draft.summary)
                        .font(.title3.weight(.semibold))

                    ScrollView(.horizontal) {
                        Text(draft.payload)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 180)

                    HStack(spacing: 12) {
                        Button {
                            model.approveOutboundDraft()
                        } label: {
                            Label("Approve & Save", systemImage: "checkmark.circle.fill")
                                .font(.body.weight(.medium))
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)

                        Button(role: .destructive) {
                            model.rejectOutboundDraft()
                        } label: {
                            Label("Reject", systemImage: "xmark.circle.fill")
                                .font(.body.weight(.medium))
                        }
                        .controlSize(.large)
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
        } label: {
            Text("Outbound Review")
                .font(.headline)
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

private struct TraceEntryRow: View {
    let entry: TraceEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Text(entry.channel)
                    .font(.caption.monospaced().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(channelColor.opacity(0.22))
                    )
                    .foregroundStyle(channelColor)

                Text(entry.summary)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            }

            if expanded {
                Text(entry.payloadJSON)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }

    private var channelColor: Color {
        switch entry.channel {
        case "api_request": return .blue
        case "api_response": return .teal
        case "api_error", "nudge": return .orange
        case "tool_request": return .purple
        case "tool_response": return .green
        case "final_text": return .accentColor
        default: return .secondary
        }
    }
}

private struct QuestionAnswerCard: View {
    let question: PendingQuestion
    let onSubmit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.title)
                .font(.title3.weight(.semibold))

            Text(question.prompt)
                .font(.body)

            if question.choices.isEmpty {
                Text("The agent did not provide answer choices.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(question.choices.enumerated()), id: \.offset) { _, choice in
                        Button {
                            onSubmit(choice)
                        } label: {
                            HStack {
                                Text(choice)
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.accentColor.opacity(0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
