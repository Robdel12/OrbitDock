import SwiftUI

struct CodexCapabilityNotice: Equatable {
  enum Style: Equatable {
    case informational
    case success
    case caution
  }

  let title: String
  let message: String
  let badge: String
  let iconName: String
  let style: Style
}

enum CodexCapabilityNoticePlanner {
  static func notice(codexAccountStatus: ServerCodexAccountStatus?) -> CodexCapabilityNotice? {
    switch codexAccountStatus?.account {
      case .apiKey?:
        return CodexCapabilityNotice(
          title: "API Key Session",
          message: "Some Codex app-backed MCP servers only show up with ChatGPT sign-in. If a capability feels missing, check your Codex account mode first.",
          badge: "API Key",
          iconName: "key.fill",
          style: .caution
        )
      case .chatgpt?:
        return CodexCapabilityNotice(
          title: "ChatGPT Connected",
          message: "This session is using your ChatGPT-linked Codex account, so app-backed MCP availability should match what Codex can access.",
          badge: "ChatGPT",
          iconName: "sparkles",
          style: .success
        )
      case .none:
        guard codexAccountStatus?.requiresOpenaiAuth == true else { return nil }
        return CodexCapabilityNotice(
          title: "ChatGPT Sign-In Needed",
          message: "Sign in with ChatGPT to unlock Codex-managed apps and MCP servers in OrbitDock.",
          badge: "Not Connected",
          iconName: "person.crop.circle.badge.exclamationmark",
          style: .informational
        )
    }
  }
}

struct CodexCapabilityNoticeCard: View {
  let notice: CodexCapabilityNotice

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      ZStack {
        Circle()
          .fill(tint.opacity(0.16))
          .frame(width: 28, height: 28)

        Image(systemName: notice.iconName)
          .font(.system(size: TypeScale.meta, weight: .semibold))
          .foregroundStyle(tint)
      }

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.xs) {
          Text(notice.title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(notice.badge)
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(tint.opacity(0.14), in: Capsule())
        }

        Text(notice.message)
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.72))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(tint.opacity(0.18), lineWidth: 1)
    )
  }

  private var tint: Color {
    switch notice.style {
      case .informational:
        .accent
      case .success:
        .feedbackPositive
      case .caution:
        .feedbackCaution
    }
  }
}
