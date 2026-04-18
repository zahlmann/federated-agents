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
