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
        guard let name = message.toolName?.lowercased() else { return .standard }

        switch name {
        case "edit", "write", "notebookedit": return .edit
        case "bash": return .bash
        case "read": return .read
        case "glob": return .glob
        case "grep": return .grep
        case "task": return .task
        default: return .standard
        }
    }

    private enum ToolType {
        case edit, bash, read, glob, grep, task, standard
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
            case .standard:
                StandardToolCard(message: message, isExpanded: $isExpanded, isHovering: $isHovering)
            }
        }
        .padding(.vertical, 6)
    }
}
