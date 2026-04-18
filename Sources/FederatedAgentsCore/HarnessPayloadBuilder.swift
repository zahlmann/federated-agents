import Foundation

public enum HarnessPayloadBuilder {
    public static func buildPackageMarkdown(_ package: AgentPackage) -> String {
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

    public static func buildApprovedSchemaMarkdown(
        from approvedSources: [ApprovedDataSource]
    ) -> String {
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
}

public enum HarnessBinaryLocator {
    public static let environmentVariable = "RECEIVER_HARNESS_BIN"
    public static let binaryName = "receiver-bridge"

    public static func locate(bundle: Bundle = .main) -> URL? {
        if let explicit = ProcessInfo.processInfo.environment[environmentVariable],
           !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }

        if let executableURL = bundle.executableURL {
            let candidate = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent(binaryName)

            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        if let bundlePath = bundle.executablePath {
            let candidate = URL(fileURLWithPath: bundlePath)
                .deletingLastPathComponent()
                .appendingPathComponent(binaryName)

            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}

public struct HarnessOutboundWorkspace: Sendable {
    public let directoryURL: URL
    public let approvedResultURL: URL
}

public enum HarnessOutboundWorkspaceFactory {
    public static func make(packageID: String) throws -> HarnessOutboundWorkspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("federated-agents")
            .appendingPathComponent(packageID)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("outbound")

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        return HarnessOutboundWorkspace(
            directoryURL: root,
            approvedResultURL: root.appendingPathComponent("approved-result.json")
        )
    }
}
