//
//  TaskCard.swift
//  CommandCenter
//
//  Enhanced agent/subagent task card with prominent result display
//

import SwiftUI

struct TaskCard: View {
    let message: TranscriptMessage
    @Binding var isExpanded: Bool

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
            hasContent: !prompt.isEmpty || !output.isEmpty
        ) {
            header
        } content: {
            expandedContent
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
                        Text(output)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary.opacity(0.9))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.15, green: 0.25, blue: 0.18).opacity(0.5))
            }

            // Prompt section
            if !prompt.isEmpty {
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
