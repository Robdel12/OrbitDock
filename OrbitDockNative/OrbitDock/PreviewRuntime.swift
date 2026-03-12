import Foundation
import SwiftUI

@MainActor
struct PreviewRuntime {
  enum Scenario {
    case dashboard
    case settings
    case serverSetup
    case newSession
  }

  let endpoints: [ServerEndpoint]
  let runtimeRegistry: ServerRuntimeRegistry
  let sessionStore: SessionStore
  let usageServiceRegistry: UsageServiceRegistry
  let attentionService: AttentionService
  let router: AppRouter
  let toastManager: ToastManager
  let rootSessionActions: RootSessionActions
  let notificationManager: NotificationManager
  let rootShellStore: RootShellStore
  let rootShellRuntime: RootShellRuntime
  let externalNavigationCenter: AppExternalNavigationCenter
  #if os(macOS)
    let serverManager: ServerManager
  #endif

  init(scenario: Scenario = .dashboard) {
    let endpoint = Self.previewEndpoint()
    self.endpoints = [endpoint]

    let clients = ServerClients(
      serverURL: ServerURLResolver.httpBaseURL(from: endpoint.wsURL),
      authToken: endpoint.authToken
    )
    let eventStream = EventStream(authToken: endpoint.authToken)
    let sessionStore = SessionStore(
      clients: clients,
      eventStream: eventStream,
      endpointId: endpoint.id,
      endpointName: endpoint.name
    )
    Self.previewSessions(endpoint: endpoint).forEach { session in
      sessionStore.session(session.id).applySnapshotProjection(SessionDetailSnapshotProjection.from(session))
    }
    sessionStore.codexModels = Self.previewCodexModels()
    sessionStore.claudeModels = Self.previewClaudeModels()
    sessionStore.codexAccountStatus = ServerCodexAccountStatus(
      authMode: .chatgpt,
      requiresOpenaiAuth: false,
      account: .chatgpt(email: "preview@orbitdock.dev", planType: "Plus"),
      loginInProgress: false,
      activeLoginId: nil
    )
    eventStream.seedSessionsListForTesting(Self.previewSessionListItems())
    self.sessionStore = sessionStore

    let runtime = ServerRuntime(
      endpoint: endpoint,
      clients: clients,
      eventStream: eventStream,
      sessionStore: sessionStore
    )

    let runtimeByEndpointID = [endpoint.id: runtime]
    let runtimeRegistry = ServerRuntimeRegistry(
      endpointsProvider: { [endpoint] },
      runtimeFactory: { requestedEndpoint in
        runtimeByEndpointID[requestedEndpoint.id] ?? ServerRuntime(endpoint: requestedEndpoint)
      },
      shouldBootstrapFromSettings: false
    )
    runtimeRegistry.configureFromSettings(startEnabled: false)
    self.runtimeRegistry = runtimeRegistry

    self.usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
    self.attentionService = AttentionService()
    self.router = AppRouter()
    self.toastManager = ToastManager()
    let rootShellStore = RootShellStore()
    self.rootShellStore = rootShellStore
    self.rootSessionActions = RootSessionActions(runtimeRegistry: runtimeRegistry)
    self.notificationManager = NotificationManager(
      isAuthorized: false,
      shouldRequestAuthorizationOnStart: false,
      notificationCenter: NotificationCenterClient(
        requestAuthorization: { completion in completion(false, nil) },
        setDelegate: { _ in },
        setNotificationCategories: { _ in },
        addRequest: { _, completion in completion(nil) },
        removeDeliveredNotifications: { _ in }
      ),
      preferences: NotificationPreferences(
        stringForKey: { _ in nil },
        objectForKey: { _ in nil },
        boolForKey: { _ in false }
      )
    )
    self.externalNavigationCenter = AppExternalNavigationCenter()
    self.rootShellRuntime = RootShellRuntime(
      runtimeRegistry: runtimeRegistry,
      rootShellStore: rootShellStore
    )
    self.rootShellRuntime.start()

    #if os(macOS)
      self.serverManager = ServerManager(
        previewInstallState: scenario == .serverSetup ? .notConfigured : .running
      )
    #endif
  }

  @ViewBuilder
  func inject<Content: View>(_ content: Content) -> some View {
    content
      .environment(sessionStore)
      .environment(runtimeRegistry)
      .environment(usageServiceRegistry)
      .environment(notificationManager)
      .environment(attentionService)
      .environment(router)
      .environment(toastManager)
      .environment(\.rootSessionActions, rootSessionActions)
      .environment(rootShellStore)
      #if os(macOS)
        .environment(\.serverManager, serverManager)
      #endif
  }

  private static func previewEndpoint() -> ServerEndpoint {
    ServerEndpoint(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      name: "Preview Server",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
  }

  private static func previewSessions(endpoint: ServerEndpoint) -> [Session] {
    [
      Session(
        id: "preview-claude-session",
        endpointId: endpoint.id,
        endpointName: endpoint.name,
        endpointConnectionStatus: .disconnected,
        projectPath: "/Users/preview/OrbitDock",
        projectName: "OrbitDock",
        branch: "client-refactor",
        model: "claude-opus",
        summary: "Refactor the client architecture",
        firstPrompt: "Split the preview runtime and keep the app clean.",
        status: .active,
        workStatus: .waiting,
        startedAt: Date().addingTimeInterval(-3_600),
        totalTokens: 12_400,
        promptCount: 8,
        toolCount: 5,
        attentionReason: .awaitingReply,
        provider: .claude
      ),
      Session(
        id: "preview-codex-session",
        endpointId: endpoint.id,
        endpointName: endpoint.name,
        endpointConnectionStatus: .disconnected,
        projectPath: "/Users/preview/OrbitDockServer",
        projectName: "OrbitDock Server",
        branch: "server-runtime",
        model: "gpt-5-codex",
        summary: "Audit runtime startup",
        firstPrompt: "Check the new readiness gates and simplify startup.",
        status: .active,
        workStatus: .working,
        startedAt: Date().addingTimeInterval(-1_800),
        totalTokens: 8_900,
        promptCount: 5,
        toolCount: 12,
        attentionReason: .none,
        provider: .codex,
        codexIntegrationMode: .direct
      ),
    ]
  }

  private static func previewClaudeModels() -> [ServerClaudeModelOption] {
    [
      ServerClaudeModelOption(
        value: "claude-opus",
        displayName: "Claude Opus",
        description: "Best for deep design and architecture work."
      ),
      ServerClaudeModelOption(
        value: "claude-sonnet",
        displayName: "Claude Sonnet",
        description: "Balanced speed and reasoning for general work."
      ),
    ]
  }

  private static func previewCodexModels() -> [ServerCodexModelOption] {
    [
      ServerCodexModelOption(
        id: "gpt-5-codex",
        model: "gpt-5-codex",
        displayName: "GPT-5 Codex",
        description: "Strong default for coding tasks.",
        isDefault: true,
        supportedReasoningEfforts: ["low", "medium", "high"],
        supportsReasoningSummaries: true
      ),
      ServerCodexModelOption(
        id: "gpt-5-codex-fast",
        model: "gpt-5-codex-fast",
        displayName: "GPT-5 Codex Fast",
        description: "Lower latency for shorter iterations.",
        isDefault: false,
        supportedReasoningEfforts: ["low", "medium"],
        supportsReasoningSummaries: true
      ),
    ]
  }

  private static func previewSessionListItems() -> [ServerSessionListItem] {
    previewSessions(endpoint: previewEndpoint()).map {
      ServerSessionListItem(
        id: $0.id,
        provider: $0.provider == .codex ? .codex : .claude,
        projectPath: $0.projectPath,
        projectName: $0.projectName,
        gitBranch: $0.branch,
        model: $0.model,
        status: $0.status == .active ? .active : .ended,
        workStatus: serverWorkStatus(for: $0.workStatus, attentionReason: $0.attentionReason),
        codexIntegrationMode: $0.codexIntegrationMode.map(serverCodexMode),
        claudeIntegrationMode: $0.claudeIntegrationMode.map(serverClaudeMode),
        startedAt: $0.startedAt.map(Self.iso8601Timestamp),
        lastActivityAt: $0.lastActivityAt.map(Self.iso8601Timestamp),
        unreadCount: $0.unreadCount,
        hasTurnDiff: false,
        pendingToolName: $0.pendingToolName,
        repositoryRoot: $0.repositoryRoot,
        isWorktree: $0.isWorktree,
        worktreeId: $0.worktreeId,
        totalTokens: UInt64(max($0.totalTokens, 0)),
        totalCostUSD: $0.totalCostUSD,
        displayTitle: $0.displayName,
        displayTitleSortKey: $0.normalizedDisplayName,
        displaySearchText: $0.displaySearchText,
        contextLine: $0.summary ?? $0.firstPrompt,
        listStatus: nil,
        effort: $0.effort
      )
    }
  }

  private static func serverWorkStatus(
    for workStatus: Session.WorkStatus,
    attentionReason: Session.AttentionReason
  ) -> ServerWorkStatus {
    switch attentionReason {
      case .awaitingPermission:
        return .permission
      case .awaitingQuestion:
        return .question
      case .awaitingReply:
        return .reply
      case .none:
        return workStatus == .working ? .working : .reply
    }
  }

  private static func serverCodexMode(_ mode: CodexIntegrationMode) -> ServerCodexIntegrationMode {
    switch mode {
      case .direct: .direct
      case .passive: .passive
    }
  }

  private static func serverClaudeMode(_ mode: ClaudeIntegrationMode) -> ServerClaudeIntegrationMode {
    switch mode {
      case .direct: .direct
      case .passive: .passive
    }
  }

  private static func iso8601Timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
