import Foundation

public enum HarnessPayloadBuilder {
    public static func buildPackageMarkdown(_ package: AgentPackage) -> String {
        let capabilityLines = package.requestedCapabilities.map { capability in
            "- \(capability.kind.title): \(capability.reason)"
        }.joined(separator: "\n")

        return """
        # Packaged Agent Request

        ## Request identity (use these values directly)

        - Package id: `\(package.id)` — use this verbatim whenever the output contract asks for `request_id`.
        - Title: \(package.title)
        - Summary: \(package.summary)
        - Expires at: \(ISO8601DateFormatter().string(from: package.expiresAt))
        - Callback URL: \(package.callbackURL?.absoluteString ?? "No remote callback configured")

        ## Sender

        - Name: \(package.sender.name)
        - Email: \(package.sender.email)
        - Organization: \(package.sender.organization ?? "Not provided")

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

public enum HarnessEnvironmentLoader {
    public static let configPath = "~/.config/federated-agents/env"
    public static let forwardedKeys = ["OPENAI_API_KEY", "OPENAI_PROJECT", "OPENAI_BASE_URL"]

    public static func resolvedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        for (key, value) in loadConfigFile() where environment[key] == nil {
            environment[key] = value
        }

        return environment
    }

    public static func hasOpenAIKey() -> Bool {
        if let value = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        return loadConfigFile()["OPENAI_API_KEY"]?.isEmpty == false
    }

    private static func loadConfigFile() -> [String: String] {
        let expandedPath = (configPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath),
              let contents = try? String(contentsOfFile: expandedPath, encoding: .utf8)
        else {
            return [:]
        }

        var result: [String: String] = [:]

        for line in contents.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            guard let separatorIndex = trimmed.firstIndex(of: "=") else {
                continue
            }

            let key = String(trimmed[..<separatorIndex])
                .trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: separatorIndex)...])
                .trimmingCharacters(in: .whitespaces)

            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }

            if !key.isEmpty {
                result[key] = value
            }
        }

        return result
    }
}

public struct HarnessOutboundWorkspace: Sendable {
    public let directoryURL: URL
    public let approvedResultURL: URL
}

public enum HarnessTraceLog {
    public static func directoryURL() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("federated-agents", isDirectory: true)
    }

    public static func makeSessionLogURL(packageID: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")

        let timestamp = formatter.string(from: Date())
        let filename = "\(timestamp)-\(packageID).ndjson"

        return directoryURL().appendingPathComponent(filename)
    }

    public static func latestLogURL() -> URL {
        directoryURL().appendingPathComponent("latest.ndjson")
    }

    public static func refreshLatestSymlink(pointingAt target: URL) {
        let latest = latestLogURL()
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: directoryURL(),
                withIntermediateDirectories: true
            )

            if fileManager.fileExists(atPath: latest.path) ||
               (try? latest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try fileManager.removeItem(at: latest)
            }

            try fileManager.createSymbolicLink(at: latest, withDestinationURL: target)
        } catch {
            // Best effort — if the symlink can't be created we still have the real log file.
        }
    }
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
