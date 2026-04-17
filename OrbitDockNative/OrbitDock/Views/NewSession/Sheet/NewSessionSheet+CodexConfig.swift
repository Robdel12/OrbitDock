import SwiftUI

extension NewSessionSheet {
  func inspectCodexConfig() {
    guard !model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      codexConfigState.inspectorError =
        "Choose a project folder first so OrbitDock can resolve the Codex config that applies there, including user and project-level layers."
      codexConfigState.inspectorResponse = nil
      presentation.showCodexInspector = true
      return
    }

    codexConfigState.inspectorLoading = true
    codexConfigState.inspectorError = nil
    presentation.showCodexInspector = true

    let shouldApplyOverrides = model.codexConfigMode == .custom
    let request = SessionsClient.CodexInspectRequest(
      cwd: model.selectedPath,
      codexConfigSource: .user,
      codexConfigMode: model.codexConfigMode,
      codexConfigProfile: normalizedCodexProfile,
      model: shouldApplyOverrides ? model.codexModel : nil,
      modelProvider: shouldApplyOverrides ? normalizedCodexModelProvider : nil,
      approvalPolicy: shouldApplyOverrides ? model.selectedAutonomy.approvalPolicy : nil,
      approvalPolicyDetails: shouldApplyOverrides ? model.selectedAutonomy.approvalPolicyDetails : nil,
      sandboxMode: shouldApplyOverrides ? model.selectedAutonomy.sandboxMode : nil,
      sandboxPolicyDetails: shouldApplyOverrides ? model.selectedAutonomy.sandboxPolicyDetails : nil,
      collaborationMode: shouldApplyOverrides ? model.codexCollaborationMode.rawValue : nil,
      multiAgent: shouldApplyOverrides ? model.codexMultiAgentEnabled : nil,
      personality: shouldApplyOverrides ? model.codexPersonality.requestValue : nil,
      serviceTier: shouldApplyOverrides ? model.codexServiceTier.requestValue : nil,
      developerInstructions: shouldApplyOverrides ? normalizedCodexInstructions : nil,
      effort: nil
    )

    Task {
      do {
        codexConfigState.inspectorResponse = try await endpointAppState.clients.sessions.inspectCodexConfig(request)
      } catch {
        codexConfigState.inspectorResponse = nil
        codexConfigState.inspectorError = error.localizedDescription
      }
      codexConfigState.inspectorLoading = false
    }
  }

  func openCodexConfigManager() {
    guard normalizedProjectPathForConfigEditor != nil else {
      codexConfigState.inspectorError =
        "Choose a project folder first so OrbitDock can resolve the Codex config layers that apply here before editing saved profiles and providers."
      codexConfigState.inspectorResponse = nil
      presentation.showCodexInspector = true
      return
    }
    presentation.showCodexConfigManager = true
  }

  var normalizedCodexInstructions: String? {
    let trimmed = model.codexInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var normalizedCodexProfile: String? {
    let trimmed = model.codexConfigProfile.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var normalizedCodexModelProvider: String? {
    let trimmed = model.codexModelProvider.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var normalizedProjectPathForConfigEditor: String? {
    let trimmed = model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var scopedCodexModelProvider: String? {
    guard model.provider == .codex, model.codexConfigMode == .custom else { return nil }
    let provider = model.codexModelProvider.trimmingCharacters(in: .whitespacesAndNewlines)
    return provider.isEmpty ? nil : provider
  }

  func refreshCodexConfigCatalogIfNeeded(force _: Bool = false) {
    guard model.provider == .codex else {
      codexConfigState.catalog = nil
      codexConfigState.catalogError = nil
      codexConfigState.catalogLoading = false
      codexConfigState.catalogRequiresProjectPath = false
      return
    }

    let cwd = model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    codexConfigState.catalogLoading = true
    codexConfigState.catalogError = nil
    codexConfigState.catalogRequiresProjectPath = false
    codexConfigState.catalogRequestID += 1
    let requestID = codexConfigState.catalogRequestID

    Task {
      do {
        let response = try await endpointAppState.clients.sessions.fetchCodexConfigCatalog(
          cwd: cwd.isEmpty ? "" : cwd
        )
        await MainActor.run {
          guard requestID == codexConfigState.catalogRequestID,
                model.provider == .codex,
                model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines) == cwd
          else { return }
          codexConfigState.catalog = response
          codexConfigState.catalogLoading = false
          codexConfigState.catalogRequiresProjectPath = false
          if model.codexConfigMode == .profile,
             model.codexConfigProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            model.codexConfigProfile = response.profiles.first?.name ?? ""
          }
          if model.codexConfigMode == .custom,
             model.codexModelProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            model.codexModelProvider = response.providers.first?.id ?? ""
          }
        }
      } catch {
        await MainActor.run {
          guard requestID == codexConfigState.catalogRequestID,
                model.provider == .codex,
                model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines) == cwd
          else { return }
          codexConfigState.catalog = nil
          codexConfigState.catalogRequiresProjectPath = isLegacyCodexCatalogProjectRequirement(error: error, cwd: cwd)
          codexConfigState.catalogError = codexConfigState.catalogRequiresProjectPath ? nil : error.localizedDescription
          codexConfigState.catalogLoading = false
        }
      }
    }
  }

  func isLegacyCodexCatalogProjectRequirement(error: Error, cwd: String) -> Bool {
    guard cwd.isEmpty else { return false }
    guard let requestError = error as? ServerRequestError else { return false }
    return requestError.statusCode == 400
  }

  func refreshScopedCodexModelsIfNeeded(force _: Bool = false) {
    guard model.provider == .codex else {
      codexConfigState.scopedModels = nil
      codexConfigState.scopedModelsLoading = false
      codexConfigState.scopedModelsError = nil
      return
    }

    guard model.codexConfigMode == .custom else {
      codexConfigState.scopedModels = nil
      codexConfigState.scopedModelsLoading = false
      codexConfigState.scopedModelsError = nil
      return
    }

    let cwd = model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cwd.isEmpty else {
      codexConfigState.scopedModels = nil
      codexConfigState.scopedModelsLoading = false
      codexConfigState.scopedModelsError = nil
      return
    }

    let modelProvider = scopedCodexModelProvider
    guard modelProvider != nil else {
      codexConfigState.scopedModels = nil
      codexConfigState.scopedModelsLoading = false
      codexConfigState.scopedModelsError = nil
      return
    }

    codexConfigState.scopedModelsRequestID += 1
    let requestID = codexConfigState.scopedModelsRequestID
    codexConfigState.scopedModelsLoading = true
    codexConfigState.scopedModelsError = nil
    codexConfigState.scopedModels = nil

    Task {
      do {
        let models = try await endpointAppState.clients.usage.listCodexModels(
          cwd: cwd,
          modelProvider: modelProvider
        )
        await MainActor.run {
          guard requestID == codexConfigState.scopedModelsRequestID,
                model.provider == .codex,
                model.codexConfigMode == .custom,
                model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines) == cwd,
                scopedCodexModelProvider == modelProvider
          else { return }
          codexConfigState.scopedModels = models
          codexConfigState.scopedModelsLoading = false
          codexConfigState.scopedModelsError = nil
        }
      } catch {
        await MainActor.run {
          guard requestID == codexConfigState.scopedModelsRequestID else { return }
          codexConfigState.scopedModels = nil
          codexConfigState.scopedModelsLoading = false
          codexConfigState.scopedModelsError = error.localizedDescription
        }
      }
    }
  }
}
