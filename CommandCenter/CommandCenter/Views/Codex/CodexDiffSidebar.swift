//
//  CodexDiffSidebar.swift
//  OrbitDock
//
//  Right sidebar showing aggregated diff for Codex session.
//  Uses same visual style as EditCard for consistency.
//

import SwiftUI

struct CodexDiffSidebar: View {
  let diff: String
  let onClose: () -> Void

  // Match EditCard colors
  private let addedBg = Color(red: 0.15, green: 0.32, blue: 0.18).opacity(0.6)
  private let removedBg = Color(red: 0.35, green: 0.14, blue: 0.14).opacity(0.6)
  private let addedAccent = Color(red: 0.4, green: 0.95, blue: 0.5)
  private let removedAccent = Color(red: 1.0, green: 0.5, blue: 0.5)

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Image(systemName: "doc.badge.plus")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.toolWrite)

        Text("Changes")
          .font(.system(size: 13, weight: .semibold))

        Spacer()

        // Stats
        HStack(spacing: 8) {
          Text("+\(additionCount)")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(addedAccent)
          Text("−\(deletionCount)")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(removedAccent)
        }

        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 24, height: 24)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(Color.backgroundSecondary)

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Diff content
      ScrollView([.vertical, .horizontal], showsIndicators: true) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(parsedLines) { line in
            SidebarDiffLine(
              line: line,
              addedBg: addedBg,
              removedBg: removedBg,
              addedAccent: addedAccent,
              removedAccent: removedAccent
            )
          }
        }
        .padding(.vertical, 4)
      }
      .background(Color.backgroundPrimary)
    }
    .background(Color.backgroundSecondary)
  }

  private var parsedLines: [CodexParsedDiffLine] {
    diff.components(separatedBy: "\n").map { line in
      if line.hasPrefix("+++") || line.hasPrefix("---") {
        CodexParsedDiffLine(text: line, type: .header)
      } else if line.hasPrefix("@@") {
        CodexParsedDiffLine(text: line, type: .hunk)
      } else if line.hasPrefix("+") {
        CodexParsedDiffLine(text: line, type: .addition)
      } else if line.hasPrefix("-") {
        CodexParsedDiffLine(text: line, type: .deletion)
      } else {
        CodexParsedDiffLine(text: line, type: .context)
      }
    }
  }

  private var additionCount: Int {
    parsedLines.filter { $0.type == .addition }.count
  }

  private var deletionCount: Int {
    parsedLines.filter { $0.type == .deletion }.count
  }
}

struct SidebarDiffLine: View {
  let line: CodexParsedDiffLine
  let addedBg: Color
  let removedBg: Color
  let addedAccent: Color
  let removedAccent: Color

  var body: some View {
    HStack(spacing: 0) {
      // Line prefix indicator
      Text(prefix)
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundStyle(prefixColor)
        .frame(width: 16)

      // Line content
      Text(lineContent)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(textColor)
        .lineLimit(1)
        .textSelection(.enabled)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(backgroundColor)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var prefix: String {
    switch line.type {
      case .addition: "+"
      case .deletion: "−"
      case .hunk: "@"
      default: " "
    }
  }

  private var lineContent: String {
    switch line.type {
      case .addition, .deletion:
        String(line.text.dropFirst())
      default:
        line.text
    }
  }

  private var prefixColor: Color {
    switch line.type {
      case .addition: addedAccent
      case .deletion: removedAccent
      case .hunk: Color.accent
      default: .clear
    }
  }

  private var textColor: Color {
    switch line.type {
      case .header: .secondary
      case .hunk: Color.accent
      case .addition: addedAccent
      case .deletion: removedAccent
      case .context: .primary.opacity(0.7)
    }
  }

  private var backgroundColor: Color {
    switch line.type {
      case .addition: addedBg
      case .deletion: removedBg
      case .hunk: Color.accent.opacity(0.05)
      default: .clear
    }
  }
}

// MARK: - Parsed Diff Line

struct CodexParsedDiffLine: Identifiable {
  let id = UUID()
  let text: String
  let type: LineType

  enum LineType {
    case header
    case hunk
    case addition
    case deletion
    case context
  }
}

#Preview {
  CodexDiffSidebar(
    diff: """
    diff --git a/src/components/Button.tsx b/src/components/Button.tsx
    --- a/src/components/Button.tsx
    +++ b/src/components/Button.tsx
    @@ -10,7 +10,12 @@ export function Button({ children, onClick }: Props) {
       return (
         <button
           className="btn"
    -      onClick={onClick}
    +      onClick={(e) => {
    +        e.preventDefault();
    +        onClick();
    +      }}
         >
           {children}
         </button>
    """,
    onClose: {}
  )
  .frame(width: 350, height: 400)
  .background(Color.backgroundPrimary)
}
