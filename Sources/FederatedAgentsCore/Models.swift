import Foundation

public struct AgentPackage: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let sender: PackageSender
    public let expiresAt: Date
    public let callbackURL: URL?
    public let purposeMarkdown: String
    public let instructionsMarkdown: String
    public let requestedCapabilities: [CapabilityRequest]
    public let questions: [QuestionTemplate]
    public let outputContract: OutputContract
    public let verification: PackageVerification
    public let packageDirectory: URL

    public var isExpired: Bool {
        expiresAt < Date()
    }
}

public struct PackageSender: Codable, Sendable {
    public let name: String
    public let email: String
    public let organization: String?
}

public struct CapabilityRequest: Codable, Identifiable, Sendable {
    public let id: String
    public let kind: CapabilityKind
    public let reason: String
    public let required: Bool
}

public enum CapabilityKind: String, Codable, CaseIterable, Sendable {
    case analyzeCSV
    case analyzeParquet
    case connectDatabase
    case sendApprovedResult

    public var title: String {
        switch self {
        case .analyzeCSV:
            "Analyze CSV files"
        case .analyzeParquet:
            "Analyze Parquet files"
        case .connectDatabase:
            "Connect to one database"
        case .sendApprovedResult:
            "Send approved result"
        }
    }
}

public struct QuestionTemplate: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let prompt: String
    public let placeholder: String?
}

public struct OutputContract: Codable, Sendable {
    public let description: String
    public let topLevelFields: [String]
}

public struct PackageVerification: Sendable {
    public let status: VerificationStatus
    public let message: String
    public let fileDigests: [TrackedFileDigest]
}

public enum VerificationStatus: String, Sendable {
    case verified
    case invalid
    case unsigned
}

public struct TrackedFileDigest: Codable, Hashable, Sendable {
    public let path: String
    public let sha256: String
}

public struct ApprovedDataSource: Identifiable, Sendable {
    public let id: UUID
    public let alias: String
    public let kind: DataSourceKind
    public let url: URL
    public let schema: DataSourceSchema
    public let displayName: String

    public init(
        id: UUID,
        alias: String,
        kind: DataSourceKind,
        url: URL,
        schema: DataSourceSchema,
        displayName: String? = nil
    ) {
        self.id = id
        self.alias = alias
        self.kind = kind
        self.url = url
        self.schema = schema
        self.displayName = displayName ?? url.lastPathComponent
    }
}

public struct PostgresConnectionConfig: Sendable, Hashable {
    public let host: String
    public let port: Int
    public let database: String
    public let user: String
    public let password: String
    public let table: String

    public init(host: String, port: Int, database: String, user: String, password: String, table: String) {
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = password
        self.table = table
    }

    public var attachString: String {
        "host=\(host) port=\(port) dbname=\(database) user=\(user) password=\(password)"
    }

    public var publicDisplayName: String {
        "postgres://\(host):\(port)/\(database)#\(table)"
    }
}

public enum DataSourceKind: String, Codable, Sendable {
    case csv
    case parquet
    case database

    public var title: String {
        switch self {
        case .csv:
            "CSV"
        case .parquet:
            "Parquet"
        case .database:
            "Database"
        }
    }
}

public struct DataSourceSchema: Codable, Sendable {
    public let alias: String
    public let columns: [SchemaColumn]
}

public struct SchemaColumn: Codable, Sendable, Hashable {
    public let name: String
    public let type: String
    public let looksSensitive: Bool
}

public struct PendingQuestion: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let prompt: String
    public let choices: [String]
    public let requestPath: URL

    public init(
        id: String,
        title: String,
        prompt: String,
        choices: [String],
        requestPath: URL
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.choices = choices
        self.requestPath = requestPath
    }
}

public struct QueryReview: Identifiable, Sendable {
    public let id: String
    public let sql: String
    public let rationale: String
    public let requestPath: URL

    public init(
        id: String,
        sql: String,
        rationale: String,
        requestPath: URL
    ) {
        self.id = id
        self.sql = sql
        self.rationale = rationale
        self.requestPath = requestPath
    }
}

public struct OutboundDraft: Identifiable, Sendable {
    public let id: String
    public let summary: String
    public let payload: String
    public let requestPath: URL

    public init(
        id: String,
        summary: String,
        payload: String,
        requestPath: URL
    ) {
        self.id = id
        self.summary = summary
        self.payload = payload
        self.requestPath = requestPath
    }
}

public struct SafeQueryResult: Sendable {
    public let columns: [String]
    public let rows: [[String]]
}

public struct PrivacyDecision: Sendable {
    public let status: PrivacyDecisionStatus
    public let message: String
    public let rewrittenSQL: String?
}

public enum PrivacyDecisionStatus: Sendable {
    case approved
    case rejected
}

public struct PackageManifest: Codable, Sendable {
    public let packageID: String
    public let title: String
    public let summary: String
    public let sender: PackageSender
    public let expiresAt: Date
    public let callbackURL: URL?
    public let purposeFile: String
    public let instructionsFile: String
    public let signingPayloadFile: String?
    public let signature: PackageSignature?
    public let requestedCapabilities: [CapabilityRequest]
    public let questions: [QuestionTemplate]
    public let outputContract: OutputContract
}

public struct PackageSignature: Codable, Sendable {
    public let algorithm: String
    public let publicKeyBase64: String
    public let signatureBase64: String
}

public struct SigningPayload: Codable, Sendable {
    public let packageID: String
    public let expiresAt: Date
    public let trackedFiles: [TrackedFileDigest]
}

public struct LocalSessionWorkspace: Sendable {
    public let rootURL: URL
    public let workspaceURL: URL
    public let requestDirectoryURL: URL
    public let responseDirectoryURL: URL
    public let outboundDirectoryURL: URL
    public let approvedSchemaURL: URL
}

public enum CodexEvent: Sendable {
    case status(String)
    case agentMessage(String)
    case rawLine(String)
    case finished(Int32)
}

public enum SessionRequestKind: String, Codable {
    case askUser = "ask_user"
    case safeQuery = "safe_query"
    case submitResult = "submit_result"
    case log
}

public struct SessionRequestEnvelope: Codable {
    public let id: String
    public let kind: SessionRequestKind
    public let createdAt: Date
    public let title: String?
    public let prompt: String?
    public let placeholder: String?
    public let sql: String?
    public let rationale: String?
    public let summary: String?
    public let resultJSON: String?
    public let message: String?
}

public struct SessionResponseEnvelope: Codable {
    public let id: String
    public let status: String
    public let message: String
    public let answer: String?
    public let resultJSON: String?

    public init(
        id: String,
        status: String,
        message: String,
        answer: String?,
        resultJSON: String?
    ) {
        self.id = id
        self.status = status
        self.message = message
        self.answer = answer
        self.resultJSON = resultJSON
    }
}
