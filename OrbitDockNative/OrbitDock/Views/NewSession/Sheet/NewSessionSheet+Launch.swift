import SwiftUI

extension NewSessionSheet {
  func initGitAndEnableWorktree() {
    guard let runtime = runtimeRegistry.runtimesByEndpointId[model.selectedEndpointId] else { return }
    model.isCreating = true
    Task { @MainActor in
      defer { model.isCreating = false }
      do {
        let state = try await NewSessionLaunchCoordinator.initializeGit(
          at: model.selectedPath,
          using: launchPorts(store: endpointAppState, runtime: runtime)
        )
        model.selectedPathIsGit = state.selectedPathIsGit
        model.useWorktree = state.useWorktree
      } catch {
        model.worktreeError = "Failed to initialize git: \(error.localizedDescription)"
      }
    }
  }

  func createSession() {
    guard let plan = NewSessionRequestPlanner.planLaunch(
      selectedPath: model.selectedPath,
      useWorktree: model.useWorktree,
      worktreeBranch: model.worktreeBranch,
      worktreeBaseBranch: model.worktreeBaseBranch,
      providerConfiguration: model.providerConfiguration,
      bootstrapPrompt: continuationPrompt
    ) else {
      return
    }

    switch plan.target {
      case let .worktree(repoPath, branch, baseBranch):
        createSessionWithWorktree(plan: plan, repoPath: repoPath, branch: branch, baseBranch: baseBranch)
      case .direct:
        createSessionDirect(plan: plan)
    }
  }

  func createSessionWithWorktree(
    plan: NewSessionLaunchPlan,
    repoPath: String,
    branch: String,
    baseBranch: String?
  ) {
    guard let runtime = runtimeRegistry.runtimesByEndpointId[model.selectedEndpointId] else { return }
    model.isCreating = true
    model.worktreeError = nil
    let store = endpointAppState
    Task { @MainActor in
      do {
        let worktreePath = try await NewSessionLaunchCoordinator.createWorktree(
          repoPath: repoPath,
          branchName: branch,
          baseBranch: baseBranch,
          using: launchPorts(store: store, runtime: runtime)
        )
        try await launchSession(plan: plan, cwd: worktreePath, store: store, runtime: runtime)
        dismiss()
      } catch {
        model.isCreating = false
        model.worktreeError = error.localizedDescription
      }
    }
  }

  func createSessionDirect(plan: NewSessionLaunchPlan) {
    guard case let .direct(cwd) = plan.target else { return }
    model.isCreating = true
    let store = endpointAppState
    Task { @MainActor in
      do {
        try await launchSession(plan: plan, cwd: cwd, store: store, runtime: nil)
        dismiss()
      } catch {
        model.isCreating = false
        model.codexErrorMessage = error.localizedDescription
      }
    }
  }

  func launchSession(
    plan: NewSessionLaunchPlan,
    cwd: String,
    store: ServerEndpointRuntime,
    runtime: ServerRuntime?
  ) async throws {
    let request = plan.requestTemplate.makeRequest(cwd: cwd)
    let createdSessionId = try await NewSessionLaunchCoordinator.launchSession(
      request: request,
      continuationPrompt: plan.bootstrapPrompt,
      using: launchPorts(store: store, runtime: runtime)
    )
    model.isCreating = false
    if let createdSessionId {
      router.selectSession(SessionRef(endpointId: store.endpointId, sessionId: createdSessionId))
    }
  }

  func launchPorts(store: ServerEndpointRuntime, runtime: ServerRuntime?) -> NewSessionLaunchPorts {
    NewSessionLaunchPorts(
      gitInit: { path in
        guard let runtime else { throw NewSessionLaunchCoordinatorError.runtimeUnavailable }
        _ = try await runtime.clients.worktrees.gitInit(path: path)
      },
      createWorktree: { repoPath, branchName, baseBranch in
        guard let runtime else { throw NewSessionLaunchCoordinatorError.runtimeUnavailable }
        let worktree = try await runtime.clients.worktrees.createWorktree(
          repoPath: repoPath,
          branchName: branchName,
          baseBranch: baseBranch
        )
        return worktree.worktreePath
      },
      createSession: { request in
        let response = try await store.createSession(request)
        return response.sessionId
      },
      sendBootstrapPrompt: { sessionId, prompt in
        _ = try await store.session(sessionId).api.sendMessage(content: prompt)
      }
    )
  }
}
