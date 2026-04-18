import Foundation

public struct IncomingInvitation: Identifiable, Sendable {
    public let id: String
    public let packageURL: URL
    public let title: String
    public let senderName: String
    public let senderEmail: String
    public let senderOrganization: String?
    public let summary: String
    public let arrivedAt: Date

    public init(
        id: String,
        packageURL: URL,
        title: String,
        senderName: String,
        senderEmail: String,
        senderOrganization: String?,
        summary: String,
        arrivedAt: Date
    ) {
        self.id = id
        self.packageURL = packageURL
        self.title = title
        self.senderName = senderName
        self.senderEmail = senderEmail
        self.senderOrganization = senderOrganization
        self.summary = summary
        self.arrivedAt = arrivedAt
    }
}

public enum InboxLocator {
    public static let folderName = "FederatedAgents"
    public static let inboxSubfolder = "Inbox"
    public static let archivedSubfolder = "Inbox/.archived"

    public static func inboxURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return base
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(inboxSubfolder, isDirectory: true)
    }

    public static func archivedURL() -> URL {
        inboxURL().appendingPathComponent(".archived", isDirectory: true)
    }

    @discardableResult
    public static func ensureExists() -> URL {
        let url = inboxURL()
        let archived = archivedURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
public final class InboxWatcher {
    public typealias InvitationHandler = @MainActor (IncomingInvitation) -> Void

    private let inboxURL: URL
    private let handler: InvitationHandler
    private let decoder: JSONDecoder

    private var seenPackageIDs: Set<String> = []
    private var pollTask: Task<Void, Never>?

    public init(inboxURL: URL = InboxLocator.ensureExists(), handler: @escaping InvitationHandler) {
        self.inboxURL = inboxURL
        self.handler = handler

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func start() {
        stop()

        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.scan()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func markSeen(_ packageID: String) {
        seenPackageIDs.insert(packageID)
    }

    private func scan() {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries {
            guard entry.pathExtension.lowercased() == "fagent" else {
                continue
            }

            guard let invitation = invitation(from: entry) else {
                continue
            }

            if seenPackageIDs.contains(invitation.id) {
                continue
            }

            seenPackageIDs.insert(invitation.id)
            handler(invitation)
        }
    }

    private func invitation(from packageURL: URL) -> IncomingInvitation? {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }

        guard let manifest = try? decoder.decode(PackageManifest.self, from: data) else {
            return nil
        }

        let requiredFiles: [String] = [
            manifest.purposeFile,
            manifest.instructionsFile,
            manifest.signingPayloadFile,
        ].compactMap { $0 }

        for relativePath in requiredFiles {
            let fileURL = packageURL.appendingPathComponent(relativePath)
            if !FileManager.default.isReadableFile(atPath: fileURL.path) {
                return nil
            }
        }

        let arrived = (try? packageURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()

        return IncomingInvitation(
            id: manifest.packageID,
            packageURL: packageURL,
            title: manifest.title,
            senderName: manifest.sender.name,
            senderEmail: manifest.sender.email,
            senderOrganization: manifest.sender.organization,
            summary: manifest.summary,
            arrivedAt: arrived
        )
    }
}
