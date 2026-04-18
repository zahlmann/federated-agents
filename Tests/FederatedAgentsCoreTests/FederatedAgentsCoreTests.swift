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
