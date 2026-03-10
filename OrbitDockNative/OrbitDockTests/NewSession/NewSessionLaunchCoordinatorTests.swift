@testable import OrbitDock
import Testing

private actor NewSessionLaunchRecorder {
  private(set) var initializedPaths: [String] = []
  private(set) var createdSessions: [(provider: String, cwd: String, model: String?)] = []
  private(set) var sentPrompts: [(sessionId: String, prompt: String)] = []

  func recordInitializedPath(_ path: String) {
    initializedPaths.append(path)
  }

  func recordCreatedSession(provider: String, cwd: String, model: String?) {
    createdSessions.append((provider: provider, cwd: cwd, model: model))
  }

  func recordSentPrompt(sessionId: String, prompt: String) {
    sentPrompts.append((sessionId: sessionId, prompt: prompt))
  }
}

@MainActor
struct NewSessionLaunchCoordinatorTests {
  @Test func initializeGitReturnsUpdatedPathState() async throws {
    let recorder = NewSessionLaunchRecorder()
    let ports = NewSessionLaunchPorts(
      gitInit: { path in
        await recorder.recordInitializedPath(path)
      },
      createWorktree: { _, _, _ in
        Issue.record("createWorktree should not run")
        return ""
      },
      createSession: { _ in
        Issue.record("createSession should not run")
        return nil
      },
      sendBootstrapPrompt: { _, _ in
        Issue.record("sendBootstrapPrompt should not run")
      }
    )

    let state = try await NewSessionLaunchCoordinator.initializeGit(
      at: "/tmp/project",
      using: ports
    )

    #expect(await recorder.initializedPaths == ["/tmp/project"])
    #expect(state.selectedPathIsGit == true)
    #expect(state.useWorktree == true)
  }

  @Test func createWorktreeReturnsTheResolvedPath() async throws {
    let ports = NewSessionLaunchPorts(
      gitInit: { _ in
        Issue.record("gitInit should not run")
      },
      createWorktree: { repoPath, branchName, baseBranch in
        #expect(repoPath == "/tmp/project")
        #expect(branchName == "feature/refactor")
        #expect(baseBranch == "main")
        return "/tmp/project-worktree"
      },
      createSession: { _ in
        Issue.record("createSession should not run")
        return nil
      },
      sendBootstrapPrompt: { _, _ in
        Issue.record("sendBootstrapPrompt should not run")
      }
    )

    let worktreePath = try await NewSessionLaunchCoordinator.createWorktree(
      repoPath: "/tmp/project",
      branchName: "feature/refactor",
      baseBranch: "main",
      using: ports
    )

    #expect(worktreePath == "/tmp/project-worktree")
  }

  @Test func launchSessionCreatesSessionAndSendsContinuationPrompt() async throws {
    let recorder = NewSessionLaunchRecorder()
    let request = SessionsClient.CreateSessionRequest(
      provider: "claude",
      cwd: "/tmp/project",
      model: "claude-opus",
      permissionMode: "default",
      allowedTools: ["Read"],
      disallowedTools: ["Write"],
      effort: "high"
    )
    let ports = NewSessionLaunchPorts(
      gitInit: { _ in
        Issue.record("gitInit should not run")
      },
      createWorktree: { _, _, _ in
        Issue.record("createWorktree should not run")
        return ""
      },
      createSession: { request in
        await recorder.recordCreatedSession(
          provider: request.provider,
          cwd: request.cwd,
          model: request.model
        )
        return "session-123"
      },
      sendBootstrapPrompt: { sessionId, prompt in
        await recorder.recordSentPrompt(sessionId: sessionId, prompt: prompt)
      }
    )

    let sessionId = try await NewSessionLaunchCoordinator.launchSession(
      request: request,
      continuationPrompt: "Summarize and continue.",
      using: ports
    )

    #expect(sessionId == "session-123")
    let created = await recorder.createdSessions
    #expect(created.count == 1)
    #expect(created.first?.provider == "claude")
    #expect(created.first?.cwd == "/tmp/project")
    #expect(created.first?.model == "claude-opus")
    let prompts = await recorder.sentPrompts
    #expect(prompts.count == 1)
    #expect(prompts.first?.sessionId == "session-123")
    #expect(prompts.first?.prompt == "Summarize and continue.")
  }

  @Test func launchSessionSkipsPromptWhenThereIsNoContinuation() async throws {
    let recorder = NewSessionLaunchRecorder()
    let request = SessionsClient.CreateSessionRequest(provider: "codex", cwd: "/tmp/project", model: "gpt-5-codex")
    let ports = NewSessionLaunchPorts(
      gitInit: { _ in
        Issue.record("gitInit should not run")
      },
      createWorktree: { _, _, _ in
        Issue.record("createWorktree should not run")
        return ""
      },
      createSession: { request in
        await recorder.recordCreatedSession(
          provider: request.provider,
          cwd: request.cwd,
          model: request.model
        )
        return "session-456"
      },
      sendBootstrapPrompt: { sessionId, prompt in
        await recorder.recordSentPrompt(sessionId: sessionId, prompt: prompt)
      }
    )

    let sessionId = try await NewSessionLaunchCoordinator.launchSession(
      request: request,
      continuationPrompt: nil,
      using: ports
    )

    #expect(sessionId == "session-456")
    #expect(await recorder.sentPrompts.isEmpty)
  }

  @Test func launchSessionSkipsPromptWhenSessionCreationReturnsNil() async throws {
    let recorder = NewSessionLaunchRecorder()
    let request = SessionsClient.CreateSessionRequest(provider: "claude", cwd: "/tmp/project")
    let ports = NewSessionLaunchPorts(
      gitInit: { _ in
        Issue.record("gitInit should not run")
      },
      createWorktree: { _, _, _ in
        Issue.record("createWorktree should not run")
        return ""
      },
      createSession: { request in
        await recorder.recordCreatedSession(
          provider: request.provider,
          cwd: request.cwd,
          model: request.model
        )
        return nil
      },
      sendBootstrapPrompt: { sessionId, prompt in
        await recorder.recordSentPrompt(sessionId: sessionId, prompt: prompt)
      }
    )

    let sessionId = try await NewSessionLaunchCoordinator.launchSession(
      request: request,
      continuationPrompt: "Continue from context.",
      using: ports
    )

    #expect(sessionId == nil)
    #expect(await recorder.sentPrompts.isEmpty)
  }
}
