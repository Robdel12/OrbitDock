@testable import OrbitDock
import Testing

struct DirectSessionComposerCommandDeckPlannerTests {
  @Test func extractsSortedMcpEntriesFromProtocolPayloads() {
    let tools: [String: ServerMcpTool] = [
      "mcp__design__render": ServerMcpTool(
        name: "render",
        title: nil,
        description: "Render a design",
        inputSchema: AnyCodable(["type": "object"]),
        outputSchema: nil,
        annotations: nil
      ),
      "mcp__fs__read_file": ServerMcpTool(
        name: "read_file",
        title: nil,
        description: "Read a file",
        inputSchema: AnyCodable(["type": "object"]),
        outputSchema: nil,
        annotations: nil
      ),
    ]

    let entries = DirectSessionComposerCommandDeckPlanner.mcpToolEntries(from: tools)

    #expect(entries.map(\.server) == ["design", "fs"])
    #expect(entries.map(\.tool.name) == ["render", "read_file"])
  }

  @Test func commandDeckIncludesMatchingActionsAndFeatureEntries() {
    let context = DirectSessionComposerCommandDeckContext(
      query: "mcp",
      hasSkillsPanel: true,
      hasMcpData: true,
      manualShellMode: false,
      projectFiles: [],
      availableSkills: [
        ServerSkillMetadata(
          name: "mcp-debug",
          description: "Inspect MCP issues",
          shortDescription: "Debug MCP",
          path: "/skills/mcp-debug",
          scope: .repo,
          enabled: true
        )
      ],
      mcpToolEntries: [
        ComposerMcpToolEntry(
          id: "mcp__design__render",
          server: "design",
          tool: ServerMcpTool(
            name: "render",
            title: nil,
            description: "Render a design",
            inputSchema: AnyCodable(["type": "object"]),
            outputSchema: nil,
            annotations: nil
          )
        )
      ],
      mcpResourceEntries: [
        ComposerMcpResourceEntry(
          id: "design|mcp://design/assets",
          server: "design",
          resource: ServerMcpResource(
            name: "assets",
            uri: "mcp://design/assets",
            description: "Shared assets",
            mimeType: nil,
            title: nil,
            size: nil,
            annotations: nil
          )
        )
      ],
      mcpResourceTemplateEntries: [
        ComposerMcpResourceTemplateEntry(
          id: "design|mcp://design/assets/{asset_id}",
          server: "design",
          resourceTemplate: ServerMcpResourceTemplate(
            name: "asset-template",
            uriTemplate: "mcp://design/assets/{asset_id}",
            title: nil,
            description: "Parameterized asset lookup",
            mimeType: nil,
            annotations: nil
          )
        )
      ]
    )

    let items = DirectSessionComposerCommandDeckPlanner.buildItems(context)

    #expect(items.contains(where: { $0.id == "action:mcp-refresh" }))
    #expect(items.contains(where: { $0.id == "skill:/skills/mcp-debug" }))
    #expect(items.contains(where: { $0.id == "mcp-tool:mcp__design__render" }))
    #expect(items.contains(where: { $0.id == "mcp-resource:design|mcp://design/assets" }))
    #expect(items.contains(where: { $0.id == "mcp-resource-template:design|mcp://design/assets/{asset_id}" }))
  }

  @Test func commandDeckLimitsResultsAndReflectsShellModeState() {
    let files = (0..<20).map { index in
      ProjectFileIndex.ProjectFile(
        id: "src/File\(index).swift",
        name: "File\(index).swift",
        relativePath: "src/File\(index).swift"
      )
    }

    let context = DirectSessionComposerCommandDeckContext(
      query: "",
      hasSkillsPanel: false,
      hasMcpData: false,
      manualShellMode: true,
      projectFiles: files,
      availableSkills: [],
      mcpToolEntries: [],
      mcpResourceEntries: [],
      mcpResourceTemplateEntries: []
    )

    let items = DirectSessionComposerCommandDeckPlanner.buildItems(context)

    #expect(items.count == 18)
    #expect(items.contains(where: { $0.id == "action:shell-mode" && $0.title == "Disable Shell Mode" }))
  }
}
