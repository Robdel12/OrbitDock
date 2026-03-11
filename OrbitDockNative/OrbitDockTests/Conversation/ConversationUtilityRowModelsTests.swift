import Testing
@testable import OrbitDock

@MainActor
struct ConversationUtilityRowModelsTests {
  @Test func workerOrchestrationPrefersActiveWorkerForSpotlight() {
    let running = makeWorker(
      id: "worker-running",
      label: "Scout",
      status: .running,
      taskSummary: "Map the auth entrypoints",
      resultSummary: nil
    )
    let completed = makeWorker(
      id: "worker-complete",
      label: "Finisher",
      status: .completed,
      taskSummary: nil,
      resultSummary: "Wrapped the smoke test"
    )

    let model = ConversationUtilityRowModels.workerOrchestration(
      workerIDs: [completed.id, running.id],
      subagentsByID: [running.id: running, completed.id: completed]
    )

    #expect(model.titleText == "Workers in play")
    #expect(model.subtitleText == "1 active in this turn")
    #expect(model.spotlightText == "Scout is on it: Map the auth entrypoints")
    #expect(model.workers.first?.id == completed.id)
    #expect(model.workers.last?.isActive == true)
  }

  @Test func workerOrchestrationFallsBackToCompletedSummaryWhenNothingIsActive() {
    let completed = makeWorker(
      id: "worker-complete",
      label: "Finisher",
      status: .completed,
      taskSummary: nil,
      resultSummary: "Confirmed the worker result returned cleanly."
    )

    let model = ConversationUtilityRowModels.workerOrchestration(
      workerIDs: [completed.id],
      subagentsByID: [completed.id: completed]
    )

    #expect(model.titleText == "Worker in play")
    #expect(model.subtitleText == "1 finished in this turn")
    #expect(model.spotlightText == "Finisher reported back: Confirmed the worker result returned cleanly.")
    #expect(model.workers.first?.isActive == false)
  }

  private func makeWorker(
    id: String,
    label: String?,
    status: ServerSubagentStatus?,
    taskSummary: String?,
    resultSummary: String?
  ) -> ServerSubagentInfo {
    ServerSubagentInfo(
      id: id,
      agentType: "worker",
      startedAt: "2026-03-10T09:00:00Z",
      endedAt: nil,
      provider: .codex,
      label: label,
      status: status,
      taskSummary: taskSummary,
      resultSummary: resultSummary,
      errorSummary: nil,
      parentSubagentId: nil,
      model: nil,
      lastActivityAt: "2026-03-10T10:00:00Z"
    )
  }
}
