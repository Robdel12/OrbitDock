//
//  StandardToolCard.swift
//  OrbitDock
//
//  Generic tool card for WebFetch, WebSearch, and other tools
//

import AppKit
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
          .frame(width: 2)
          .padding(.vertical, 4)

        HStack(spacing: 10) {
          Image(systemName: ToolCardStyle.icon(for: message.toolName))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 16)

          Text(message.toolName ?? "Tool")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)

          if message.isInProgress {
            ProgressView()
              .controlSize(.mini)
          }

          Text(message.formattedToolInput ?? message.content)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)

          Spacer()

          // Stats
          if !message.isInProgress {
            HStack(spacing: 8) {
              ToolCardDuration(duration: message.formattedDuration)
            }
          }

          if message.toolInput != nil || message.toolOutput != nil {
            ToolCardExpandButton(isExpanded: $isExpanded)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(isHovering ? Color.surfaceHover : Color.clear)
      )
      .contentShape(Rectangle())
      .onTapGesture {
        if message.toolInput != nil || message.toolOutput != nil {
          withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
            isExpanded.toggle()
          }
        }
      }
      .onHover { isHovering = $0 }

      // Expanded content
      if isExpanded {
        expandedContent
          .padding(.leading, 28)
          .padding(.top, 8)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  // MARK: - Expanded Content

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let input = message.formattedToolInput {
        VStack(alignment: .leading, spacing: 4) {
          Text("INPUT")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.quaternary)
            .tracking(0.5)

          ScrollView(.horizontal, showsIndicators: false) {
            Text(input)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.9))
              .textSelection(.enabled)
          }
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color.backgroundTertiary)
          )
        }
      }

      if let output = message.sanitizedToolOutput, !output.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("OUTPUT")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.quaternary)
            .tracking(0.5)

          ScrollView {
            Text(output.count > 1_500 ? String(output.prefix(1_500)) + "\n[...]" : output)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.8))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 150)
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color.backgroundTertiary)
          )
        }
      }

      if let path = message.filePath {
        Button {
          NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "doc")
              .font(.system(size: 9))
            Text(path.components(separatedBy: "/").suffix(3).joined(separator: "/"))
              .font(.system(size: 10, design: .monospaced))
          }
          .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
  }
}
