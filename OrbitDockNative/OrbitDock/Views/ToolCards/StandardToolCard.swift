//
//  StandardToolCard.swift
//  OrbitDock
//
//  Generic tool card for WebFetch, WebSearch, and other tools
//

import SwiftUI

struct StandardToolCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool
  @Binding var isHovering: Bool

  private var color: Color {
    ToolCardStyle.color(for: message.toolName)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      HStack(spacing: 0) {
        Rectangle()
          .fill(color)
          .frame(width: EdgeBar.width)
          .padding(.vertical, Spacing.xs)

        HStack(spacing: Spacing.md_) {
          Image(systemName: ToolCardStyle.icon(for: message.toolName))
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 16)

          Text(message.toolName ?? "Tool")
            .font(.system(size: TypeScale.meta, weight: .semibold))
            .foregroundStyle(color)

          if message.isInProgress {
            ProgressView()
              .controlSize(.mini)
          }

          Text(message.formattedToolInput ?? message.content)
            .font(.system(size: TypeScale.meta, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)

          Spacer()

          // Stats
          if !message.isInProgress {
            HStack(spacing: Spacing.sm) {
              ToolCardDuration(duration: message.formattedDuration)
            }
          }

          if message.toolInput != nil || message.toolOutput != nil {
            ToolCardExpandButton(isExpanded: $isExpanded)
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
      }
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(isHovering ? Color.surfaceHover : Color.clear)
      )
      .contentShape(Rectangle())
      .onTapGesture {
        if message.toolInput != nil || message.toolOutput != nil {
          withAnimation(Motion.snappy) {
            isExpanded.toggle()
          }
        }
      }
      .onHover { isHovering = $0 }

      // Expanded content
      if isExpanded {
        expandedContent
          .padding(.leading, 28)
          .padding(.top, Spacing.sm)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  // MARK: - Expanded Content

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = message.formattedToolInput {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("INPUT")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)
            .tracking(0.5)

          ScrollView(.horizontal, showsIndicators: false) {
            Text(input)
              .font(.system(size: TypeScale.meta, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.9))
              .textSelection(.enabled)
          }
          .padding(Spacing.md_)
          .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .fill(Color.backgroundTertiary)
          )
        }
      }

      if let output = message.sanitizedToolOutput, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("OUTPUT")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)
            .tracking(0.5)

          ScrollView {
            Text(output.count > 1_500 ? String(output.prefix(1_500)) + "\n[...]" : output)
              .font(.system(size: TypeScale.meta, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.8))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 150)
          .padding(Spacing.md_)
          .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .fill(Color.backgroundTertiary)
          )
        }
      }

      if let path = message.filePath {
        Button {
          _ = Platform.services.revealInFileBrowser(path)
        } label: {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "doc")
              .font(.system(size: TypeScale.mini))
            Text(path.components(separatedBy: "/").suffix(3).joined(separator: "/"))
              .font(.system(size: TypeScale.micro, design: .monospaced))
          }
          .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
  }
}
