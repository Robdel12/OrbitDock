import SwiftUI

extension NewSessionSheet {
  func applyOnAppearLifecycle() {
    applyLifecyclePlan(
      NewSessionLifecyclePlanner.onAppear(
        current: lifecycleState,
        selectableEndpoints: selectableEndpoints,
        primaryEndpointId: runtimeRegistry.primaryEndpointId,
        continuationEndpointId: continuation?.endpointId,
        continuationDefaults: continuationDefaults
      )
    )
  }

  func applyPathChangeLifecycle(_ newPath: String) {
    applyLifecyclePlan(
      NewSessionLifecyclePlanner.pathChanged(
        current: lifecycleState,
        newPath: newPath
      )
    )
  }

  func applyEndpointChangeLifecycle(_ newEndpointId: UUID) {
    applyLifecyclePlan(
      NewSessionLifecyclePlanner.endpointChanged(
        current: lifecycleState,
        requestedEndpointId: newEndpointId,
        selectableEndpoints: selectableEndpoints,
        primaryEndpointId: runtimeRegistry.primaryEndpointId,
        continuationEndpointId: continuation?.endpointId,
        continuationDefaults: continuationDefaults
      )
    )
  }

  func refreshEndpointData() {
    guard model.provider == .codex else { return }
    endpointAppState.refreshCodexModels()
    endpointAppState.codexAccountService.refresh()
  }

  func syncModelSelections() {
    syncClaudeModelSelection()
    syncCodexModelSelection()
  }

  func syncClaudeModelSelection() {
    model.syncClaudeModelSelection(models: claudeModels)
  }

  func syncCodexModelSelection() {
    model.syncCodexModelSelection(models: codexModels)
  }

  func applyLifecyclePlan(_ plan: NewSessionLifecyclePlan) {
    model.applyLifecyclePlan(plan)

    if plan.shouldRefreshEndpointData {
      refreshEndpointData()
    }
    if plan.shouldSyncModelSelections {
      syncModelSelections()
    }
  }
}
