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
        connectionStatus: .connected
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

  // MARK: - Endpoint & Store

  private static func demoEndpoint() -> ServerEndpoint {
    ServerEndpoint(
      id: UUID(uuidString: "99999999-2222-3333-4444-555555555555")!,
      name: "Mission Control",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
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

  // MARK: - Session Details (for detail view)

  private static func populateSessionDetails(sessionStore: SessionStore, endpoint: ServerEndpoint) {
    let now = Date()

    // Session 1: Warp Drive — Claude working on a feature
    var warpDrive = Session(
      id: "demo-warp-drive",
      endpointId: endpoint.id,
      endpointName: endpoint.name,
      endpointConnectionStatus: .connected,
      projectPath: "/Users/pilot/nebula-api",
      projectName: "nebula-api",
      branch: "feat/warp-drive",
      model: "claude-opus-4-6",
      summary: "Implement FTL route calculation engine",
      firstPrompt: "Build a route calculation module that finds the fastest path between star systems using the jump gate network.",
      status: .active,
      workStatus: .working,
      startedAt: now.addingTimeInterval(-1_800),
      totalTokens: 42_600,
      totalCostUSD: 1.28,
      lastActivityAt: now.addingTimeInterval(-12),
      promptCount: 8,
      toolCount: 14,
      attentionReason: .none,
      provider: .claude,
      claudeIntegrationMode: .direct
    )
    warpDrive.controlMode = .direct
    warpDrive.lifecycleState = .open
    warpDrive.acceptsUserInput = true
    warpDrive.steerable = true
    warpDrive.repositoryRoot = "/Users/pilot/nebula-api"
    warpDrive.lastMessage = "I've implemented the Dijkstra-based pathfinder with jump gate weights. Now optimizing for fuel consumption constraints."
    warpDrive.currentDiff = """
    diff --git a/src/routes/pathfinder.rs b/src/routes/pathfinder.rs
    +pub fn calculate_route(origin: &StarSystem, dest: &StarSystem, gates: &JumpGateNetwork) -> Route {
    +    let mut frontier = BinaryHeap::new();
    +    frontier.push(RouteNode { system: origin.clone(), cost: 0.0, fuel: origin.fuel_capacity });
    """
    warpDrive.cumulativeDiff = """
    diff --git a/src/routes/mod.rs b/src/routes/mod.rs
    +pub mod pathfinder;
    +pub mod fuel;
    diff --git a/src/routes/pathfinder.rs b/src/routes/pathfinder.rs
    +pub fn calculate_route(origin: &StarSystem, dest: &StarSystem, gates: &JumpGateNetwork) -> Route {
    diff --git a/src/routes/fuel.rs b/src/routes/fuel.rs
    +pub fn estimate_fuel(route: &Route, ship: &ShipClass) -> FuelEstimate {
    """

    // Session 2: Navigation Array — Codex waiting for permission
    var navArray = Session(
      id: "demo-nav-array",
      endpointId: endpoint.id,
      endpointName: endpoint.name,
      endpointConnectionStatus: .connected,
      projectPath: "/Users/pilot/nebula-api",
      projectName: "nebula-api",
      branch: "fix/nav-drift",
      model: "o3-pro",
      summary: "Fix coordinate drift in long-range navigation",
      firstPrompt: "The navigation array drifts by ~0.003 AU after 72h. Find the accumulation error and fix it.",
      status: .active,
      workStatus: .permission,
      startedAt: now.addingTimeInterval(-3_600),
      totalTokens: 28_400,
      totalCostUSD: 0.86,
      lastActivityAt: now.addingTimeInterval(-45),
      promptCount: 5,
      toolCount: 9,
      attentionReason: .awaitingPermission,
      pendingToolName: "Edit",
      pendingToolInput: "{\"file_path\":\"src/nav/coordinate_transform.rs\",\"old_string\":\"let drift = accumulated * 0.99997\",\"new_string\":\"let drift = accumulated * CORRECTION_FACTOR\"}",
      provider: .codex,
      codexIntegrationMode: .direct
    )
    navArray.controlMode = .direct
    navArray.lifecycleState = .open
    navArray.acceptsUserInput = true
    navArray.steerable = true
    navArray.repositoryRoot = "/Users/pilot/nebula-api"
    navArray.lastMessage = "Found the drift source — a hardcoded correction factor that compounds over time. I'd like to replace it with a configurable constant."

    // Session 3: Shield Harmonics — Claude awaiting reply
    var shields = Session(
      id: "demo-shields",
      endpointId: endpoint.id,
      endpointName: endpoint.name,
      endpointConnectionStatus: .connected,
      projectPath: "/Users/pilot/orbital-ui",
      projectName: "orbital-ui",
      branch: "feat/shield-viz",
      model: "claude-sonnet-4-6",
      summary: "Add real-time shield integrity visualization",
      firstPrompt: "Build a SwiftUI view that shows shield integrity as an animated ring with sector-level damage indicators.",
      status: .active,
      workStatus: .waiting,
      startedAt: now.addingTimeInterval(-7_200),
      totalTokens: 18_950,
      totalCostUSD: 0.34,
      lastActivityAt: now.addingTimeInterval(-300),
      promptCount: 4,
      toolCount: 6,
      attentionReason: .awaitingReply,
      provider: .claude,
      claudeIntegrationMode: .direct
    )
    shields.controlMode = .direct
    shields.lifecycleState = .open
    shields.acceptsUserInput = true
    shields.steerable = true
    shields.repositoryRoot = "/Users/pilot/orbital-ui"
    shields.lastMessage = "The shield ring view is rendering with sector segments. Each sector pulses red when integrity drops below 40%. Want me to add haptic feedback on critical hits?"
    shields.currentDiff = """
    diff --git a/Sources/Views/ShieldRingView.swift b/Sources/Views/ShieldRingView.swift
    +struct ShieldRingView: View {
    +    let sectors: [ShieldSector]
    +    @State private var pulsePhase: CGFloat = 0
    """

    // Session 4: Docking Bay — ended session
    var dockingBay = Session(
      id: "demo-docking-bay",
      endpointId: endpoint.id,
      endpointName: endpoint.name,
      endpointConnectionStatus: .connected,
      projectPath: "/Users/pilot/nebula-api",
      projectName: "nebula-api",
      branch: "chore/bay-cleanup",
      model: "gpt-5-mini",
      summary: "Clean up deprecated docking bay allocation logic",
      firstPrompt: "Remove the legacy bay allocation system and migrate callers to the new slot-based API.",
      status: .ended,
      workStatus: .ended,
      startedAt: now.addingTimeInterval(-14_400),
      totalTokens: 31_200,
      totalCostUSD: 0.47,
      lastActivityAt: now.addingTimeInterval(-10_800),
      promptCount: 6,
      toolCount: 11,
      attentionReason: .none,
      provider: .codex,
      codexIntegrationMode: .direct
    )
    dockingBay.controlMode = .direct
    dockingBay.lifecycleState = .ended
    dockingBay.acceptsUserInput = false
    dockingBay.repositoryRoot = "/Users/pilot/nebula-api"
    dockingBay.lastMessage = "All done. Removed 847 lines of legacy code, migrated 12 callers, and tests pass."

    // Session 5: Comms Array — Qwen via OpenRouter, question status
    var commsArray = Session(
      id: "demo-comms-array",
      endpointId: endpoint.id,
      endpointName: endpoint.name,
      endpointConnectionStatus: .connected,
      projectPath: "/Users/pilot/orbital-ui",
      projectName: "orbital-ui",
      branch: "feat/comms-panel",
      model: "qwen3-coder",
      summary: "Build inter-ship communication panel",
      firstPrompt: "Create a real-time comms panel that shows incoming transmissions grouped by frequency band.",
      status: .active,
      workStatus: .question,
      startedAt: now.addingTimeInterval(-5_400),
      totalTokens: 15_700,
      totalCostUSD: 0.22,
      lastActivityAt: now.addingTimeInterval(-120),
      promptCount: 3,
      toolCount: 5,
      attentionReason: .awaitingQuestion,
      pendingQuestion: "Should encrypted transmissions show a lock icon inline, or should I group them in a separate \"Secure Channel\" section?",
      provider: .codex,
      codexIntegrationMode: .direct
    )
    commsArray.controlMode = .direct
    commsArray.lifecycleState = .open
    commsArray.acceptsUserInput = true
    commsArray.steerable = true
    commsArray.repositoryRoot = "/Users/pilot/orbital-ui"
    commsArray.lastMessage = "Should encrypted transmissions show a lock icon inline, or should I group them in a separate \"Secure Channel\" section?"

    // Populate each session into the store
    let sessions: [Session] = [warpDrive, navArray, shields, dockingBay, commsArray]
    let conversationGenerators: [String: (String) -> [ServerConversationRowEntry]] = [
      "demo-warp-drive": { id in warpDriveConversation(sessionId: id) },
      "demo-nav-array": { id in navArrayConversation(sessionId: id) },
      "demo-shields": { id in shieldsConversation(sessionId: id) },
      "demo-docking-bay": { id in dockingBayConversation(sessionId: id) },
      "demo-comms-array": { id in commsArrayConversation(sessionId: id) },
    ]

    // Demo sessions are seeded through the dashboard snapshot

    sessionStore.codexModels = [
      ServerCodexModelOption(
        id: "o3-pro",
        model: "o3-pro",
        displayName: "o3 Pro",
        description: "Best for complex reasoning tasks.",
        isDefault: false,
        supportedReasoningEfforts: ["low", "medium", "high"],
        supportsReasoningSummaries: true
      ),
      ServerCodexModelOption(
        id: "gpt-5-mini",
        model: "gpt-5-mini",
        displayName: "GPT-5 Mini",
        description: "Fast and cost-effective.",
        isDefault: true,
        supportedReasoningEfforts: ["low", "medium", "high"],
        supportsReasoningSummaries: true
      ),
      ServerCodexModelOption(
        id: "qwen3-coder",
        model: "qwen3-coder",
        displayName: "Qwen3 Coder (OpenRouter)",
        description: "Via OpenRouter — strong at code generation.",
        isDefault: false,
        supportedReasoningEfforts: ["low", "medium", "high"],
        supportsReasoningSummaries: false
      ),
    ]
    sessionStore.codexAccountStatus = ServerCodexAccountStatus(
      authMode: .chatgpt,
      requiresOpenaiAuth: false,
      account: .chatgpt(email: "pilot@orbitdock.app", planType: "Pro"),
      loginInProgress: false,
      activeLoginId: nil
    )
  }

  // MARK: - Session List Items

  private static func demoSessionListItems() -> [ServerSessionListItem] {
    let now = Date()
    return [
      // Warp Drive — Claude, working
      ServerSessionListItem(
        id: "demo-warp-drive",
        provider: .claude,
        projectPath: "/Users/pilot/nebula-api",
        projectName: "nebula-api",
        gitBranch: "feat/warp-drive",
        model: "claude-opus-4-6",
        status: .active,
        workStatus: .working,
        controlMode: .direct,
        lifecycleState: .open,
        steerable: false,
        codexIntegrationMode: nil,
        claudeIntegrationMode: .direct,
        startedAt: iso8601(now.addingTimeInterval(-1_800)),
        lastActivityAt: iso8601(now.addingTimeInterval(-12)),
        unreadCount: 2,
        hasTurnDiff: true,
        pendingToolName: "Edit",
        repositoryRoot: "/Users/pilot/nebula-api",
        isWorktree: false,
        worktreeId: nil,
        totalTokens: 42_600,
        totalCostUSD: 1.28,
        inputTokens: 21_300,
        outputTokens: 21_300,
        cachedTokens: 0,
        displayTitle: "Warp Drive",
        displayTitleSortKey: "warp drive",
        displaySearchText: "warp drive ftl route pathfinder nebula-api",
        contextLine: "Implementing FTL route calculation engine",
        listStatus: .working,
        summaryRevision: 0,
        effort: "high",
        activeWorkerCount: 0,
        pendingToolFamily: nil,
        forkedFromSessionId: nil,
        missionId: nil,
        issueIdentifier: nil
      ),
      // Navigation Array — Codex, permission
      ServerSessionListItem(
        id: "demo-nav-array",
        provider: .codex,
        projectPath: "/Users/pilot/nebula-api",
        projectName: "nebula-api",
        gitBranch: "fix/nav-drift",
        model: "o3-pro",
        status: .active,
        workStatus: .permission,
        controlMode: .direct,
        lifecycleState: .open,
        steerable: false,
        codexIntegrationMode: .direct,
        claudeIntegrationMode: nil,
        startedAt: iso8601(now.addingTimeInterval(-3_600)),
        lastActivityAt: iso8601(now.addingTimeInterval(-45)),
        unreadCount: 1,
        hasTurnDiff: true,
        pendingToolName: "Edit",
        repositoryRoot: "/Users/pilot/nebula-api",
        isWorktree: false,
        worktreeId: nil,
        totalTokens: 28_400,
        totalCostUSD: 0.86,
        inputTokens: 14_200,
        outputTokens: 14_200,
        cachedTokens: 0,
        displayTitle: "Navigation Array",
        displayTitleSortKey: "navigation array",
        displaySearchText: "navigation array drift coordinate fix nebula-api",
        contextLine: "Wants to edit coordinate_transform.rs",
        listStatus: .permission,
        summaryRevision: 0,
        effort: "high",
        activeWorkerCount: 0,
        pendingToolFamily: "file_change",
        forkedFromSessionId: nil,
        missionId: nil,
        issueIdentifier: nil
      ),
      // Shield Harmonics — Claude, reply
      ServerSessionListItem(
        id: "demo-shields",
        provider: .claude,
        projectPath: "/Users/pilot/orbital-ui",
        projectName: "orbital-ui",
        gitBranch: "feat/shield-viz",
        model: "claude-sonnet-4-6",
        status: .active,
        workStatus: .waiting,
        controlMode: .direct,
        lifecycleState: .open,
        steerable: false,
        codexIntegrationMode: nil,
        claudeIntegrationMode: .direct,
        startedAt: iso8601(now.addingTimeInterval(-7_200)),
        lastActivityAt: iso8601(now.addingTimeInterval(-300)),
        unreadCount: 0,
        hasTurnDiff: true,
        pendingToolName: nil,
        repositoryRoot: "/Users/pilot/orbital-ui",
        isWorktree: false,
        worktreeId: nil,
        totalTokens: 18_950,
        totalCostUSD: 0.34,
        inputTokens: 9_475,
        outputTokens: 9_475,
        cachedTokens: 0,
        displayTitle: "Shield Harmonics",
        displayTitleSortKey: "shield harmonics",
        displaySearchText: "shield harmonics integrity ring visualization orbital-ui",
        contextLine: "Want me to add haptic feedback on critical hits?",
        listStatus: .reply,
        summaryRevision: 0,
        effort: "medium",
        activeWorkerCount: 0,
        pendingToolFamily: nil,
        forkedFromSessionId: nil,
        missionId: nil,
        issueIdentifier: nil
      ),
      // Docking Bay Cleanup — Codex, ended
      ServerSessionListItem(
        id: "demo-docking-bay",
        provider: .codex,
        projectPath: "/Users/pilot/nebula-api",
        projectName: "nebula-api",
        gitBranch: "chore/bay-cleanup",
        model: "gpt-5-mini",
        status: .ended,
        workStatus: .ended,
        controlMode: .direct,
        lifecycleState: .ended,
        steerable: false,
        codexIntegrationMode: .direct,
        claudeIntegrationMode: nil,
        startedAt: iso8601(now.addingTimeInterval(-14_400)),
        lastActivityAt: iso8601(now.addingTimeInterval(-10_800)),
        unreadCount: 0,
        hasTurnDiff: false,
        pendingToolName: nil,
        repositoryRoot: "/Users/pilot/nebula-api",
        isWorktree: false,
        worktreeId: nil,
        totalTokens: 31_200,
        totalCostUSD: 0.47,
        inputTokens: 15_600,
        outputTokens: 15_600,
        cachedTokens: 0,
        displayTitle: "Docking Bay Cleanup",
        displayTitleSortKey: "docking bay cleanup",
        displaySearchText: "docking bay cleanup legacy migration nebula-api",
        contextLine: "Removed 847 lines, migrated 12 callers",
        listStatus: .ended,
        summaryRevision: 0,
        effort: "medium",
        activeWorkerCount: 0,
        pendingToolFamily: nil,
        forkedFromSessionId: nil,
        missionId: nil,
        issueIdentifier: nil
      ),
      // Comms Array — Qwen via OpenRouter, question
      ServerSessionListItem(
        id: "demo-comms-array",
        provider: .codex,
        projectPath: "/Users/pilot/orbital-ui",
        projectName: "orbital-ui",
        gitBranch: "feat/comms-panel",
        model: "qwen3-coder",
        status: .active,
        workStatus: .question,
        controlMode: .direct,
        lifecycleState: .open,
        steerable: false,
        codexIntegrationMode: .direct,
        claudeIntegrationMode: nil,
        startedAt: iso8601(now.addingTimeInterval(-5_400)),
        lastActivityAt: iso8601(now.addingTimeInterval(-120)),
        unreadCount: 1,
        hasTurnDiff: false,
        pendingToolName: nil,
        repositoryRoot: "/Users/pilot/orbital-ui",
        isWorktree: false,
        worktreeId: nil,
        totalTokens: 15_700,
        totalCostUSD: 0.22,
        inputTokens: 7_850,
        outputTokens: 7_850,
        cachedTokens: 0,
        displayTitle: "Comms Array",
        displayTitleSortKey: "comms array",
        displaySearchText: "comms array transmission panel orbital-ui openrouter qwen",
        contextLine: "Encrypted transmissions — inline lock or separate section?",
        listStatus: .question,
        summaryRevision: 0,
        effort: "medium",
        activeWorkerCount: 0,
        pendingToolFamily: nil,
        forkedFromSessionId: nil,
        missionId: nil,
        issueIdentifier: nil
      ),
    ]
  }

  // MARK: - Dashboard Items

  private static func demoDashboardItems() -> [ServerDashboardConversationItem] {
    let now = Date()
    return [
      // Warp Drive — working
      ServerDashboardConversationItem(
        sessionId: "demo-warp-drive",
        provider: .claude,
        projectPath: "/Users/pilot/nebula-api",
        groupingPath: "/Users/pilot/nebula-api",
        groupingName: "nebula-api",
        projectName: "nebula-api",
        repositoryRoot: "/Users/pilot/nebula-api",
        gitBranch: "feat/warp-drive",
        isWorktree: false,
        worktreeId: nil,
        model: "claude-opus-4-6",
        codexIntegrationMode: nil,
        claudeIntegrationMode: .direct,
        status: .active,
        workStatus: .working,
        controlMode: .direct,
        lifecycleState: .open,
        listStatus: .working,
        displayTitle: "Warp Drive",
        contextLine: "Implementing FTL route calculation engine",
        lastMessage: "Optimizing the pathfinder for fuel consumption constraints. Adding jump gate weight calculations now.",
        previewText: "Optimizing the pathfinder for fuel consumption constraints.",
        activitySummary: "Running Edit on pathfinder.rs",
        alertContext: "Optimizing the pathfinder for fuel consumption constraints.",
        startedAt: iso8601(now.addingTimeInterval(-1_800)),
        lastActivityAt: iso8601(now.addingTimeInterval(-12)),
        unreadCount: 2,
        hasTurnDiff: true,
        diffPreview: ServerDashboardDiffPreview(
          fileCount: 3,
          additions: 142,
          deletions: 8,
          filePaths: [
            "src/routes/pathfinder.rs",
            "src/routes/fuel.rs",
            "src/routes/mod.rs",
          ]
        ),
        pendingToolName: "Edit",
        pendingToolInput: nil,
        pendingQuestion: nil,
        toolCount: 14,
        activeWorkerCount: 0,
        issueIdentifier: nil,
        effort: "high"
      ),
      // Navigation Array — permission
      ServerDashboardConversationItem(
        sessionId: "demo-nav-array",
        provider: .codex,
        projectPath: "/Users/pilot/nebula-api",
        groupingPath: "/Users/pilot/nebula-api",
        groupingName: "nebula-api",
        projectName: "nebula-api",
        repositoryRoot: "/Users/pilot/nebula-api",
        gitBranch: "fix/nav-drift",
        isWorktree: false,
        worktreeId: nil,
        model: "o3-pro",
        codexIntegrationMode: .direct,
        claudeIntegrationMode: nil,
        status: .active,
        workStatus: .permission,
        controlMode: .direct,
        lifecycleState: .open,
        listStatus: .permission,
        displayTitle: "Navigation Array",
        contextLine: "Wants to edit coordinate_transform.rs",
        lastMessage: "Found the drift source — a hardcoded correction factor that compounds over time.",
        previewText: "Found the drift source — a hardcoded correction factor.",
        activitySummary: "Wants to edit coordinate_transform.rs",
        alertContext: "Edit coordinate_transform.rs",
        startedAt: iso8601(now.addingTimeInterval(-3_600)),
        lastActivityAt: iso8601(now.addingTimeInterval(-45)),
        unreadCount: 1,
        hasTurnDiff: true,
        diffPreview: ServerDashboardDiffPreview(
          fileCount: 2,
          additions: 24,
          deletions: 3,
          filePaths: [
            "src/nav/coordinate_transform.rs",
            "src/nav/constants.rs",
          ]
        ),
        pendingToolName: "Edit",
        pendingToolInput: "{\"file_path\":\"src/nav/coordinate_transform.rs\"}",
        pendingQuestion: nil,
        toolCount: 9,
        activeWorkerCount: 0,
        issueIdentifier: nil,
        effort: "high"
      ),
      // Shield Harmonics — reply
      ServerDashboardConversationItem(
        sessionId: "demo-shields",
        provider: .claude,
        projectPath: "/Users/pilot/orbital-ui",
        groupingPath: "/Users/pilot/orbital-ui",
        groupingName: "orbital-ui",
        projectName: "orbital-ui",
        repositoryRoot: "/Users/pilot/orbital-ui",
        gitBranch: "feat/shield-viz",
        isWorktree: false,
        worktreeId: nil,
        model: "claude-sonnet-4-6",
        codexIntegrationMode: nil,
        claudeIntegrationMode: .direct,
        status: .active,
        workStatus: .waiting,
        controlMode: .direct,
        lifecycleState: .open,
        listStatus: .reply,
        displayTitle: "Shield Harmonics",
        contextLine: "Want me to add haptic feedback on critical hits?",
        lastMessage: "The shield ring view is rendering with sector segments. Want me to add haptic feedback on critical hits?",
        previewText: "Shield ring rendering with sector-level damage indicators.",
        activitySummary: "Shield ring rendering with sector-level damage indicators.",
        alertContext: "Want me to add haptic feedback on critical hits?",
        startedAt: iso8601(now.addingTimeInterval(-7_200)),
        lastActivityAt: iso8601(now.addingTimeInterval(-300)),
        unreadCount: 0,
        hasTurnDiff: true,
        diffPreview: ServerDashboardDiffPreview(
          fileCount: 2,
          additions: 87,
          deletions: 0,
          filePaths: [
            "Sources/Views/ShieldRingView.swift",
            "Sources/Models/ShieldSector.swift",
          ]
        ),
        pendingToolName: nil,
        pendingToolInput: nil,
        pendingQuestion: nil,
        toolCount: 6,
        activeWorkerCount: 0,
        issueIdentifier: nil,
        effort: "medium"
      ),
      // Comms Array — question
      ServerDashboardConversationItem(
        sessionId: "demo-comms-array",
        provider: .codex,
        projectPath: "/Users/pilot/orbital-ui",
        groupingPath: "/Users/pilot/orbital-ui",
        groupingName: "orbital-ui",
        projectName: "orbital-ui",
        repositoryRoot: "/Users/pilot/orbital-ui",
        gitBranch: "feat/comms-panel",
        isWorktree: false,
        worktreeId: nil,
        model: "qwen3-coder",
        codexIntegrationMode: .direct,
        claudeIntegrationMode: nil,
        status: .active,
        workStatus: .question,
        controlMode: .direct,
        lifecycleState: .open,
        listStatus: .question,
        displayTitle: "Comms Array",
        contextLine: "Encrypted transmissions — inline lock or separate section?",
        lastMessage: "Should encrypted transmissions show a lock icon inline, or should I group them in a separate \"Secure Channel\" section?",
        previewText: "Encrypted transmissions — inline lock or separate section?",
        activitySummary: "Waiting for design decision on encrypted transmissions.",
        alertContext: "Should encrypted transmissions show a lock icon inline, or should I group them in a separate \"Secure Channel\" section?",
        startedAt: iso8601(now.addingTimeInterval(-5_400)),
        lastActivityAt: iso8601(now.addingTimeInterval(-120)),
        unreadCount: 1,
        hasTurnDiff: false,
        diffPreview: nil,
        pendingToolName: nil,
        pendingToolInput: nil,
        pendingQuestion: "Should encrypted transmissions show a lock icon inline, or should I group them in a separate \"Secure Channel\" section?",
        toolCount: 5,
        activeWorkerCount: 0,
        issueIdentifier: nil,
        effort: "medium"
      ),
    ]
  }

  // MARK: - Conversations

  private static func warpDriveConversation(sessionId: String) -> [ServerConversationRowEntry] {
    let now = Date()
    return [
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 1,
        turnId: "turn-1",
        row: .user(ServerConversationMessageRow(
          id: "wd-user-1",
          content: "Build a route calculation module that finds the fastest path between star systems using the jump gate network. The gate graph is in `src/models/gate_network.rs`.",
          turnId: "turn-1",
          timestamp: iso8601(now.addingTimeInterval(-1_800)),
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
          id: "wd-asst-1",
          content: "I'll build a pathfinder using Dijkstra's algorithm weighted by jump gate traversal costs. Let me start by reading the gate network model to understand the graph structure.",
          turnId: "turn-1",
          timestamp: iso8601(now.addingTimeInterval(-1_780)),
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
          id: "wd-shell-1",
          kind: .bash,
          title: "Read gate network model",
          summary: "Inspected the JumpGateNetwork struct and its graph representation",
          command: "cat src/models/gate_network.rs",
          args: [],
          stdout: "pub struct JumpGate {\n    pub origin: StarSystemId,\n    pub destination: StarSystemId,\n    pub traversal_cost: f64,\n    pub fuel_required: f64,\n    pub cooldown_seconds: u32,\n}\n\npub struct JumpGateNetwork {\n    pub gates: Vec<JumpGate>,\n    pub systems: HashMap<StarSystemId, StarSystem>,\n}",
          stderr: nil,
          exitCode: 0,
          durationSeconds: 0.02,
          cwd: "/Users/pilot/nebula-api",
          renderHints: ServerConversationRenderHints(canExpand: true, defaultExpanded: false)
        ))
      ),
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 4,
        turnId: "turn-2",
        row: .user(ServerConversationMessageRow(
          id: "wd-user-2",
          content: "Make sure to account for fuel capacity — some routes are cheaper but the ship might not have enough fuel to make a long jump.",
          turnId: "turn-2",
          timestamp: iso8601(now.addingTimeInterval(-900)),
          isStreaming: false,
          images: nil,
          memoryCitation: nil
        ))
      ),
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 5,
        turnId: "turn-2",
        row: .assistant(ServerConversationMessageRow(
          id: "wd-asst-2",
          content: "Good call. I've implemented the Dijkstra-based pathfinder with jump gate weights. Now optimizing for fuel consumption constraints — the frontier tracks remaining fuel so we prune paths where the ship would run dry mid-jump.",
          turnId: "turn-2",
          timestamp: iso8601(now.addingTimeInterval(-12)),
          isStreaming: false,
          images: nil,
          memoryCitation: nil
        ))
      ),
    ]
  }

  private static func navArrayConversation(sessionId: String) -> [ServerConversationRowEntry] {
    let now = Date()
    return [
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 1,
        turnId: "turn-1",
        row: .user(ServerConversationMessageRow(
          id: "nav-user-1",
          content: "The navigation array drifts by ~0.003 AU after 72h of continuous operation. Find the accumulation error and fix it.",
          turnId: "turn-1",
          timestamp: iso8601(now.addingTimeInterval(-3_600)),
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
          id: "nav-asst-1",
          content: "I'll trace the coordinate transform pipeline to find where the drift accumulates. Let me check the transform chain.",
          turnId: "turn-1",
          timestamp: iso8601(now.addingTimeInterval(-3_560)),
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
          id: "nav-shell-1",
          kind: .bash,
          title: "Search for correction factors",
          summary: "Found a hardcoded 0.99997 multiplier applied every tick",
          command: "rg \"correction\\|drift\\|accumulated\" src/nav/",
          args: [],
          stdout: "src/nav/coordinate_transform.rs:47:    let drift = accumulated * 0.99997; // \"close enough\"\nsrc/nav/coordinate_transform.rs:48:    // TODO: this was supposed to be temporary\nsrc/nav/constants.rs:12:pub const TICK_RATE: f64 = 60.0;",
          stderr: nil,
          exitCode: 0,
          durationSeconds: 0.04,
          cwd: "/Users/pilot/nebula-api",
          renderHints: ServerConversationRenderHints(canExpand: true, defaultExpanded: true)
        ))
      ),
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 4,
        turnId: "turn-1",
        row: .assistant(ServerConversationMessageRow(
          id: "nav-asst-2",
          content: "Found it. Line 47 in `coordinate_transform.rs` has a hardcoded `0.99997` multiplier applied every tick. At 60 ticks/sec, that's `0.99997^(60*60*72)` = massive drift after 72 hours. The comment says \"close enough\" and there's a TODO saying it was supposed to be temporary.\n\nI'd like to replace the magic number with a configurable constant and fix the math to use proper frame-independent damping.",
          turnId: "turn-1",
          timestamp: iso8601(now.addingTimeInterval(-45)),
          isStreaming: false,
          images: nil,
          memoryCitation: nil
        ))
      ),
    ]
  }

  private static func shieldsConversation(sessionId: String) -> [ServerConversationRowEntry] {
    let now = Date()
    return [
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 1,
        turnId: "turn-1",
        row: .user(ServerConversationMessageRow(
          id: "sh-user-1",
          content: "Build a SwiftUI view that shows shield integrity as an animated ring with sector-level damage indicators. Think of it like a ship's shield display from a sci-fi HUD.",
          turnId: "turn-1",
          timestamp: iso8601(now.addingTimeInterval(-7_200)),
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
          id: "sh-asst-1",
          content: "Great visual target. I'll create a `ShieldRingView` with:\n- 8 arc segments representing shield sectors\n- Color interpolation from green (100%) through yellow to red (critical)\n- A pulsing glow effect on damaged sectors\n- Sector integrity labels on the outer edge\n\nLet me set up the model first, then the view.",
          turnId: "turn-1",
          timestamp: iso8601(now.addingTimeInterval(-7_140)),
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
          id: "sh-shell-1",
          kind: .bash,
          title: "Create ShieldSector model",
          summary: "Created the data model for shield sectors with integrity tracking",
          command: "cat Sources/Models/ShieldSector.swift",
          args: [],
          stdout: "struct ShieldSector: Identifiable {\n    let id: Int\n    let label: String  // \"Fore\", \"Aft\", \"Port\", etc.\n    var integrity: Double  // 0.0 to 1.0\n    var isCritical: Bool { integrity < 0.4 }\n}",
          stderr: nil,
          exitCode: 0,
          durationSeconds: 0.01,
          cwd: "/Users/pilot/orbital-ui",
          renderHints: ServerConversationRenderHints(canExpand: true, defaultExpanded: false)
        ))
      ),
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 4,
        turnId: "turn-2",
        row: .assistant(ServerConversationMessageRow(
          id: "sh-asst-2",
          content: "The shield ring view is rendering with sector segments. Each sector pulses red when integrity drops below 40%. The arc segments use `trim(from:to:)` with smooth color interpolation.\n\nWant me to add haptic feedback on critical hits?",
          turnId: "turn-2",
          timestamp: iso8601(now.addingTimeInterval(-300)),
          isStreaming: false,
          images: nil,
          memoryCitation: nil
        ))
      ),
    ]
  }

  private static func dockingBayConversation(sessionId: String) -> [ServerConversationRowEntry] {
    let now = Date()
    return [
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 1,
        turnId: "turn-1",
        row: .user(ServerConversationMessageRow(
          id: "db-user-1",
          content: "Remove the legacy bay allocation system and migrate callers to the new slot-based API. The old code is in `src/docking/legacy_allocator.rs`.",
          turnId: "turn-1",
          timestamp: iso8601(now.addingTimeInterval(-14_400)),
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
          id: "db-asst-1",
          content: "I'll map all callers of the legacy allocator, migrate them to the slot-based API, then remove the old module. Let me find every call site first.",
          turnId: "turn-1",
          timestamp: iso8601(now.addingTimeInterval(-14_360)),
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
          id: "db-shell-1",
          kind: .bash,
          title: "Find legacy allocator callers",
          summary: "Found 12 call sites across 6 modules",
          command: "rg \"legacy_allocator\\|LegacyBayAlloc\" src/ --stats",
          args: [],
          stdout: "12 matches\n6 files contained matches\n847 lines in legacy_allocator.rs",
          stderr: nil,
          exitCode: 0,
          durationSeconds: 0.03,
          cwd: "/Users/pilot/nebula-api",
          renderHints: ServerConversationRenderHints(canExpand: true, defaultExpanded: false)
        ))
      ),
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 4,
        turnId: "turn-2",
        row: .assistant(ServerConversationMessageRow(
          id: "db-asst-2",
          content: "All done. Removed 847 lines of legacy code, migrated 12 callers to the slot-based API, and all tests pass. The new API is cleaner — callers just request a `DockingSlot` and the allocator handles bay assignment internally.",
          turnId: "turn-2",
          timestamp: iso8601(now.addingTimeInterval(-10_800)),
          isStreaming: false,
          images: nil,
          memoryCitation: nil
        ))
      ),
    ]
  }

  private static func commsArrayConversation(sessionId: String) -> [ServerConversationRowEntry] {
    let now = Date()
    return [
      ServerConversationRowEntry(
        sessionId: sessionId,
        sequence: 1,
        turnId: "turn-1",
        row: .user(ServerConversationMessageRow(
          id: "ca-user-1",
          content: "Create a real-time comms panel that shows incoming transmissions grouped by frequency band. Think Star Trek bridge communications.",
          turnId: "turn-1",
          timestamp: iso8601(now.addingTimeInterval(-5_400)),
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
          id: "ca-asst-1",
          content: "Fun project. I'll build a `CommsPanel` view with frequency band sections, each showing a live feed of transmissions. New messages will animate in from the right with a subtle scan-line effect.\n\nOne design question before I go further — should encrypted transmissions show a lock icon inline, or should I group them in a separate \"Secure Channel\" section?",
          turnId: "turn-1",
          timestamp: iso8601(now.addingTimeInterval(-120)),
          isStreaming: false,
          images: nil,
          memoryCitation: nil
        ))
      ),
    ]
  }

  // MARK: - Helpers

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
