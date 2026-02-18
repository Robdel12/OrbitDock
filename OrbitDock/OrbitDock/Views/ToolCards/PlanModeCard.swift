//
//  PlanModeCard.swift
//  OrbitDock
//
//  Shows plan mode entry/exit
//

import SwiftUI

struct PlanModeCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool

  private var color: Color {
    Color(red: 0.45, green: 0.7, blue: 0.45)
  } // Soft green

  private var isEntering: Bool {
    message.toolName?.lowercased() == "enterplanmode"
  }

  private var output: String {
    message.toolOutput ?? ""
  }

  var body: some View {
    ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: !output.isEmpty) {
      header
    } content: {
      expandedContent
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: isEntering ? "doc.text.magnifyingglass" : "checkmark.rectangle")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(color)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(isEntering ? "Enter Plan Mode" : "Exit Plan Mode")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)

          // Status badge
          Text(isEntering ? "Planning" : "Ready")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.8), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }

        Text(isEntering ? "Analyzing requirements..." : "Plan approved")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }

      Spacer()

      if !message.isInProgress {
        ToolCardDuration(duration: message.formattedDuration)
      }

      if message.isInProgress {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.mini)
          Text(isEntering ? "Entering..." : "Exiting...")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
        }
      } else if !output.isEmpty {
        ToolCardExpandButton(isExpanded: $isExpanded)
      }
    }
  }

  // MARK: - Expanded Content

  @ViewBuilder
  private var expandedContent: some View {
    if !output.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("DETAILS")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(.quaternary)
          .tracking(0.5)

        Text(output.count > 500 ? String(output.prefix(500)) + "..." : output)
          .font(.system(size: 11))
          .foregroundStyle(.primary.opacity(0.8))
          .textSelection(.enabled)
      }
      .padding(12)
    }
  }
}
