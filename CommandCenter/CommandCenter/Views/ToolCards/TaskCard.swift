//
//  TaskCard.swift
//  CommandCenter
//
//  Agent/subagent task card with prompt preview
//

import SwiftUI

struct TaskCard: View {
    let message: TranscriptMessage
    @Binding var isExpanded: Bool

    private var color: Color { ToolCardStyle.color(for: message.toolName) }

    private var description: String { message.taskDescription ?? "" }
    private var prompt: String { message.taskPrompt ?? "" }
    private var agentType: String {
        (message.toolInput?["subagent_type"] as? String) ?? "general"
    }

    private var agentInfo: (icon: String, label: String) {
        switch agentType.lowercased() {
        case "explore": return ("binoculars.fill", "Explore")
        case "plan": return ("map.fill", "Plan")
        case "bash": return ("terminal.fill", "Bash")
        default: return ("person.2.fill", agentType.capitalized)
        }
    }

    var body: some View {
        ToolCardContainer(color: color, isExpanded: isExpanded) {
            header
        } content: {
            expandedContent
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: agentInfo.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Task")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)

                    // Agent type badge
                    Text(agentInfo.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !message.isInProgress {
                ToolCardDuration(duration: message.formattedDuration)
            }

            if message.isInProgress {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Running...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(color)
                }
            } else if !prompt.isEmpty {
                ToolCardExpandButton(isExpanded: $isExpanded)
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Prompt
            if !prompt.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PROMPT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .tracking(0.5)

                    Text(prompt.count > 500 ? String(prompt.prefix(500)) + "..." : prompt)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.8))
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Result
            if let output = message.toolOutput, !output.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RESULT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .tracking(0.5)

                    Text(output.count > 300 ? String(output.prefix(300)) + "..." : output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.7))
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.backgroundTertiary.opacity(0.5))
            }
        }
    }
}
