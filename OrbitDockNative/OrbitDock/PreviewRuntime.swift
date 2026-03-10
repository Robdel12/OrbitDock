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
  let notificationManager: NotificationManager
  let windowSessionCoordinator: WindowSessionCoordinator
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
    sessionStore.sessions = Self.previewSessions(endpoint: endpoint)
    sessionStore.codexModels = Self.previewCodexModels()
    sessionStore.claudeModels = Self.previewClaudeModels()
    sessionStore.codexAccountStatus = ServerCodexAccountStatus(
      authMode: .chatgpt,
      requiresOpenaiAuth: false,
      account: .chatgpt(email: "preview@orbitdock.dev", planType: "Plus"),
      loginInProgress: false,
      activeLoginId: nil
    )
    sessionStore.setHasReceivedInitialSessionsList(true)
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
    self.notificationManager = NotificationManager(
      isAuthorized: false,
      requestsAuthorizationOnInit: false
    )
    self.externalNavigationCenter = AppExternalNavigationCenter()
    self.windowSessionCoordinator = WindowSessionCoordinator(
      runtimeRegistry: runtimeRegistry,
      attentionService: attentionService,
      notificationManager: notificationManager,
      toastManager: toastManager,
      router: router
    )
    self.windowSessionCoordinator.start(currentScopedId: nil)

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
      .environment(attentionService)
      .environment(router)
      .environment(windowSessionCoordinator)
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
}
