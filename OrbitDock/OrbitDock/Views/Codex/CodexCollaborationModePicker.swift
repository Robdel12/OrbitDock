import SwiftUI

enum CodexCollaborationMode: String, CaseIterable, Identifiable {
  case `default`
  case plan

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
      case .default: "Default"
      case .plan: "Plan"
    }
  }

  var icon: String {
    switch self {
      case .default: "chevron.left.forwardslash.chevron.right"
      case .plan: "map.fill"
    }
  }

  var color: Color {
    switch self {
      case .default: .providerCodex
      case .plan: .statusQuestion
    }
  }

  var permissionMode: ClaudePermissionMode {
    switch self {
      case .default: .default
      case .plan: .plan
    }
  }

  static func from(permissionMode: ClaudePermissionMode) -> CodexCollaborationMode {
    permissionMode == .plan ? .plan : .default
  }
}

struct CodexModePill: View {
  enum PillSize {
    case regular
    case statusBar

    var iconFontSize: CGFloat {
      self == .statusBar ? 9 : TypeScale.body
    }

    var textFontSize: CGFloat {
      self == .statusBar ? 10 : TypeScale.body
    }

    var horizontalPadding: CGFloat {
      self == .statusBar ? 6 : CGFloat(Spacing.md)
    }

    var verticalPadding: CGFloat {
      self == .statusBar ? 3 : CGFloat(Spacing.sm)
    }

    var spacing: CGFloat {
      self == .statusBar ? 3 : CGFloat(Spacing.xs)
    }

    var height: CGFloat? {
      self == .statusBar ? 20 : nil
    }
  }

  let sessionId: String
  var size: PillSize = .regular
  @Environment(ServerAppState.self) private var serverState
  @State private var showPopover = false

  private var currentMode: CodexCollaborationMode {
    CodexCollaborationMode.from(permissionMode: serverState.session(sessionId).permissionMode)
  }

  var body: some View {
    Button {
      showPopover.toggle()
    } label: {
      HStack(spacing: size.spacing) {
        Image(systemName: currentMode.icon)
          .font(.system(size: size.iconFontSize, weight: .semibold))
        Text(currentMode.displayName)
          .font(.system(size: size.textFontSize, weight: .semibold))
      }
      .foregroundStyle(currentMode.color)
      .padding(.horizontal, size.horizontalPadding)
      .padding(.vertical, size.verticalPadding)
      .frame(height: size.height)
      .background(currentMode.color.opacity(OpacityTier.light), in: Capsule())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .platformPopover(isPresented: $showPopover) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Codex Mode")
          .font(.system(size: TypeScale.subhead, weight: .semibold))

        ForEach(CodexCollaborationMode.allCases) { mode in
          Button {
            serverState.updateCodexCollaborationMode(sessionId: sessionId, mode: mode)
            showPopover = false
          } label: {
            HStack(spacing: 8) {
              Image(systemName: mode.icon)
              Text(mode.displayName)
              Spacer()
              if mode == currentMode {
                Image(systemName: "checkmark")
              }
            }
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color.textPrimary)
          .padding(.vertical, Spacing.xs)
        }
      }
      .padding(Spacing.lg)
      .ifMacOS { $0.frame(width: 220) }
      .background(Color.backgroundSecondary)
    }
  }
}
