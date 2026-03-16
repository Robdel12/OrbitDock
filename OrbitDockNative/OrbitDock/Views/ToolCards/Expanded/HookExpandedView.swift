//
//  HookExpandedView.swift
//  OrbitDock
//
//  Structured field display for hook notifications.
//  Features: duration field, structured entries with status icons.
//

import SwiftUI

struct HookExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow

  private var hookInfo: (name: String?, event: String?, phase: String?) {
    // Hook metadata is in toolDisplay subtitle (server formats as "hook_name — event")
    let subtitle = toolRow.toolDisplay.subtitle
    let parts = subtitle?.split(separator: " — ", maxSplits: 1).map(String.init)
    return (
      name: parts?.first,
      event: parts?.count ?? 0 > 1 ? parts?[1] : nil,
      phase: nil
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Structured fields
      let info = hookInfo
      if info.name != nil || info.event != nil || info.phase != nil || durationString != nil {
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          if let name = info.name {
            fieldRow(label: "Hook", value: name, icon: "link")
          }
          if let event = info.event {
            fieldRow(label: "Event", value: event, icon: "bolt")
          }
          if let phase = info.phase {
            fieldRow(label: "Phase", value: phase, icon: "clock")
          }
          if let dur = durationString {
            fieldRow(label: "Duration", value: dur, icon: "stopwatch")
          }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
      }

      if let input = content.inputDisplay, !input.isEmpty, hookInfo.name == nil {
        codeBlock(label: "Hook Event", text: input)
      }

      if let output = content.outputDisplay, !output.isEmpty {
        codeBlock(label: "Result", text: output)
      }

      // Structured entries (rendered from input display if present)
      if let input = content.inputDisplay, !input.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Details")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text(input)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
        }
      }
    }
  }

  // MARK: - Duration

  private var durationString: String? {
    toolRow.toolDisplay.rightMeta
  }

  // MARK: - Entry Helpers

  private func entryIcon(_ kind: String?) -> String {
    switch kind {
    case "pass", "success": return "checkmark.circle.fill"
    case "fail", "error": return "xmark.circle.fill"
    default: return "circle.fill"
    }
  }

  private func entryColor(_ kind: String?) -> Color {
    switch kind {
    case "pass", "success": return .feedbackPositive
    case "fail", "error": return .feedbackNegative
    default: return .textQuaternary
    }
  }

  // MARK: - Shared Components

  private func fieldRow(label: String, value: String, icon: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: IconScale.xs))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 14)
      Text(label)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 50, alignment: .trailing)
      Text(value)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
    }
  }

  private func codeBlock(label: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
      Text(text)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
  }
}
