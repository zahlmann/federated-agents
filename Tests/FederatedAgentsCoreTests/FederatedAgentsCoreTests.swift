import FederatedAgentsCore
import Foundation
import Testing

@Test
func prototypePrivacyEngineRejectsRawSelect() {
    let engine = PrototypePrivacyEngine()
    let decision = engine.evaluate(sql: "SELECT employee_id, salary FROM payroll", approvedSources: [])

    #expect(decision.status == .rejected)
}

@Test
func prototypePrivacyEngineApprovesAggregateQuery() {
    let engine = PrototypePrivacyEngine()
    let decision = engine.evaluate(
        sql: "SELECT department, count(*) AS people FROM payroll GROUP BY department",
        approvedSources: []
    )

    #expect(decision.status == .approved)
    #expect(decision.rewrittenSQL != nil)
}

@Test
func samplePackageSignatureVerifies() throws {
    let loader = AgentPackageLoader()
    let packageURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/FederatedAgentsReceiver/Resources/Samples/PeopleOpsCompensationAudit.fagent")

    let package = try loader.load(from: packageURL)

    #expect(package.id == "peopleops-compensation-audit")
    #expect(package.verification.status == .verified)
}

@Test
func generatedAgentControlScriptReadsResponseFilesWithoutStdinCollision() throws {
    let builder = SessionWorkspaceBuilder()
    let packageURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/FederatedAgentsReceiver/Resources/Samples/PeopleOpsCompensationAudit.fagent")

    let package = try AgentPackageLoader().load(from: packageURL)
    let workspace = try builder.makeWorkspace(for: package, approvedSources: [])
    let agentctlPath = workspace.workspaceURL.appendingPathComponent("bin/agentctl")
    let script = try String(contentsOf: agentctlPath, encoding: .utf8)

    #expect(script.contains("wait_for_response_path"))
    #expect(script.contains("read_response_field"))
    #expect(!script.contains("wait_for_response \"$request_id\" | python3 -"))
}

@Test
func semicolonDelimitedCSVDoesNotCollapseIntoSingleColumnSchema() throws {
    let catalog = try ApprovedDataCatalog()
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sample_semicolon.csv")

    let source = try catalog.registerFile(at: fixtureURL)

    #expect(source.schema.columns.count == 5)
    #expect(source.schema.columns.map(\.name) == [
        "department",
        "level",
        "location",
        "base_salary",
        "bonus",
    ])
}

@Test
func commaDelimitedCSVRegistersAsExpected() throws {
    let catalog = try ApprovedDataCatalog()
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sample.csv")

    let source = try catalog.registerFile(at: fixtureURL)

    #expect(source.schema.columns.count == 5)
    #expect(source.schema.columns.map(\.name) == [
        "department",
        "level",
        "location",
        "base_salary",
        "bonus",
    ])
}
