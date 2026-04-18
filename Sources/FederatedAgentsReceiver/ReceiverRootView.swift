import AppKit
import FederatedAgentsCore
import SwiftUI

struct ReceiverRootView: View {
    @EnvironmentObject private var model: ReceiverAppModel
    @State private var showingPostgresSheet = false
    @State private var showingDetailsSheet = false

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
                if !model.pendingInvitations.isEmpty {
                    invitationBanner
                }

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

    private var invitationBanner: some View {
        VStack(spacing: 10) {
            ForEach(model.pendingInvitations) { invitation in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(Color.accentColor)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("New analysis request")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Text(invitation.title)
                            .font(.title3.weight(.semibold))

                        Text("From \(invitation.senderName)\(invitation.senderOrganization.map { " · \($0)" } ?? "")")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Text(invitation.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 8) {
                        Button {
                            model.acceptInvitation(invitation)
                        } label: {
                            Text("Accept")
                                .frame(minWidth: 90)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            model.dismissInvitation(invitation)
                        } label: {
                            Text("Dismiss")
                                .frame(minWidth: 90)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sessionControlSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        model.addDataSource()
                    } label: {
                        Label("Add CSV / Parquet", systemImage: "plus.circle")
                            .font(.body.weight(.medium))
                            .padding(.vertical, 4)
                    }
                    .controlSize(.large)
                    .disabled(model.loadedPackage == nil)

                    Button {
                        showingPostgresSheet = true
                    } label: {
                        Label("Add Postgres", systemImage: "cylinder.split.1x2")
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
        .sheet(isPresented: $showingPostgresSheet) {
            PostgresConnectionSheet { config in
                model.addPostgresSource(config)
            }
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

                    Button {
                        showingDetailsSheet = true
                    } label: {
                        Label("View full request", systemImage: "doc.text.magnifyingglass")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingDetailsSheet) {
            if let package = model.loadedPackage {
                RequestDetailsSheet(package: package)
            }
        }
    }

    private func icon(for kind: DataSourceKind) -> String {
        switch kind {
        case .csv: return "tablecells"
        case .parquet: return "tablecells.badge.ellipsis"
        case .database: return "cylinder.split.1x2"
        }
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
                            HStack {
                                Image(systemName: icon(for: source.kind))
                                    .foregroundStyle(.tint)
                                Text(source.alias)
                                    .font(.headline)
                                Text(source.kind.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.secondary.opacity(0.15))
                                    )
                            }
                            Text(source.displayName)
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

                    StructuredPayloadView(payloadJSON: draft.payload)

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
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if model.agentMessages.isEmpty {
                    Text("The agent has not said anything yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.agentMessages.enumerated()), id: \.offset) { _, message in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "sparkle")
                                .foregroundStyle(.tint)
                                .font(.callout)
                                .padding(.top, 2)
                            Text(message)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Agent Messages")
                .font(.headline)
        }
    }
}

private struct StructuredPayloadView: View {
    let payloadJSON: String
    @State private var showRawJSON = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let parsed = parse() {
                ForEach(parsed.keys.sorted(), id: \.self) { key in
                    fieldView(label: key, value: parsed[key] ?? "")
                }
            }

            DisclosureGroup(isExpanded: $showRawJSON) {
                ScrollView(.horizontal) {
                    Text(payloadJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            } label: {
                Text("Raw JSON payload")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func fieldView(label: String, value: Any) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prettyLabel(label))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            valueView(value: value)
        }
    }

    @ViewBuilder
    private func valueView(value: Any) -> some View {
        if let string = value as? String {
            Text(string)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let number = value as? NSNumber {
            Text("\(number)")
                .font(.body.monospacedDigit())
        } else if let array = value as? [[String: Any]] {
            tableView(rows: array)
        } else if let array = value as? [Any] {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(array.enumerated()), id: \.offset) { _, element in
                    Text("• \(String(describing: element))")
                        .font(.body)
                }
            }
        } else if let dict = value as? [String: Any] {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(dict.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .top) {
                        Text("\(prettyLabel(key)):")
                            .font(.callout.weight(.medium))
                        Text(String(describing: dict[key] ?? ""))
                            .font(.callout)
                    }
                }
            }
        } else {
            Text(String(describing: value))
                .font(.body)
        }
    }

    @ViewBuilder
    private func tableView(rows: [[String: Any]]) -> some View {
        let columns = rows.flatMap { $0.keys }.reduce(into: [String]()) { accumulator, key in
            if !accumulator.contains(key) {
                accumulator.append(key)
            }
        }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(columns, id: \.self) { column in
                    Text(prettyLabel(column))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
            }
            .background(Color.secondary.opacity(0.08))

            Divider()

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 0) {
                    ForEach(columns, id: \.self) { column in
                        Text(cellText(row[column]))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .textSelection(.enabled)
                    }
                }
                .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.05))

                if index != rows.count - 1 {
                    Divider()
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func cellText(_ value: Any?) -> String {
        guard let value else {
            return ""
        }

        if let string = value as? String {
            return string
        }

        if let number = value as? NSNumber {
            return "\(number)"
        }

        return String(describing: value)
    }

    private func prettyLabel(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
    }

    private func parse() -> [String: Any]? {
        guard let data = payloadJSON.data(using: .utf8) else {
            return nil
        }

        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private struct RequestDetailsSheet: View {
    let package: AgentPackage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(package.title)
                        .font(.title2.weight(.bold))
                    Text("From \(package.sender.name) · \(package.sender.organization ?? "Independent sender")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section(title: "Purpose", markdown: package.purposeMarkdown)
                    section(title: "Instructions for the agent", markdown: package.instructionsMarkdown)
                    outputContractSection
                    senderMetaSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    private func section(title: String, markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))

            markdownBody(markdown)
        }
    }

    private var outputContractSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Output contract")
                .font(.title3.weight(.semibold))

            Text(package.outputContract.description)
                .font(.body)

            HStack(spacing: 6) {
                ForEach(package.outputContract.topLevelFields, id: \.self) { field in
                    Text(field)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.15))
                        )
                }
            }
        }
    }

    private var senderMetaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sender")
                .font(.title3.weight(.semibold))
            Text("\(package.sender.name)")
                .font(.body)
            Text(package.sender.email)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let organization = package.sender.organization {
                Text(organization)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Expires \(package.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func markdownBody(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    private struct MarkdownBlock {
        enum Kind { case heading(Int); case bullet; case paragraph }
        let kind: Kind
        let text: String
    }

    private func blocks(from markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            if !paragraphBuffer.isEmpty {
                blocks.append(MarkdownBlock(kind: .paragraph, text: paragraphBuffer.joined(separator: " ")))
                paragraphBuffer.removeAll()
            }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                continue
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .heading(3), text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .heading(2), text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .heading(1), text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .bullet, text: String(line.dropFirst(2))))
            } else {
                paragraphBuffer.append(line)
            }
        }

        flushParagraph()
        return blocks
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(attributedInline(block.text))
                .font(headingFont(level: level))
                .padding(.top, level == 1 ? 6 : 4)
        case .bullet:
            HStack(alignment: .top, spacing: 8) {
                Text("•").bold()
                Text(attributedInline(block.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph:
            Text(attributedInline(block.text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        default: return .body.weight(.semibold)
        }
    }

    private func attributedInline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct PostgresConnectionSheet: View {
    let onSubmit: (PostgresConnectionConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var host = "127.0.0.1"
    @State private var port = "5433"
    @State private var database = "cardiac"
    @State private var user = "agent"
    @State private var password = "agent"
    @State private var table = "cardiac_admissions_registry"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Postgres Source")
                .font(.title2.weight(.semibold))

            Text("DuckDB will ATTACH this Postgres server read-only. The password stays local to this app and is never sent to the agent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Host")
                    TextField("127.0.0.1", text: $host)
                }
                GridRow {
                    Text("Port")
                    TextField("5433", text: $port)
                }
                GridRow {
                    Text("Database")
                    TextField("cardiac", text: $database)
                }
                GridRow {
                    Text("User")
                    TextField("agent", text: $user)
                }
                GridRow {
                    Text("Password")
                    SecureField("", text: $password)
                }
                GridRow {
                    Text("Table")
                    TextField("cardiac_admissions_registry", text: $table)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button {
                    let config = PostgresConnectionConfig(
                        host: host,
                        port: Int(port) ?? 5432,
                        database: database,
                        user: user,
                        password: password,
                        table: table
                    )
                    onSubmit(config)
                    dismiss()
                } label: {
                    Text("Approve Source")
                        .fontWeight(.semibold)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
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
