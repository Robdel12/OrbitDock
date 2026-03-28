import SwiftUI

/// Compact terminal presence strip that sits below the conversation timeline,
/// stacking visually with the orbit status indicator.
///
/// Shows the active terminal session with a live title and tap-to-expand
/// affordance. On iOS, tapping opens the full-screen interactive terminal.
/// On macOS, tapping expands the inline terminal panel.
struct TerminalLiveStrip: View {
  let session: TerminalSessionController
  let onTap: () -> Void

  @Environment(\.horizontalSizeClass) private var sizeClass

  private var isConnecting: Bool {
    !session.isConnected && session.title == "Terminal"
  }

  /// Shorten the terminal title for display — show last path component
  /// with a tilde for home, e.g. "~/Developer/OrbitDock" → "~/OrbitDock"
  private var displayTitle: String {
    let title = session.title
    // If the shell gives us a path-like title, abbreviate it
    if title.contains("/") {
      let path = title.replacingOccurrences(of: "^~", with: NSHomeDirectory(), options: .regularExpression)
      let home = NSHomeDirectory()
      let shortened = path.hasPrefix(home)
        ? "~/" + (path.dropFirst(home.count + 1).split(separator: "/").last.map(String.init) ?? "")
        : String(title.split(separator: "/").last ?? Substring(title))
      return shortened.isEmpty ? title : shortened
    }
    return title
  }

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: Spacing.xs) {
        // Shell prompt indicator
        Text("❯")
          .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.terminal)

        if isConnecting {
          Text("Connecting")
            .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textTertiary)

          ProgressView()
            .controlSize(.mini)
            .tint(Color.textQuaternary)
        } else {
          // Live state — show terminal title (shell cwd)
          Text(displayTitle)
            .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        // Expand indicator
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(Color.textQuaternary)
          .frame(width: 20, height: 20)
          .background(Color.terminal.opacity(OpacityTier.subtle), in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.sm_)
      .background(Color.backgroundCode.opacity(0.6))
      .overlay(alignment: .top) {
        Color.surfaceBorder.opacity(0.3)
          .frame(height: 0.5)
      }
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
      session: {
        let s = TerminalSessionController(terminalId: "preview")
        return s
      }(),
      onTap: {}
    )
  }
  .background(Color.backgroundPrimary)
  .frame(width: 400)
}
