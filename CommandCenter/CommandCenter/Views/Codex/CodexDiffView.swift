//
//  CodexDiffView.swift
//  OrbitDock
//
//  Displays aggregated unified diff for current Codex turn
//

import SwiftUI

struct CodexDiffView: View {
  let diff: String
  @State private var isExpanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .foregroundStyle(.tertiary)

          Image(systemName: "doc.badge.plus")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accent)

          Text("Changes")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)

          Spacer()

          // Stats
          HStack(spacing: 12) {
            HStack(spacing: 3) {
              Text("+\(additionCount)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.green)
            }
            HStack(spacing: 3) {
              Text("-\(deletionCount)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.red)
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.surfaceHover)
      }
      .buttonStyle(.plain)

      // Diff content
      if isExpanded {
        ScrollView(.horizontal, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parsedLines.enumerated()), id: \.offset) { _, line in
              CodexDiffLineView(line: line)
            }
          }
          .padding(.vertical, 8)
        }
        .background(Color.backgroundPrimary.opacity(0.5))
      }
    }
    .background(Color.backgroundSecondary)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var parsedLines: [CodexParsedDiffLine] {
    diff.components(separatedBy: "\n").map { line in
      if line.hasPrefix("+++") || line.hasPrefix("---") {
        return CodexParsedDiffLine(text: line, type: .header)
      } else if line.hasPrefix("@@") {
        return CodexParsedDiffLine(text: line, type: .hunk)
      } else if line.hasPrefix("+") {
        return CodexParsedDiffLine(text: line, type: .addition)
      } else if line.hasPrefix("-") {
        return CodexParsedDiffLine(text: line, type: .deletion)
      } else {
        return CodexParsedDiffLine(text: line, type: .context)
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

struct CodexDiffLineView: View {
  let line: CodexParsedDiffLine

  var body: some View {
    HStack(spacing: 0) {
      // Line prefix indicator
      Text(prefix)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(prefixColor)
        .frame(width: 20, alignment: .center)

      // Line content
      Text(lineContent)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(textColor)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 1)
    .background(backgroundColor)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var prefix: String {
    switch line.type {
    case .addition: return "+"
    case .deletion: return "-"
    case .hunk: return "@@"
    default: return " "
    }
  }

  private var lineContent: String {
    switch line.type {
    case .addition, .deletion:
      return String(line.text.dropFirst())
    default:
      return line.text
    }
  }

  private var prefixColor: Color {
    switch line.type {
    case .addition: return .green
    case .deletion: return .red
    case .hunk: return .cyan
    default: return .clear
    }
  }

  private var textColor: Color {
    switch line.type {
    case .header: return .secondary
    case .hunk: return .cyan
    case .addition: return .green
    case .deletion: return .red
    case .context: return .primary.opacity(0.7)
    }
  }

  private var backgroundColor: Color {
    switch line.type {
    case .addition: return .green.opacity(0.1)
    case .deletion: return .red.opacity(0.1)
    case .hunk: return .cyan.opacity(0.05)
    default: return .clear
    }
  }
}

#Preview {
  CodexDiffView(diff: """
--- a/src/components/Button.tsx
+++ b/src/components/Button.tsx
@@ -10,7 +10,9 @@ export function Button({ children, onClick }: Props) {
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
""")
  .frame(width: 600)
  .padding()
  .background(Color.backgroundPrimary)
}
