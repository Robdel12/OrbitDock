//
//  ReviewEmptyState.swift
//  OrbitDock
//
//  Empty state messaging for the review canvas when no diffs are available.
//

import SwiftUI

struct ReviewEmptyState: View {
  let isSessionActive: Bool

  var body: some View {
    VStack(spacing: Spacing.section) {
      // Icon with subtle glow
      ZStack {
        Circle()
          .fill(Color.accent.opacity(0.06))
          .frame(width: 72, height: 72)

        Circle()
          .fill(Color.accent.opacity(0.03))
          .frame(width: 56, height: 56)

        Image(systemName: isSessionActive ? "doc.text.magnifyingglass" : "checkmark.circle")
          .font(.system(size: 24, weight: .light))
          .foregroundStyle(Color.accent.opacity(0.5))
      }

      VStack(spacing: Spacing.sm_) {
        Text(isSessionActive ? "No Diffs Yet" : "No Changes")
          .font(.system(size: TypeScale.subhead, weight: .semibold))
          .foregroundStyle(.secondary)

        Text(isSessionActive
          ? "File changes will appear here as the agent edits code"
          : "This session ended without file changes")
          .font(.system(size: 11.5))
          .foregroundStyle(Color.textTertiary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 240)
      }

      if isSessionActive {
        // Keyboard shortcut hint
        HStack(spacing: Spacing.xs) {
          keyboardHint("n")
          Text("/")
            .foregroundStyle(Color.textTertiary)
          keyboardHint("p")
          Text("navigate hunks")
            .foregroundStyle(Color.textTertiary)
        }
        .font(.system(size: 9.5))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.backgroundPrimary)
  }

  private func keyboardHint(_ key: String) -> some View {
    Text(key)
      .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
      .foregroundStyle(Color.textTertiary)
      .padding(.horizontal, 5)
      .padding(.vertical, Spacing.xxs)
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .strokeBorder(Color.panelBorder, lineWidth: 1)
      )
  }
}
