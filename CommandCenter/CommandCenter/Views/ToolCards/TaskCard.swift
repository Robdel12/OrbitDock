//
//  TaskCard.swift
//  CommandCenter
//
//  Enhanced agent/subagent task card with nested tool calls
//

import SwiftUI

struct TaskCard: View {
    let message: TranscriptMessage
    @Binding var isExpanded: Bool
    var transcriptPath: String? = nil

    // Subagent tool calls (loaded lazily when expanded)
    @State private var subagentTools: [TranscriptMessage] = []
    @State private var hasLoadedSubagent = false
    @State private var showSubagentTools = false

    private var description: String { message.taskDescription ?? "" }
    private var prompt: String { message.taskPrompt ?? "" }
    private var output: String { message.toolOutput ?? "" }
    private var isComplete: Bool { !message.isInProgress && !output.isEmpty }

    private var agentType: String {
        (message.toolInput?["subagent_type"] as? String) ?? "general"
    }

    private var agentInfo: AgentTypeInfo {
        AgentTypeInfo.from(agentType)
    }

    var body: some View {
        ToolCardContainer(
            color: agentInfo.color,
            isExpanded: $isExpanded,
            hasContent: !prompt.isEmpty || !output.isEmpty || !subagentTools.isEmpty
        ) {
            header
        } content: {
            expandedContent
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded && !hasLoadedSubagent {
                loadSubagentTools()
            }
        }
    }

    // MARK: - Load Subagent Tools

    private func loadSubagentTools() {
        guard let path = transcriptPath, !prompt.isEmpty else {
            hasLoadedSubagent = true
            return
        }

        // Find and parse subagent transcript in background
        DispatchQueue.global(qos: .userInitiated).async {
            if let subagentPath = TranscriptParser.findSubagentTranscript(sessionPath: path, taskPrompt: prompt) {
                let tools = TranscriptParser.parseSubagentTools(subagentPath: subagentPath)
                DispatchQueue.main.async {
                    self.subagentTools = tools
                    self.hasLoadedSubagent = true
                }
            } else {
                DispatchQueue.main.async {
                    self.hasLoadedSubagent = true
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Agent icon with status ring
            ZStack {
                Circle()
                    .fill(agentInfo.color.opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: agentInfo.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(agentInfo.color)

                // Status ring
                if message.isInProgress {
                    Circle()
                        .strokeBorder(agentInfo.color.opacity(0.5), lineWidth: 2)
                        .frame(width: 32, height: 32)
                } else if isComplete {
                    Circle()
                        .strokeBorder(Color(red: 0.4, green: 0.9, blue: 0.5), lineWidth: 2)
                        .frame(width: 32, height: 32)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    // Agent type badge
                    HStack(spacing: 4) {
                        Text(agentInfo.label)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(agentInfo.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                    // Status
                    if message.isInProgress {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Running...")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(agentInfo.color)
                    } else if isComplete {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                            Text("Complete")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Description
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(1)
                }

                // Result preview in header when complete
                if isComplete && !isExpanded {
                    Text(output.prefix(100).replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if !message.isInProgress {
                    ToolCardDuration(duration: message.formattedDuration)
                }

                ToolCardExpandButton(isExpanded: $isExpanded)
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Result first (most important when complete)
            if isComplete {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                        Text("AGENT RESULT")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5).opacity(0.8))
                            .tracking(0.5)
                    }

                    ScrollView {
                        MarkdownView(content: output)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.15, green: 0.25, blue: 0.18).opacity(0.5))
            }

            // Subagent tools section
            if !subagentTools.isEmpty {
                subagentToolsSection
            } else if !hasLoadedSubagent && isExpanded {
                // Loading indicator
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading agent activity...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            // Prompt section (collapsed by default if we have tools)
            if !prompt.isEmpty {
                promptSection
            }
        }
    }

    // MARK: - Subagent Tools Section

    @ViewBuilder
    private var subagentToolsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with toggle
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    showSubagentTools.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showSubagentTools ? 90 : 0))
                        .foregroundStyle(agentInfo.color)

                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(agentInfo.color.opacity(0.7))

                    Text("AGENT ACTIVITY")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(agentInfo.color.opacity(0.8))
                        .tracking(0.5)

                    Text("(\(subagentTools.count) tools)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(agentInfo.color.opacity(0.08))

            // Nested tool list
            if showSubagentTools {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(subagentTools.prefix(20).enumerated()), id: \.element.id) { index, tool in
                        SubagentToolRow(tool: tool, color: agentInfo.color)
                    }

                    if subagentTools.count > 20 {
                        Text("... +\(subagentTools.count - 20) more tools")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
                .background(Color.backgroundTertiary.opacity(0.2))
            }
        }
    }

    // MARK: - Prompt Section

    @ViewBuilder
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10))
                    .foregroundStyle(agentInfo.color.opacity(0.7))
                Text("PROMPT")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.quaternary)
                    .tracking(0.5)
            }

            ScrollView {
                Text(prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.7))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundTertiary.opacity(0.3))
    }
}

// MARK: - Subagent Tool Row

private struct SubagentToolRow: View {
    let tool: TranscriptMessage
    let color: Color

    private var toolColor: Color {
        ToolCardStyle.color(for: tool.toolName)
    }

    private var toolIcon: String {
        ToolCardStyle.icon(for: tool.toolName)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Indent indicator
            Rectangle()
                .fill(color.opacity(0.3))
                .frame(width: 2)
                .padding(.leading, 8)

            // Tool icon
            Image(systemName: toolIcon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(toolColor)
                .frame(width: 14)

            // Tool name
            Text(tool.toolName ?? "Tool")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(toolColor)

            // Summary
            Text(tool.content)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            // Status
            if tool.isInProgress {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5).opacity(0.7))
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 12)
    }
}

// MARK: - Agent Type Info

private struct AgentTypeInfo {
    let icon: String
    let label: String
    let color: Color

    static func from(_ type: String) -> AgentTypeInfo {
        switch type.lowercased() {
        case "explore":
            return AgentTypeInfo(
                icon: "binoculars.fill",
                label: "Explore",
                color: Color(red: 0.4, green: 0.7, blue: 0.95)  // Light blue
            )
        case "plan":
            return AgentTypeInfo(
                icon: "map.fill",
                label: "Plan",
                color: Color(red: 0.6, green: 0.5, blue: 0.9)  // Purple
            )
        case "bash":
            return AgentTypeInfo(
                icon: "terminal.fill",
                label: "Bash",
                color: Color(red: 0.35, green: 0.8, blue: 0.5)  // Green
            )
        case "general-purpose":
            return AgentTypeInfo(
                icon: "cpu.fill",
                label: "General",
                color: Color(red: 0.45, green: 0.45, blue: 0.95)  // Indigo
            )
        case "claude-code-guide":
            return AgentTypeInfo(
                icon: "book.fill",
                label: "Guide",
                color: Color(red: 0.9, green: 0.6, blue: 0.3)  // Orange
            )
        case "linear-project-manager":
            return AgentTypeInfo(
                icon: "list.bullet.rectangle.fill",
                label: "Linear",
                color: Color(red: 0.35, green: 0.5, blue: 0.95)  // Linear blue
            )
        default:
            return AgentTypeInfo(
                icon: "person.2.fill",
                label: type.isEmpty ? "Agent" : type.capitalized,
                color: Color(red: 0.5, green: 0.5, blue: 0.6)  // Gray
            )
        }
    }
}
