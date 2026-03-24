import Foundation

@MainActor
struct DemoModeExperience {
  let endpoint: ServerEndpoint
  let sessionStore: SessionStore
  let rootSessions: [RootSessionNode]
  let dashboardConversations: [DashboardConversationRecord]

  init() {
    let endpoint = Self.demoEndpoint()
    self.endpoint = endpoint
    self.sessionStore = Self.demoSessionStore(endpoint: endpoint)

    let sessionList = Self.demoSessionListItems()
    self.rootSessions = sessionList.map {
      RootSessionNode(
        session: $0,
        endpointId: endpoint.id,
        endpointName: endpoint.name,
        connectionStatus: .disconnected
      )
    }
    self.dashboardConversations = Self.demoDashboardItems().map {
      DashboardConversationRecord(
        item: $0,
        endpointId: endpoint.id,
        endpointName: endpoint.name
      )
    }

    Self.populateSessionDetails(sessionStore: sessionStore, endpoint: endpoint)
  }

  private static func demoEndpoint() -> ServerEndpoint {
    ServerEndpoint(
      id: UUID(uuidString: "99999999-2222-3333-4444-555555555555")!,
      name: "OrbitDock Demo",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: false,
      isEnabled: false,
      isDefault: false
    )
  }

  private static func demoSessionStore(endpoint: ServerEndpoint) -> SessionStore {
    let baseURL = ServerURLResolver.httpBaseURL(from: endpoint.wsURL)
    let requestBuilder = HTTPRequestBuilder(baseURL: baseURL, authToken: endpoint.authToken)
    let clients = ServerClients(
      baseURL: baseURL,
      requestBuilder: requestBuilder,
      responseLoader: { _ in throw HTTPTransportError.serverUnreachable }
    )
    let connection = ServerConnection(authToken: endpoint.authToken)
    return SessionStore(
      clients: clients,
      connection: connection,
      endpointId: endpoint.id,
      endpointName: endpoint.name
    )
  }

  private static func populateSessionDetails(sessionStore: SessionStore, endpoint: ServerEndpoint) {
    let now = Date()

    var reviewSession = Session(
      id: "demo-review-session",
      endpointId: endpoint.id,
      endpointName: endpoint.name,
      endpointConnectionStatus: .disconnected,
      projectPath: "/Users/demo/OrbitDock",
      projectName: "OrbitDock",
      branch: "app-store-demo",
      model: "gpt-5-codex",
      summary: "Tighten onboarding and add a review-friendly demo path",
      firstPrompt: "Build a minimal in-app demo mode so reviewers can tap around without a server.",
      status: .active,
      workStatus: .waiting,
      startedAt: now.addingTimeInterval(-4_200),
      totalTokens: 14_820,
      totalCostUSD: 0.19,
      lastActivityAt: now.addingTimeInterval(-180),
      promptCount: 6,
      toolCount: 4,
      attentionReason: .awaitingReply,
      provider: .codex,
      codexIntegrationMode: .direct
    )
    reviewSession.repositoryRoot = "/Users/demo/OrbitDock"
    reviewSession.lastMessage = "I added a lightweight Explore Demo flow and seeded a sample session."
    reviewSession.currentDiff = """
diff --git a/OrbitDockNative/OrbitDock/Views/Server/ServerSetupView.swift b/OrbitDockNative/OrbitDock/Views/Server/ServerSetupView.swift
+ Button("Explore Demo") { ... }
"""
    reviewSession.cumulativeDiff = """
diff --git a/OrbitDockNative/OrbitDock/Views/Server/ServerSetupView.swift b/OrbitDockNative/OrbitDock/Views/Server/ServerSetupView.swift
+ Button("Explore Demo") { ... }
diff --git a/OrbitDockNative/OrbitDock/Services/DemoModeExperience.swift b/OrbitDockNative/OrbitDock/Services/DemoModeExperience.swift
+ struct DemoModeExperience { ... }
"""

    var endedSession = Session(
      id: "demo-ended-session",
      endpointId: endpoint.id,
      endpointName: endpoint.name,
      endpointConnectionStatus: .disconnected,
      projectPath: "/Users/demo/OrbitDockServer",
      projectName: "OrbitDock Server",
      branch: "mission-control",
      model: "claude-opus",
      summary: "Review the server startup path",
      firstPrompt: "Walk the startup flow and call out risky edge cases.",
      status: .ended,
      workStatus: .waiting,
      startedAt: now.addingTimeInterval(-86_400),
      totalTokens: 9_640,
      totalCostUSD: 0.12,
      lastActivityAt: now.addingTimeInterval(-79_200),
      promptCount: 4,
      toolCount: 2,
      attentionReason: .none,
      provider: .claude,
      claudeIntegrationMode: .passive
    )
    endedSession.repositoryRoot = "/Users/demo/OrbitDockServer"
    endedSession.lastMessage = "Wrapped up with a short findings list and two follow-up suggestions."

    let reviewObservable = sessionStore.session(reviewSession.id)
    reviewObservable.applySnapshotProjection(SessionDetailSnapshotProjection.from(reviewSession))
    reviewObservable.applyConversationPage(
      rows: demoConversationRows(sessionId: reviewSession.id, projectPath: reviewSession.projectPath),
      hasMoreBefore: false,
      oldestSequence: 1,
      isBootstrap: true
    )

    let endedObservable = sessionStore.session(endedSession.id)
    endedObservable.applySnapshotProjection(SessionDetailSnapshotProjection.from(endedSession))
    endedObservable.applyConversationPage(
      rows: endedConversationRows(sessionId: endedSession.id),
      hasMoreBefore: false,
      oldestSequence: 1,
      isBootstrap: true
    )

    sessionStore.codexModels = [
      ServerCodexModelOption(
        id: "gpt-5-codex",
        model: "gpt-5-codex",
        displayName: "GPT-5 Codex",
        description: "Strong default for coding tasks.",
        isDefault: true,
        supportedReasoningEfforts: ["low", "medium", "high"],
        supportsReasoningSummaries: true
      ),
    ]
    sessionStore.codexAccountStatus = ServerCodexAccountStatus(
      authMode: .chatgpt,
      requiresOpenaiAuth: false,
      account: .chatgpt(email: "demo@orbitdock.app", planType: "Review"),
      loginInProgress: false,
      activeLoginId: nil
    )
  }

  private static func demoSessionListItems() -> [ServerSessionListItem] {
    let now = Date()
    return [
      ServerSessionListItem(
        id: "demo-review-session",
        provider: .codex,
        projectPath: "/Users/demo/OrbitDock",
        projectName: "OrbitDock",
        gitBranch: "app-store-demo",
        model: "gpt-5-codex",
        status: .active,
        workStatus: .waiting,
        codexIntegrationMode: .direct,
        claudeIntegrationMode: nil,
        startedAt: iso8601Timestamp(now.addingTimeInterval(-4_200)),
        lastActivityAt: iso8601Timestamp(now.addingTimeInterval(-180)),
        unreadCount: 0,
        hasTurnDiff: true,
        pendingToolName: nil,
        repositoryRoot: "/Users/demo/OrbitDock",
        isWorktree: false,
        worktreeId: nil,
        totalTokens: 14_820,
        totalCostUSD: 0.19,
        displayTitle: "App Review Demo",
        displayTitleSortKey: "app review demo",
        displaySearchText: "app review demo orbitdock onboarding reviewer demo mode",
        contextLine: "Minimal seeded conversation for App Review",
        listStatus: .reply,
        effort: "medium",
        activeWorkerCount: 0
      ),
      ServerSessionListItem(
        id: "demo-ended-session",
        provider: .claude,
        projectPath: "/Users/demo/OrbitDockServer",
        projectName: "OrbitDock Server",
        gitBranch: "mission-control",
        model: "claude-opus",
        status: .ended,
        workStatus: .waiting,
        codexIntegrationMode: nil,
        claudeIntegrationMode: .passive,
        startedAt: iso8601Timestamp(now.addingTimeInterval(-86_400)),
        lastActivityAt: iso8601Timestamp(now.addingTimeInterval(-79_200)),
        unreadCount: 0,
        hasTurnDiff: false,
        pendingToolName: nil,
        repositoryRoot: "/Users/demo/OrbitDockServer",
        isWorktree: false,
        worktreeId: nil,
        totalTokens: 9_640,
        totalCostUSD: 0.12,
        displayTitle: "Startup Audit",
        displayTitleSortKey: "startup audit",
        displaySearchText: "startup audit orbitdock server",
        contextLine: "Completed example session",
        listStatus: .ended,
        effort: "low",
        activeWorkerCount: 0
      ),
    ]
  }

  private static func demoDashboardItems() -> [ServerDashboardConversationItem] {
    let now = Date()
    return [
      ServerDashboardConversationItem(
        sessionId: "demo-review-session",
        provider: .codex,
        projectPath: "/Users/demo/OrbitDock",
        projectName: "OrbitDock",
        repositoryRoot: "/Users/demo/OrbitDock",
        gitBranch: "app-store-demo",
        isWorktree: false,
        worktreeId: nil,
        model: "gpt-5-codex",
        codexIntegrationMode: .direct,
        claudeIntegrationMode: nil,
        status: .active,
        workStatus: .waiting,
        listStatus: .reply,
        displayTitle: "App Review Demo",
        contextLine: "Minimal seeded conversation for App Review",
        lastMessage: "I added a lightweight Explore Demo flow and seeded a sample session.",
        previewText: "I added a lightweight Explore Demo flow and seeded a sample session.",
        activitySummary: "I added a lightweight Explore Demo flow and seeded a sample session.",
        alertContext: "I added a lightweight Explore Demo flow and seeded a sample session.",
        startedAt: iso8601Timestamp(now.addingTimeInterval(-4_200)),
        lastActivityAt: iso8601Timestamp(now.addingTimeInterval(-180)),
        unreadCount: 0,
        hasTurnDiff: true,
        diffPreview: ServerDashboardDiffPreview(
          fileCount: 2,
          additions: 31,
          deletions: 4,
          filePaths: [
            "OrbitDockNative/OrbitDock/Views/Server/ServerSetupView.swift",
            "OrbitDockNative/OrbitDock/Services/DemoModeExperience.swift",
          ]
        ),
        pendingToolName: nil,
        pendingToolInput: nil,
        pendingQuestion: nil,
        toolCount: 4,
        activeWorkerCount: 0,
        issueIdentifier: nil,
        effort: "medium"
      ),
    ]
  }

  private static func demoConversationRows(
    sessionId: String,
    projectPath: String
  ) -> [ServerConversationRowEntry] {
    let now = Date()
    return [
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 1,
        turnId: "turn-1",
        row: .user(ServerConversationMessageRow(
          id: "demo-user-1",
          content: "Build a bare minimum demo mode so App Review can tap around the app without connecting to a server.",
          turnId: "turn-1",
          timestamp: iso8601Timestamp(now.addingTimeInterval(-600)),
          isStreaming: false,
          images: nil,
          memoryCitation: nil
        ))
      ),
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 2,
        turnId: "turn-1",
        row: .assistant(ServerConversationMessageRow(
          id: "demo-assistant-1",
          content: "I’ll add an Explore Demo path from setup, seed a sample dashboard session, and keep the experience clearly labeled as demo data.",
          turnId: "turn-1",
          timestamp: iso8601Timestamp(now.addingTimeInterval(-540)),
          isStreaming: false,
          images: nil,
          memoryCitation: nil
        ))
      ),
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 3,
        turnId: "turn-1",
        row: .shellCommand(ServerConversationShellCommandRow(
          id: "demo-shell-1",
          kind: .bash,
          title: "Inspect setup entry points",
          summary: "Looked for the smallest place to attach demo mode",
          command: "rg -n \"ServerSetupView|OrbitDockWindowRoot|AppStore\" OrbitDockNative/OrbitDock",
          args: [],
          stdout: "OrbitDockWindowRoot.swift\nServerSetupView.swift\nServices/AppStore.swift",
          stderr: nil,
          exitCode: 0,
          durationSeconds: 0.08,
          cwd: projectPath,
          renderHints: ServerConversationRenderHints(canExpand: true, defaultExpanded: false)
        ))
      ),
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 4,
        turnId: "turn-2",
        row: .assistant(ServerConversationMessageRow(
          id: "demo-assistant-2",
          content: "The demo flow is intentionally read-only. Reviewers can browse the dashboard, open a session, and see a realistic conversation without needing auth or backend setup.",
          turnId: "turn-2",
          timestamp: iso8601Timestamp(now.addingTimeInterval(-180)),
          isStreaming: false,
          images: nil,
          memoryCitation: nil
        ))
      ),
    ]
  }

  private static func endedConversationRows(sessionId: String) -> [ServerConversationRowEntry] {
    let now = Date()
    return [
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 1,
        turnId: "turn-1",
        row: .user(ServerConversationMessageRow(
          id: "demo-ended-user-1",
          content: "Walk the startup flow and call out risky edge cases.",
          turnId: "turn-1",
          timestamp: iso8601Timestamp(now.addingTimeInterval(-82_000)),
          isStreaming: false,
          images: nil,
          memoryCitation: nil
        ))
      ),
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 2,
        turnId: "turn-1",
        row: .assistant(ServerConversationMessageRow(
          id: "demo-ended-assistant-1",
          content: "I found two risky spots: readiness can race connection state, and reconnect behavior depends on a stale endpoint snapshot.",
          turnId: "turn-1",
          timestamp: iso8601Timestamp(now.addingTimeInterval(-81_600)),
          isStreaming: false,
          images: nil,
          memoryCitation: nil
        ))
      ),
    ]
  }

  private static func iso8601Timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

extension ServerDashboardDiffPreview {
  init(fileCount: UInt32, additions: UInt32, deletions: UInt32, filePaths: [String]) {
    self.fileCount = fileCount
    self.additions = additions
    self.deletions = deletions
    self.filePaths = filePaths
  }
}

extension ServerDashboardConversationItem {
  init(
    sessionId: String,
    provider: ServerProvider,
    projectPath: String,
    projectName: String?,
    repositoryRoot: String?,
    gitBranch: String?,
    isWorktree: Bool,
    worktreeId: String?,
    model: String?,
    codexIntegrationMode: ServerCodexIntegrationMode?,
    claudeIntegrationMode: ServerClaudeIntegrationMode?,
    status: ServerSessionStatus,
    workStatus: ServerWorkStatus,
    listStatus: ServerSessionListStatus,
    displayTitle: String,
    contextLine: String?,
    lastMessage: String?,
    previewText: String?,
    activitySummary: String?,
    alertContext: String?,
    startedAt: String?,
    lastActivityAt: String?,
    unreadCount: UInt64,
    hasTurnDiff: Bool,
    diffPreview: ServerDashboardDiffPreview?,
    pendingToolName: String?,
    pendingToolInput: String?,
    pendingQuestion: String?,
    toolCount: UInt64,
    activeWorkerCount: UInt32,
    issueIdentifier: String?,
    effort: String?
  ) {
    self.sessionId = sessionId
    self.provider = provider
    self.projectPath = projectPath
    self.projectName = projectName
    self.repositoryRoot = repositoryRoot
    self.gitBranch = gitBranch
    self.isWorktree = isWorktree
    self.worktreeId = worktreeId
    self.model = model
    self.codexIntegrationMode = codexIntegrationMode
    self.claudeIntegrationMode = claudeIntegrationMode
    self.status = status
    self.workStatus = workStatus
    self.listStatus = listStatus
    self.displayTitle = displayTitle
    self.contextLine = contextLine
    self.lastMessage = lastMessage
    self.previewText = previewText
    self.activitySummary = activitySummary
    self.alertContext = alertContext
    self.startedAt = startedAt
    self.lastActivityAt = lastActivityAt
    self.unreadCount = unreadCount
    self.hasTurnDiff = hasTurnDiff
    self.diffPreview = diffPreview
    self.pendingToolName = pendingToolName
    self.pendingToolInput = pendingToolInput
    self.pendingQuestion = pendingQuestion
    self.toolCount = toolCount
    self.activeWorkerCount = activeWorkerCount
    self.issueIdentifier = issueIdentifier
    self.effort = effort
  }
}
