import SwiftUI

/// Compact terminal presence strip that sits below the conversation timeline,
/// stacking visually with the orbit status indicator.
///
/// Shows the active terminal session with a live title and tap-to-expand
/// affordance. On iOS, tapping opens the full-screen interactive terminal.
/// On macOS, tapping expands the inline terminal panel.
struct TerminalLiveStrip: View {
  private enum Metrics {
    static let horizontalInset: CGFloat = Spacing.md
    static let iconColumnWidth: CGFloat = 12
  }

  enum ChromeStyle {
    case standalone
    case embedded
  }

  let session: TerminalSessionController
  let onTap: () -> Void
  var fallbackPath: String?
  var chromeStyle: ChromeStyle = .standalone

  @Environment(\.horizontalSizeClass) private var sizeClass

  private var isConnecting: Bool {
    !session.isConnected && session.title == "Terminal"
  }

  /// Shorten the terminal title for display — show last path component
  /// with a tilde for home, e.g. "~/Developer/OrbitDock" → "~/OrbitDock"
  private var displayTitle: String {
    let title = session.title
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == "Terminal" {
      return shortenedPath(fallbackPath) ?? title
    }
    // If the shell gives us a path-like title, abbreviate it
    if title.contains("/") {
      return shortenedPath(title) ?? title
    }
    return title
  }

  private var isCompact: Bool {
    sizeClass == .compact
  }

  private func shortenedPath(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let path = trimmed.replacingOccurrences(of: "^~", with: NSHomeDirectory(), options: .regularExpression)
    let home = NSHomeDirectory()
    if path.hasPrefix(home) {
      let suffix = String(path.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if suffix.isEmpty { return "~" }
      if let last = suffix.split(separator: "/").last {
        return "~/\(last)"
      }
      return "~"
    }

    if let last = path.split(separator: "/").last, !last.isEmpty {
      return String(last)
    }
    return trimmed
  }

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm_) {
        Image(systemName: "chevron.right")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.terminal)
          .frame(width: Metrics.iconColumnWidth, height: 16)

        if isConnecting {
          HStack(spacing: Spacing.xs) {
            Text("Terminal")
              .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
              .foregroundStyle(Color.textPrimary)

            Text("·")
              .font(.system(size: TypeScale.meta, weight: .medium))
              .foregroundStyle(Color.textQuaternary)

            Text("Connecting")
              .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textTertiary)

            ProgressView()
              .controlSize(.mini)
              .tint(Color.textQuaternary)
          }
        } else {
          HStack(spacing: Spacing.xs) {
            Text("Terminal")
              .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
              .foregroundStyle(Color.textPrimary)

            Text("·")
              .font(.system(size: TypeScale.meta, weight: .medium))
              .foregroundStyle(Color.textQuaternary)

            Text(displayTitle)
              .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)

        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.system(size: isCompact ? IconScale.xs : TypeScale.mini, weight: .semibold))
          .foregroundStyle(Color.textQuaternary)
          .frame(width: 18, height: 18)
      }
      .padding(.horizontal, Metrics.horizontalInset)
      .padding(.vertical, Spacing.xs)
      .background(
        chromeStyle == .standalone ? Color.backgroundCode.opacity(0.12) : Color.clear
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open terminal")
    .accessibilityHint("Opens the interactive terminal in full screen")
    .animation(Motion.gentle, value: isConnecting)
  }
}

#Preview {
  VStack(spacing: 0) {
    OrbitStatusIndicator(displayStatus: .reply)

    TerminalLiveStrip(
      session: TerminalSessionController(terminalId: "preview"),
      onTap: {}
    )
  }
  .background(Color.backgroundPrimary)
  .frame(width: 400)
}
