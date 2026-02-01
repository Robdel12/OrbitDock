//
//  BashCard.swift
//  OrbitDock
//
//  Terminal-style command card with output
//

import AppKit
import SwiftUI

struct BashCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool
  @Binding var isHovering: Bool

  private var color: Color {
    ToolCardStyle.color(for: message.toolName)
  }

  private var hasError: Bool {
    message.bashHasError
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      HStack(spacing: 0) {
        Rectangle()
          .fill(hasError ? .orange : color)
          .frame(width: 3)

        HStack(spacing: 10) {
          Image(systemName: "terminal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)

          Text("$")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(color)

          Text(message.content)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.9))
            .lineLimit(isExpanded ? nil : 1)

          Spacer()

          // Status and duration
          if message.isInProgress {
            ProgressView()
              .controlSize(.mini)
          } else {
            HStack(spacing: 8) {
              if hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.system(size: 10))
                  .foregroundStyle(.orange)
              }

              ToolCardDuration(duration: message.formattedDuration)

              if message.toolOutput != nil {
                ToolCardExpandButton(isExpanded: $isExpanded)
              }
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(hasError ? Color.orange.opacity(isHovering ? 0.12 : 0.08) : color.opacity(isHovering ? 0.10 : 0.06))
      )
      .contentShape(Rectangle())
      .onTapGesture {
        if message.toolOutput != nil {
          withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
            isExpanded.toggle()
          }
        }
      }
      .onHover { isHovering = $0 }

      // Output
      if isExpanded, let output = message.toolOutput, !output.isEmpty {
        ScrollView {
          Text(output.count > 2_000 ? String(output.prefix(2_000)) + "\n[...]" : output)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.8))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
        .padding(10)
        .background(Color.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.top, 6)
        .padding(.leading, 16)
        .transition(.opacity)
      }
    }
  }
}
