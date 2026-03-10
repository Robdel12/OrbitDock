import Foundation

enum NewSessionLaunchCoordinatorError: LocalizedError, Equatable {
  case runtimeUnavailable

  var errorDescription: String? {
    switch self {
      case .runtimeUnavailable:
        "No connected runtime is available for this endpoint."
    }
  }
}

struct NewSessionGitInitState: Equatable, Sendable {
  let selectedPathIsGit: Bool
  let useWorktree: Bool
}

struct NewSessionLaunchPorts: Sendable {
  let gitInit: @Sendable (String) async throws -> Void
  let createWorktree: @Sendable (String, String, String?) async throws -> String
  let createSession: @Sendable (SessionsClient.CreateSessionRequest) async throws -> String?
  let sendBootstrapPrompt: @Sendable (String, String) async throws -> Void
}

enum NewSessionLaunchCoordinator {
  static func initializeGit(
    at path: String,
    using ports: NewSessionLaunchPorts
  ) async throws -> NewSessionGitInitState {
    try await ports.gitInit(path)
    return NewSessionGitInitState(selectedPathIsGit: true, useWorktree: true)
  }

  static func createWorktree(
    repoPath: String,
    branchName: String,
    baseBranch: String?,
    using ports: NewSessionLaunchPorts
  ) async throws -> String {
    try await ports.createWorktree(repoPath, branchName, baseBranch)
  }

  @discardableResult
  static func launchSession(
    request: SessionsClient.CreateSessionRequest,
    continuationPrompt: String?,
    using ports: NewSessionLaunchPorts
  ) async throws -> String? {
    let sessionId = try await ports.createSession(request)
    guard let continuationPrompt, let sessionId else {
      return sessionId
    }

    try await ports.sendBootstrapPrompt(sessionId, continuationPrompt)
    return sessionId
  }
}
