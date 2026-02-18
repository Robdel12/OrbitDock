//
//  SkillCard.swift
//  OrbitDock
//
//  Shows skill/slash command invocations
//

import SwiftUI

struct SkillCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool

  private var color: Color {
    Color(red: 0.85, green: 0.5, blue: 0.85)
  } // Pink/magenta

  private var skillName: String {
    (message.toolInput?["skill"] as? String) ?? "skill"
  }

  private var args: String {
    (message.toolInput?["args"] as? String) ?? ""
  }

  private var output: String {
    message.toolOutput ?? ""
  }

  var body: some View {
    ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: !args.isEmpty || !output.isEmpty) {
      header
    } content: {
      expandedContent
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "sparkles")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(color)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text("/\(skillName)")
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
        }

        if !args.isEmpty {
          Text(args.count > 60 ? String(args.prefix(60)) + "..." : args)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      if !message.isInProgress {
        ToolCardDuration(duration: message.formattedDuration)
      }

      if message.isInProgress {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.mini)
          Text("Running...")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
        }
      } else if !output.isEmpty {
        ToolCardExpandButton(isExpanded: $isExpanded)
      }
    }
  }

  // MARK: - Expanded Content

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Args
      if !args.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("ARGUMENTS")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.quaternary)
            .tracking(0.5)

          Text(args)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.9))
            .textSelection(.enabled)
        }
        .padding(12)
      }

      // Output
      if !output.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("OUTPUT")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.quaternary)
            .tracking(0.5)

          ScrollView {
            Text(output.count > 1_000 ? String(output.prefix(1_000)) + "\n[...]" : output)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.8))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 150)
        }
        .padding(12)
        .background(Color.backgroundTertiary.opacity(0.5))
      }
    }
  }
}
