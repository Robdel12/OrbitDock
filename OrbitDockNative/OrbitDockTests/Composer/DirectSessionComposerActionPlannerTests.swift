@testable import OrbitDock
import Testing

struct DirectSessionComposerActionPlannerTests {
  @Test func directCodexPromptsDoNotRequireLocalModelOverride() {
    let context = DirectSessionComposerSendContext(
      inputMode: .prompt,
      rawMessage: "Ship it",
      hasAttachments: false,
      hasMentions: false,
      isSending: false,
      isConnected: true,
      providerMode: .directCodex,
      selectedCodexModel: nil,
      selectedClaudeModel: "",
      inheritedModel: nil,
      effort: "default"
    )

    #expect(DirectSessionComposerActionPlanner.canSend(context))
    #expect(
      DirectSessionComposerActionPlanner.planSend(context)
        == .send(content: "Ship it", model: nil, effort: "default")
    )
  }

  @Test func directCodexPromptsDoNotTurnInheritedModelIntoOverride() {
    let context = DirectSessionComposerSendContext(
      inputMode: .prompt,
      rawMessage: "Hi there",
      hasAttachments: false,
      hasMentions: false,
      isSending: false,
      isConnected: true,
      providerMode: .directCodex,
      selectedCodexModel: nil,
      selectedClaudeModel: "",
      inheritedModel: "qwen/qwen3-coder-next",
      effort: "high"
    )

    #expect(DirectSessionComposerActionPlanner.canSend(context))
    #expect(
      DirectSessionComposerActionPlanner.planSend(context)
        == .send(content: "Hi there", model: nil, effort: "high")
    )
  }

  @Test func directCodexPromptsKeepExplicitCustomOverride() {
    let context = DirectSessionComposerSendContext(
      inputMode: .prompt,
      rawMessage: "Hi there",
      hasAttachments: false,
      hasMentions: false,
      isSending: false,
      isConnected: true,
      providerMode: .directCodex,
      selectedCodexModel: "qwen/qwen3-coder-next",
      selectedClaudeModel: "",
      inheritedModel: "qwen/qwen3-coder-next",
      effort: "high"
    )

    #expect(DirectSessionComposerActionPlanner.canSend(context))
    #expect(
      DirectSessionComposerActionPlanner.planSend(context)
        == .send(content: "Hi there", model: "qwen/qwen3-coder-next", effort: "high")
    )
  }

  @Test func shellModeRequiresConnectionAndExitsShellModeAfterSend() {
    let offlineContext = DirectSessionComposerSendContext(
      inputMode: .shell,
      rawMessage: "ls -la",
      hasAttachments: false,
      hasMentions: false,
      isSending: false,
      isConnected: false,
      providerMode: .inherited,
      selectedCodexModel: nil,
      selectedClaudeModel: "",
      inheritedModel: "claude-opus",
      effort: "default"
    )
    #expect(
      DirectSessionComposerActionPlanner.planSend(offlineContext)
        == .offlineShell("Server is offline. Shell command not sent.")
    )

    let onlineContext = DirectSessionComposerSendContext(
      inputMode: .shell,
      rawMessage: "ls -la",
      hasAttachments: false,
      hasMentions: false,
      isSending: false,
      isConnected: true,
      providerMode: .inherited,
      selectedCodexModel: nil,
      selectedClaudeModel: "",
      inheritedModel: "claude-opus",
      effort: "default"
    )
    #expect(
      DirectSessionComposerActionPlanner.planSend(onlineContext)
        == .executeShell(command: "ls -la", exitsShellMode: true)
    )
  }

  @Test func bangPrefixRoutesPromptToShellExecution() {
    let context = DirectSessionComposerSendContext(
      inputMode: .prompt,
      rawMessage: "!git status",
      hasAttachments: false,
      hasMentions: false,
      isSending: false,
      isConnected: true,
      providerMode: .inherited,
      selectedCodexModel: nil,
      selectedClaudeModel: "",
      inheritedModel: "claude-opus",
      effort: "default"
    )

    #expect(
      DirectSessionComposerActionPlanner.planSend(context)
        == .executeShell(command: "git status", exitsShellMode: false)
    )
  }

  @Test func steerModeAllowsAttachmentOnlyPrompts() {
    let context = DirectSessionComposerSendContext(
      inputMode: .steer,
      rawMessage: "",
      hasAttachments: true,
      hasMentions: false,
      isSending: false,
      isConnected: true,
      providerMode: .inherited,
      selectedCodexModel: nil,
      selectedClaudeModel: "",
      inheritedModel: "claude-opus",
      effort: "default"
    )

    #expect(DirectSessionComposerActionPlanner.canSend(context))
    #expect(DirectSessionComposerActionPlanner.planSend(context) == .steer(content: ""))
  }

  @Test func promptModeBuildsSendPlanForInheritedModel() {
    let context = DirectSessionComposerSendContext(
      inputMode: .prompt,
      rawMessage: "Continue the work",
      hasAttachments: false,
      hasMentions: true,
      isSending: false,
      isConnected: true,
      providerMode: .inherited,
      selectedCodexModel: nil,
      selectedClaudeModel: "",
      inheritedModel: "claude-opus",
      effort: "high"
    )

    #expect(DirectSessionComposerActionPlanner.canSend(context))
    #expect(
      DirectSessionComposerActionPlanner.planSend(context)
        == .send(content: "Continue the work", model: "claude-opus", effort: "high")
    )
  }
}
