//
//  BashCard.swift
//  OrbitDock
//
//  Terminal-style command card with output
//

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

        HStack(spacing: Spacing.md_) {
          Image(systemName: "terminal")
            .font(.system(size: TypeScale.meta, weight: .semibold))
            .foregroundStyle(color)

          Text("$")
            .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
            .foregroundStyle(color)

          Text(message.bashCommand ?? message.content)
            .font(.system(size: TypeScale.meta, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.9))
            .lineLimit(isExpanded ? nil : 1)

          Spacer()

          // Status and duration
          if message.isInProgress {
            ProgressView()
              .controlSize(.mini)
          } else {
            HStack(spacing: Spacing.sm) {
              if hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.system(size: TypeScale.micro))
                  .foregroundStyle(.orange)
              }

              ToolCardDuration(duration: message.formattedDuration)

              if message.toolOutput != nil {
                ToolCardExpandButton(isExpanded: $isExpanded)
              }
            }
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
      }
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(hasError ? Color.feedbackWarning.opacity(isHovering ? 0.12 : 0.08) : color
            .opacity(isHovering ? 0.10 : 0.06))
      )
      .contentShape(Rectangle())
      .onTapGesture {
        if message.toolOutput != nil {
          withAnimation(Motion.snappy) {
            isExpanded.toggle()
          }
        }
      }
      .onHover { isHovering = $0 }

      // Output
      if isExpanded, let output = message.sanitizedToolOutput, !output.isEmpty {
        VStack(spacing: 0) {
          Color.surfaceBorder.frame(height: 1)

          ScrollView {
            Text(output.count > 2_000 ? String(output.prefix(2_000)) + "\n[...]" : output)
              .font(.system(size: TypeScale.micro, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.8))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 180)
          .padding(Spacing.md_)
        }
        .background(Color.backgroundCode)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .padding(.top, Spacing.sm_)
        .padding(.leading, Spacing.lg)
        .transition(.opacity)
      }
    }
  }
}
