//
//  ToolIndicator.swift
//  CommandCenter
//
//  Routes to the appropriate tool card based on tool type
//

import SwiftUI

struct ToolIndicator: View {
    let message: TranscriptMessage
    @State private var isExpanded = false
    @State private var isHovering = false

    private var toolType: ToolType {
        guard let name = message.toolName else { return .standard }
        let lowercased = name.lowercased()

        // Check for MCP tools first (mcp__<server>__<tool>)
        if name.hasPrefix("mcp__") {
            return .mcp
        }

        switch lowercased {
        case "edit", "write", "notebookedit":
            return .edit
        case "bash":
            return .bash
        case "read":
            return .read
        case "glob":
            return .glob
        case "grep":
            return .grep
        case "task":
            return .task
        case "webfetch":
            return .webFetch
        case "websearch":
            return .webSearch
        case "askuserquestion":
            return .askUserQuestion
        case "toolsearch":
            return .toolSearch
        case "skill":
            return .skill
        case "enterplanmode", "exitplanmode":
            return .planMode
        case "taskcreate", "taskupdate", "tasklist", "taskget":
            return .todoTask
        default:
            return .standard
        }
    }

    private enum ToolType {
        case edit, bash, read, glob, grep, task
        case mcp, webFetch, webSearch, askUserQuestion, toolSearch
        case skill, planMode, todoTask
        case standard
    }

    var body: some View {
        Group {
            switch toolType {
            case .edit:
                EditCard(message: message, isExpanded: $isExpanded)
            case .bash:
                BashCard(message: message, isExpanded: $isExpanded, isHovering: $isHovering)
            case .read:
                ReadCard(message: message, isExpanded: $isExpanded)
            case .glob:
                GlobCard(message: message, isExpanded: $isExpanded)
            case .grep:
                GrepCard(message: message, isExpanded: $isExpanded)
            case .task:
                TaskCard(message: message, isExpanded: $isExpanded)
            case .mcp:
                MCPCard(message: message, isExpanded: $isExpanded)
            case .webFetch:
                WebFetchCard(message: message, isExpanded: $isExpanded)
            case .webSearch:
                WebSearchCard(message: message, isExpanded: $isExpanded)
            case .askUserQuestion:
                AskUserQuestionCard(message: message, isExpanded: $isExpanded)
            case .toolSearch:
                ToolSearchCard(message: message, isExpanded: $isExpanded)
            case .skill:
                SkillCard(message: message, isExpanded: $isExpanded)
            case .planMode:
                PlanModeCard(message: message, isExpanded: $isExpanded)
            case .todoTask:
                TodoTaskCard(message: message, isExpanded: $isExpanded)
            case .standard:
                StandardToolCard(message: message, isExpanded: $isExpanded, isHovering: $isHovering)
            }
        }
        .padding(.vertical, 6)
    }
}
