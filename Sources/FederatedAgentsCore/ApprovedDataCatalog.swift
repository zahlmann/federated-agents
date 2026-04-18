import DuckDB
import Foundation

public enum ApprovedDataCatalogError: LocalizedError {
    case unsupportedFileType(URL)
    case missingSource(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let url):
            "Unsupported data source type: \(url.lastPathComponent)"
        case .missingSource(let alias):
            "The approved source \(alias) is missing."
        }
    }
}

public final class ApprovedDataCatalog {
    public private(set) var sources: [ApprovedDataSource] = []

    private let database: Database
    private let connection: Connection

    public init() throws {
        database = try Database(store: .inMemory)
        connection = try database.connect()
    }

    @discardableResult
    public func registerFile(
        at fileURL: URL,
        alias preferredAlias: String? = nil
    ) throws -> ApprovedDataSource {
        let kind = dataSourceKind(for: fileURL)
        let alias = makeAlias(from: preferredAlias ?? fileURL.deletingPathExtension().lastPathComponent)
        let sql = registrationSQL(for: kind, alias: alias, fileURL: fileURL)

        try connection.execute(sql)
        let schema = try describe(alias: alias)

        let source = ApprovedDataSource(
            id: UUID(),
            alias: alias,
            kind: kind,
            url: fileURL,
            schema: schema
        )

        sources.append(source)
        return source
    }

    public func schemaMarkdown() -> String {
        var lines = [
            "# Approved Schema",
            "",
            "The agent can inspect this schema, but it cannot inspect raw rows or raw files.",
            "",
        ]

        for source in sources {
            lines.append("## \(source.alias)")
            lines.append("")
            lines.append("- Kind: \(source.kind.title)")
            lines.append("- Display name: \(source.url.lastPathComponent)")
            lines.append("- Raw data access: blocked")
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

    public func executeSafeQuery(
        _ sql: String,
        using privacyEngine: PrivacyEngine
    ) throws -> (PrivacyDecision, SafeQueryResult?) {
        let decision = privacyEngine.evaluate(sql: sql, approvedSources: sources)

        guard
            decision.status == .approved,
            let rewrittenSQL = decision.rewrittenSQL
        else {
            return (decision, nil)
        }

        let previewResult = try connection.query(rewrittenSQL)
        let columnNames = (0..<previewResult.columnCount).map { previewResult.columnName(at: $0) }

        let castedColumns = columnNames
            .map { quoteIdentifier($0) }
            .map { "CAST(\($0) AS VARCHAR) AS \($0)" }
            .joined(separator: ", ")

        let displaySQL = """
        SELECT \(castedColumns)
        FROM (
        \(rewrittenSQL)
        ) AS result_rows
        """

        let displayResult = try connection.query(displaySQL)
        let rows = rowsFromStringResult(displayResult)

        return (
            decision,
            SafeQueryResult(columns: columnNames, rows: rows)
        )
    }

    private func registrationSQL(
        for kind: DataSourceKind,
        alias: String,
        fileURL: URL
    ) -> String {
        let safePath = fileURL.path.replacingOccurrences(of: "'", with: "''")

        switch kind {
        case .csv:
            return """
            CREATE OR REPLACE VIEW \(quoteIdentifier(alias)) AS
            SELECT * FROM read_csv_auto('\(safePath)', SAMPLE_SIZE=-1);
            """
        case .parquet:
            return """
            CREATE OR REPLACE VIEW \(quoteIdentifier(alias)) AS
            SELECT * FROM read_parquet('\(safePath)');
            """
        case .database:
            return ""
        }
    }

    private func describe(alias: String) throws -> DataSourceSchema {
        let result = try connection.query("DESCRIBE SELECT * FROM \(quoteIdentifier(alias));")
        let names = result.column(at: 0).cast(to: String.self)
        let types = result.column(at: 1).cast(to: String.self)

        var columns: [SchemaColumn] = []

        for index in 0..<Int(result.rowCount) {
            guard
                let name = names[DBInt(index)],
                let type = types[DBInt(index)]
            else {
                continue
            }

            columns.append(
                SchemaColumn(
                    name: name,
                    type: type,
                    looksSensitive: looksSensitive(columnName: name)
                )
            )
        }

        return DataSourceSchema(alias: alias, columns: columns)
    }

    private func dataSourceKind(for fileURL: URL) -> DataSourceKind {
        switch fileURL.pathExtension.lowercased() {
        case "csv":
            .csv
        case "parquet":
            .parquet
        default:
            .database
        }
    }

    private func makeAlias(from value: String) -> String {
        let lowered = value.lowercased()
        let cleaned = lowered.replacingOccurrences(
            of: #"[^a-z0-9_]+"#,
            with: "_",
            options: .regularExpression
        )
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let baseAlias = trimmed.isEmpty ? "source" : trimmed

        if !sources.contains(where: { $0.alias == baseAlias }) {
            return baseAlias
        }

        var suffix = 2
        while sources.contains(where: { $0.alias == "\(baseAlias)_\(suffix)" }) {
            suffix += 1
        }

        return "\(baseAlias)_\(suffix)"
    }

    private func looksSensitive(columnName: String) -> Bool {
        let sensitiveTokens = [
            "id",
            "email",
            "name",
            "phone",
            "address",
            "ssn",
            "dob",
            "patient",
            "employee",
            "customer",
            "account",
        ]

        let normalized = columnName.lowercased()
        return sensitiveTokens.contains(where: normalized.contains)
    }

    private func rowsFromStringResult(_ result: ResultSet) -> [[String]] {
        let columnCount = Int(result.columnCount)
        let columnData = (0..<columnCount).map { result.column(at: DBInt($0)).cast(to: String.self) }
        let rowCount = Int(result.rowCount)

        var rows: [[String]] = []
        rows.reserveCapacity(rowCount)

        for rowIndex in 0..<rowCount {
            let row = columnData.map { column in
                column[DBInt(rowIndex)] ?? "NULL"
            }
            rows.append(row)
        }

        return rows
    }

    private func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
