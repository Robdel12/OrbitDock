import SwiftUI

struct CodexAccountSetupPane: View {
  @Environment(SessionStore.self) private var serverState

  var body: some View {
    SettingsSection(title: "CODEX CLI", icon: "sparkles") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
          Image(systemName: serverState
            .codexAccountStatus?.account == nil ? "person.crop.circle.badge.exclamationmark" :
            "person.crop.circle.badge.checkmark")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(serverState.codexAccountStatus?.account == nil ? Color.statusPermission : Color
              .feedbackPositive)
          Text("Account")
            .font(.system(size: TypeScale.body, weight: .semibold))
          Spacer()
          codexAuthBadge
        }

        switch serverState.codexAccountStatus?.account {
          case .apiKey?:
            Text("Connected with API key. Switch to ChatGPT sign-in for subscription-backed limits.")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
          case let .chatgpt(email, planType)?:
            VStack(alignment: .leading, spacing: Spacing.xs) {
              if let email {
                Text(email)
                  .font(.system(size: TypeScale.body, weight: .medium))
                  .foregroundStyle(.primary)
              } else {
                Text("Signed in with ChatGPT")
                  .font(.system(size: TypeScale.body, weight: .medium))
                  .foregroundStyle(.primary)
              }
              if let planType {
                Text(planType.uppercased())
                  .font(.system(size: TypeScale.meta, weight: .semibold, design: .rounded))
                  .foregroundStyle(Color.accent)
              }
            }
          case .none:
            Text("Sign in with ChatGPT to manage Codex sessions directly in OrbitDock.")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
        }

        HStack(spacing: Spacing.md_) {
          if serverState.codexAccountStatus?.loginInProgress == true {
            Button {
              serverState.cancelCodexChatgptLogin()
            } label: {
              Label("Cancel Sign-In", systemImage: "xmark.circle")
                .font(.system(size: TypeScale.caption, weight: .semibold))
            }
            .buttonStyle(.bordered)
          } else if serverState.codexAccountStatus?.account == nil {
            Button {
              serverState.startCodexChatgptLogin()
            } label: {
              Label("Sign in with ChatGPT", systemImage: "sparkles")
                .font(.system(size: TypeScale.caption, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
          }

          if serverState.codexAccountStatus?.account != nil {
            Button("Usage") {
              openCodexUsagePage()
            }
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .buttonStyle(.bordered)

            Button("Sign Out") {
              serverState.logoutCodexAccount()
            }
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .buttonStyle(.bordered)
          }

          Spacer()
        }

        if let error = serverState.codexAuthError, !error.isEmpty {
          HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.statusPermission)
            Text(error)
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textSecondary)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var codexAuthBadge: some View {
    if serverState.codexAccountStatus?.loginInProgress == true {
      Label("Signing In", systemImage: "clock")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.statusWorking.opacity(0.18), in: Capsule())
        .foregroundStyle(Color.statusWorking)
    } else if serverState.codexAccountStatus?.account == nil {
      Label("Not Connected", systemImage: "xmark")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.statusPermission.opacity(0.16), in: Capsule())
        .foregroundStyle(Color.statusPermission)
    } else {
      Label("Connected", systemImage: "checkmark")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.feedbackPositive.opacity(0.2), in: Capsule())
        .foregroundStyle(Color.feedbackPositive)
    }
  }

  private func openCodexUsagePage() {
    guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else { return }
    _ = Platform.services.openURL(url)
  }
}
