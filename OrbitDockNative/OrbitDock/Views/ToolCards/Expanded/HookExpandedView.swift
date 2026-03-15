//
//  HookExpandedView.swift
//  OrbitDock
//
//  Structured field display for hook notifications.
//

import SwiftUI

struct HookExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow

  private var hookInfo: (name: String?, event: String?, phase: String?) {
    guard let dict = toolRow.invocation.value as? [String: Any] else {
      return (nil, nil, nil)
    }
    return (
      name: dict["hook_name"] as? String ?? dict["name"] as? String,
      event: dict["event"] as? String ?? dict["hook_event"] as? String,
      phase: dict["phase"] as? String
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Structured fields
      let info = hookInfo
      if info.name != nil || info.event != nil || info.phase != nil {
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
    }
  }

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
