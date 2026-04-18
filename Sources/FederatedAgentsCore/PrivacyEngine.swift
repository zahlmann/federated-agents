import Foundation

public protocol PrivacyEngine {
    func evaluate(sql: String, approvedSources: [ApprovedDataSource]) -> PrivacyDecision
}

public struct PrototypePrivacyEngine: PrivacyEngine {
    public init() {}

    public func evaluate(sql: String, approvedSources: [ApprovedDataSource]) -> PrivacyDecision {
        let normalized = sql
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let blockedTerms = [
            "insert ",
            "update ",
            "delete ",
            "drop ",
            "alter ",
            "create ",
            "attach ",
            "copy ",
            "pragma ",
            "install ",
            "load ",
            "export ",
            "read_csv",
            "read_parquet",
        ]

        if blockedTerms.contains(where: normalized.contains) {
            return PrivacyDecision(
                status: .rejected,
                message: "This prototype privacy gate only allows read-only aggregate analysis.",
                rewrittenSQL: nil
            )
        }

        if !(normalized.hasPrefix("select ") || normalized.hasPrefix("with ")) {
            return PrivacyDecision(
                status: .rejected,
                message: "Only SELECT-style analytical queries are allowed.",
                rewrittenSQL: nil
            )
        }

        let aggregateFunctions = ["count(", "sum(", "avg(", "min(", "max("]
        let containsAggregate = aggregateFunctions.contains { normalized.contains($0) }

        if !containsAggregate {
            return PrivacyDecision(
                status: .rejected,
                message: "The query must compute aggregates. Raw row retrieval is not allowed.",
                rewrittenSQL: nil
            )
        }

        if leaksIdentifiers(in: normalized, approvedSources: approvedSources) {
            return PrivacyDecision(
                status: .rejected,
                message: "The query appears to group or project fields that look like identifiers. Reformulate with broader aggregate dimensions.",
                rewrittenSQL: nil
            )
        }

        let rewrittenSQL = """
        SELECT * FROM (
        \(sql)
        ) AS privacy_safe_result
        LIMIT 100
        """

        return PrivacyDecision(
            status: .approved,
            message: "Approved by the prototype aggregate-only privacy gate. Replace this engine with Qrlew for real differential privacy rewriting.",
            rewrittenSQL: rewrittenSQL
        )
    }

    private func leaksIdentifiers(
        in normalizedSQL: String,
        approvedSources: [ApprovedDataSource]
    ) -> Bool {
        let sensitiveNames = approvedSources
            .flatMap(\.schema.columns)
            .filter(\.looksSensitive)
            .map { $0.name.lowercased() }

        guard !sensitiveNames.isEmpty else {
            return false
        }

        let suspectPatterns = sensitiveNames.map { "\"\($0)\"" } + sensitiveNames
        return suspectPatterns.contains(where: normalizedSQL.contains)
    }
}
