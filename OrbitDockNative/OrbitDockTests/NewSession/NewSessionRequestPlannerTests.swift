@testable import OrbitDock
import Testing

@MainActor
struct NewSessionRequestPlannerTests {
  @Test func claudeLaunchPlanBuildsDirectRequestAndTrimsToolLists() {
    let plan = NewSessionRequestPlanner.planLaunch(
      selectedPath: " /tmp/project ",
      useWorktree: false,
      worktreeBranch: "",
      worktreeBaseBranch: "",
      providerConfiguration: NewSessionProviderConfiguration(
        provider: .claude,
        claudeModel: " claude-opus ",
        claudePermissionMode: .default,
        claudeAllowBypassPermissions: false,
        allowedToolsText: "Read, Glob, Bash(git:*) ",
        disallowedToolsText: " Write, Edit ",
        claudeEffort: " high ",
        codexModel: "",
        codexUseOrbitDockOverrides: false,
        codexAutonomy: .autonomous,
        codexCollaborationMode: nil,
        codexMultiAgentEnabled: false,
        codexPersonality: nil,
        codexServiceTier: nil,
        codexInstructions: nil
      ),
      bootstrapPrompt: " Continue work "
    )

    guard let plan else {
      Issue.record("Expected a launch plan")
      return
    }
    if case let .direct(cwd) = plan.target {
      #expect(cwd == "/tmp/project")
    } else {
      Issue.record("Expected a direct launch target")
    }
    if case let .claude(model, permissionMode, _, allowedTools, disallowedTools, effort) = plan.requestTemplate {
      #expect(model == "claude-opus")
      #expect(permissionMode == nil)
      #expect(allowedTools == ["Read", "Glob", "Bash(git:*)"])
      #expect(disallowedTools == ["Write", "Edit"])
      #expect(effort == "high")
    } else {
      Issue.record("Expected a Claude request template")
    }
    #expect(plan.bootstrapPrompt == "Continue work")
  }

  @Test func claudeWorktreePlanChoosesWorktreeTargetAndOmitsBlankValues() {
    let plan = NewSessionRequestPlanner.planLaunch(
      selectedPath: "/tmp/repo",
      useWorktree: true,
      worktreeBranch: " feature/printer ",
      worktreeBaseBranch: " ",
      providerConfiguration: NewSessionProviderConfiguration(
        provider: .claude,
        claudeModel: " ",
        claudePermissionMode: .acceptEdits,
        claudeAllowBypassPermissions: false,
        allowedToolsText: "",
        disallowedToolsText: "",
        claudeEffort: "",
        codexModel: "",
        codexUseOrbitDockOverrides: false,
        codexAutonomy: .autonomous,
        codexCollaborationMode: nil,
        codexMultiAgentEnabled: false,
        codexPersonality: nil,
        codexServiceTier: nil,
        codexInstructions: nil
      ),
      bootstrapPrompt: nil
    )

    guard let plan else {
      Issue.record("Expected a launch plan")
      return
    }
    if case let .worktree(repoPath, branch, baseBranch) = plan.target {
      #expect(repoPath == "/tmp/repo")
      #expect(branch == "feature/printer")
      #expect(baseBranch == nil)
    } else {
      Issue.record("Expected a worktree launch target")
    }
    if case let .claude(model, permissionMode, _, allowedTools, disallowedTools, effort) = plan.requestTemplate {
      #expect(model == nil)
      #expect(permissionMode == ClaudePermissionMode.acceptEdits.rawValue)
      #expect(allowedTools.isEmpty)
      #expect(disallowedTools.isEmpty)
      #expect(effort == nil)
    } else {
      Issue.record("Expected a Claude request template")
    }
  }

  @Test func codexLaunchPlanBuildsApprovalAndSandboxFromAutonomy() {
    let plan = NewSessionRequestPlanner.planLaunch(
      selectedPath: "/tmp/repo",
      useWorktree: false,
      worktreeBranch: "",
      worktreeBaseBranch: "",
      providerConfiguration: NewSessionProviderConfiguration(
        provider: .codex,
        claudeModel: nil,
        claudePermissionMode: .default,
        claudeAllowBypassPermissions: false,
        allowedToolsText: "Read",
        disallowedToolsText: "Edit",
        claudeEffort: "max",
        codexModel: " gpt-5-codex ",
        codexUseOrbitDockOverrides: true,
        codexAutonomy: .open,
        codexCollaborationMode: "plan",
        codexMultiAgentEnabled: true,
        codexPersonality: "friendly",
        codexServiceTier: "fast",
        codexInstructions: " Stay grounded. "
      ),
      bootstrapPrompt: nil
    )

    guard let plan else {
      Issue.record("Expected a launch plan")
      return
    }
    if case let .direct(cwd) = plan.target {
      #expect(cwd == "/tmp/repo")
    } else {
      Issue.record("Expected a direct launch target")
    }
    if case let .codex(
      model,
      approvalPolicy,
      sandboxMode,
      collaborationMode,
      multiAgent,
      personality,
      serviceTier,
      developerInstructions
    ) = plan.requestTemplate {
      #expect(model == "gpt-5-codex")
      #expect(approvalPolicy == "on-request")
      #expect(sandboxMode == "danger-full-access")
      #expect(collaborationMode == "plan")
      #expect(multiAgent == true)
      #expect(personality == "friendly")
      #expect(serviceTier == "fast")
      #expect(developerInstructions == "Stay grounded.")
    } else {
      Issue.record("Expected a Codex request template")
    }
  }

  @Test func blankWorktreeBranchFallsBackToDirectLaunch() {
    let plan = NewSessionRequestPlanner.planLaunch(
      selectedPath: "/tmp/repo",
      useWorktree: true,
      worktreeBranch: "  ",
      worktreeBaseBranch: "main",
      providerConfiguration: NewSessionProviderConfiguration(
        provider: .claude,
        claudeModel: "claude-sonnet",
        claudePermissionMode: .plan,
        claudeAllowBypassPermissions: false,
        allowedToolsText: "",
        disallowedToolsText: "",
        claudeEffort: nil,
        codexModel: "",
        codexUseOrbitDockOverrides: false,
        codexAutonomy: .autonomous,
        codexCollaborationMode: nil,
        codexMultiAgentEnabled: false,
        codexPersonality: nil,
        codexServiceTier: nil,
        codexInstructions: nil
      ),
      bootstrapPrompt: nil
    )

    guard let plan else {
      Issue.record("Expected a launch plan")
      return
    }
    if case let .direct(cwd) = plan.target {
      #expect(cwd == "/tmp/repo")
    } else {
      Issue.record("Expected a direct launch target")
    }
  }

  @Test func emptySelectedPathDoesNotProduceLaunchPlan() {
    let plan = NewSessionRequestPlanner.planLaunch(
      selectedPath: " ",
      useWorktree: false,
      worktreeBranch: "",
      worktreeBaseBranch: "",
      providerConfiguration: NewSessionProviderConfiguration(
        provider: .claude,
        claudeModel: "claude-sonnet",
        claudePermissionMode: .plan,
        claudeAllowBypassPermissions: false,
        allowedToolsText: "",
        disallowedToolsText: "",
        claudeEffort: nil,
        codexModel: "",
        codexUseOrbitDockOverrides: false,
        codexAutonomy: .autonomous,
        codexCollaborationMode: nil,
        codexMultiAgentEnabled: false,
        codexPersonality: nil,
        codexServiceTier: nil,
        codexInstructions: nil
      ),
      bootstrapPrompt: nil
    )

    #expect(plan == nil)
  }

  @Test func emptyCodexModelDoesNotProduceLaunchPlan() {
    let plan = NewSessionRequestPlanner.planLaunch(
      selectedPath: "/tmp/repo",
      useWorktree: false,
      worktreeBranch: "",
      worktreeBaseBranch: "",
      providerConfiguration: NewSessionProviderConfiguration(
        provider: .codex,
        claudeModel: nil,
        claudePermissionMode: .default,
        claudeAllowBypassPermissions: false,
        allowedToolsText: "",
        disallowedToolsText: "",
        claudeEffort: nil,
        codexModel: " ",
        codexUseOrbitDockOverrides: true,
        codexAutonomy: .autonomous,
        codexCollaborationMode: nil,
        codexMultiAgentEnabled: false,
        codexPersonality: nil,
        codexServiceTier: nil,
        codexInstructions: nil
      ),
      bootstrapPrompt: nil
    )

    #expect(plan == nil)
  }
}
