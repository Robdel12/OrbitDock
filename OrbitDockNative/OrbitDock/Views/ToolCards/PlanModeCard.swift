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
    HStack(spacing: Spacing.md) {
      Image(systemName: isEntering ? "doc.text.magnifyingglass" : "checkmark.rectangle")
        .font(.system(size: TypeScale.subhead, weight: .medium))
        .foregroundStyle(color)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.sm) {
          Text(isEntering ? "Enter Plan Mode" : "Exit Plan Mode")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(color)

          // Status badge
          Text(isEntering ? "Planning" : "Ready")
            .font(.system(size: TypeScale.mini, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(color.opacity(0.8), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }

        Text(isEntering ? "Analyzing requirements..." : "Plan approved")
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(.secondary)
      }

      Spacer()

      if !message.isInProgress {
        ToolCardDuration(duration: message.formattedDuration)
      }

      if message.isInProgress {
        HStack(spacing: Spacing.sm_) {
          ProgressView()
            .controlSize(.mini)
          Text(isEntering ? "Entering..." : "Exiting...")
            .font(.system(size: TypeScale.meta, weight: .medium))
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
      VStack(alignment: .leading, spacing: Spacing.sm_) {
        Text("DETAILS")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textQuaternary)
          .tracking(0.5)

        Text(output.count > 500 ? String(output.prefix(500)) + "..." : output)
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(.primary.opacity(0.8))
          .textSelection(.enabled)
      }
      .padding(Spacing.md)
    }
  }
}
