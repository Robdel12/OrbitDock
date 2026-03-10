//
//  SteerContextIndicator.swift
//  OrbitDock
//
//  Thin strip above input showing current input mode.
//

import SwiftUI

struct SteerContextIndicator: View {
  let mode: InputMode
  var onOverride: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      // Colored dot + mode label
      HStack(spacing: 6) {
        Circle()
          .fill(mode.color)
          .frame(width: 6, height: 6)

        Text(mode.label)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(mode.color)
      }

      Spacer()

      // Cancel link for review notes mode
      if mode == .reviewNotes, let onOverride {
        Button(action: onOverride) {
          Text("Cancel")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .frame(height: 24)
    .background(Color.backgroundTertiary)
  }
}

#Preview {
  VStack(spacing: 0) {
    SteerContextIndicator(mode: .prompt)
    SteerContextIndicator(mode: .steer)
    SteerContextIndicator(mode: .reviewNotes, onOverride: {})
  }
  .frame(width: 400)
  .background(Color.backgroundSecondary)
}
