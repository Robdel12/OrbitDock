import Testing
@testable import OrbitDock

struct ClaudeHooksSetupPlannerTests {
  @Test
  func hooksConfiguredReturnsTrueForOrbitDockCommand() {
    #expect(ClaudeHooksSetupPlanner.hooksConfigured(contents: "\"command\": \"orbitdock hook-forward claude_tool_event\""))
  }

  @Test
  func hooksConfiguredReturnsFalseForUnrelatedSettingsFile() {
    #expect(!ClaudeHooksSetupPlanner.hooksConfigured(contents: "{ \"theme\": \"dark\" }"))
  }

  @Test
  func hooksConfigurationJSONIncludesHookForwardCommands() {
    let json = ClaudeHooksSetupPlanner.hooksConfigurationJSON(hookForwardPath: "/tmp/orbitdock")

    #expect(json.contains("/tmp/orbitdock"))
    #expect(json.contains("hook-forward claude_tool_event"))
    #expect(json.contains("hook-forward claude_subagent_event"))
  }
}
