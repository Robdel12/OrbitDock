//
//  DirectSessionComposerCommandDeckPlanner.swift
//  OrbitDock
//
//  Pure command deck item construction for DirectSessionComposer.
//

import SwiftUI

struct DirectSessionComposerCommandDeckContext {
  let query: String
  let hasSkillsPanel: Bool
  let hasMcpData: Bool
  let manualShellMode: Bool
  let projectFiles: [ProjectFileIndex.ProjectFile]
  let availableSkills: [ServerSkillMetadata]
  let mcpToolEntries: [ComposerMcpToolEntry]
  let mcpResourceEntries: [ComposerMcpResourceEntry]
  let mcpResourceTemplateEntries: [ComposerMcpResourceTemplateEntry]
}

enum DirectSessionComposerCommandDeckPlanner {
  static func extractMcpServerName(from toolKey: String) -> String? {
    let parts = toolKey.split(separator: "__")
    if parts.count >= 2, parts[0] == "mcp" {
      return String(parts[1])
    }
    if parts.count >= 2 {
      return String(parts[0])
    }
    return nil
  }

  static func mcpToolEntries(from tools: [String: ServerMcpTool]) -> [ComposerMcpToolEntry] {
    tools.compactMap { key, tool in
      guard let server = extractMcpServerName(from: key) else { return nil }
      return ComposerMcpToolEntry(id: key, server: server, tool: tool)
    }
    .sorted {
      if $0.server == $1.server {
        return $0.tool.name < $1.tool.name
      }
      return $0.server < $1.server
    }
  }

  static func mcpResourceEntries(from resources: [String: [ServerMcpResource]]) -> [ComposerMcpResourceEntry] {
    resources.flatMap { server, resources in
      resources.map { resource in
        ComposerMcpResourceEntry(id: "\(server)|\(resource.uri)", server: server, resource: resource)
      }
    }
    .sorted {
      if $0.server == $1.server {
        return $0.resource.uri < $1.resource.uri
      }
      return $0.server < $1.server
    }
  }

  static func mcpResourceTemplateEntries(
    from resourceTemplates: [String: [ServerMcpResourceTemplate]]
  ) -> [ComposerMcpResourceTemplateEntry] {
    resourceTemplates.flatMap { server, templates in
      templates.map { template in
        ComposerMcpResourceTemplateEntry(
          id: "\(server)|\(template.uriTemplate)",
          server: server,
          resourceTemplate: template
        )
      }
    }
    .sorted {
      if $0.server == $1.server {
        return $0.resourceTemplate.uriTemplate < $1.resourceTemplate.uriTemplate
      }
      return $0.server < $1.server
    }
  }

  static func buildItems(
    _ context: DirectSessionComposerCommandDeckContext,
    maxItems: Int = 18
  ) -> [ComposerCommandDeckItem] {
    let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    func matches(_ values: [String]) -> Bool {
      guard !query.isEmpty else { return true }
      return values.contains { $0.lowercased().contains(query) }
    }

    var items: [ComposerCommandDeckItem] = []

    if matches(["file", "files", "mention", "attach", "project"]) {
      items.append(ComposerCommandDeckItem(
        id: "action:file-picker",
        section: "Actions",
        icon: "paperclip",
        title: "Attach Project Files",
        subtitle: "Browse project files and add @mentions",
        tint: .composerPrompt,
        kind: .openFilePicker
      ))
    }

    if context.hasSkillsPanel, matches(["skill", "skills", "agent", "attach"]) {
      items.append(ComposerCommandDeckItem(
        id: "action:skills",
        section: "Actions",
        icon: "bolt.fill",
        title: "Attach Skills",
        subtitle: "Pick enabled skills for this turn",
        tint: .toolSkill,
        kind: .openSkillsPanel
      ))
    }

    if matches(["shell", "terminal", "command", "run"]) {
      items.append(ComposerCommandDeckItem(
        id: "action:shell-mode",
        section: "Actions",
        icon: "terminal",
        title: context.manualShellMode ? "Disable Shell Mode" : "Enable Shell Mode",
        subtitle: "Switch composer into command execution mode",
        tint: .shellAccent,
        kind: .toggleShellMode
      ))
      items.append(ComposerCommandDeckItem(
        id: "action:shell-prefix",
        section: "Actions",
        icon: "exclamationmark.bubble",
        title: "Insert ! Shell Prefix",
        subtitle: "Type !<command> to run shell directly",
        tint: .shellAccent,
        kind: .insertText("!")
      ))
    }

    if context.hasMcpData, matches(["mcp", "server", "tools", "refresh"]) {
      items.append(ComposerCommandDeckItem(
        id: "action:mcp-refresh",
        section: "Actions",
        icon: "arrow.clockwise",
        title: "Refresh MCP Servers",
        subtitle: "Reload MCP tools and auth status",
        tint: .toolMcp,
        kind: .refreshMcp
      ))
    }

    for file in context.projectFiles {
      items.append(ComposerCommandDeckItem(
        id: "file:\(file.id)",
        section: "Files",
        icon: "doc.text",
        title: file.name,
        subtitle: file.relativePath,
        tint: .composerPrompt,
        kind: .attachFile(file)
      ))
    }

    let matchingSkills = context.availableSkills.filter { skill in
      query.isEmpty || matches([skill.name, skill.shortDescription ?? "", skill.description])
    }
    for skill in matchingSkills.prefix(8) {
      items.append(ComposerCommandDeckItem(
        id: "skill:\(skill.path)",
        section: "Skills",
        icon: "bolt.fill",
        title: "$\(skill.name)",
        subtitle: skill.shortDescription ?? skill.description,
        tint: .toolSkill,
        kind: .attachSkill(skill)
      ))
    }

    for entry in context.mcpToolEntries where query.isEmpty || matches([
      "mcp",
      entry.server,
      entry.tool.name,
      entry.tool.title ?? "",
      entry.tool.description ?? "",
    ]) {
      items.append(ComposerCommandDeckItem(
        id: "mcp-tool:\(entry.id)",
        section: "MCP Tools",
        icon: "square.stack.3d.up.fill",
        title: "\(entry.server).\(entry.tool.name)",
        subtitle: entry.tool.description ?? "Insert MCP tool reference",
        tint: .toolMcp,
        kind: .insertMcpTool(server: entry.server, tool: entry.tool)
      ))
    }

    for entry in context.mcpResourceEntries where query.isEmpty || matches([
      entry.server,
      entry.resource.name,
      entry.resource.uri,
      entry.resource.description ?? "",
    ]) {
      items.append(ComposerCommandDeckItem(
        id: "mcp-resource:\(entry.id)",
        section: "MCP Resources",
        icon: "tray.full.fill",
        title: "\(entry.server): \(entry.resource.name)",
        subtitle: entry.resource.uri,
        tint: .toolMcp,
        kind: .insertMcpResource(server: entry.server, resource: entry.resource)
      ))
    }

    for entry in context.mcpResourceTemplateEntries where query.isEmpty || matches([
      entry.server,
      entry.resourceTemplate.name,
      entry.resourceTemplate.uriTemplate,
      entry.resourceTemplate.description ?? "",
    ]) {
      items.append(ComposerCommandDeckItem(
        id: "mcp-resource-template:\(entry.id)",
        section: "MCP Templates",
        icon: "square.text.square.fill",
        title: "\(entry.server): \(entry.resourceTemplate.name)",
        subtitle: entry.resourceTemplate.uriTemplate,
        tint: .toolMcp,
        kind: .insertMcpResourceTemplate(server: entry.server, resourceTemplate: entry.resourceTemplate)
      ))
    }

    return items.prefix(maxItems).map { $0 }
  }
}
