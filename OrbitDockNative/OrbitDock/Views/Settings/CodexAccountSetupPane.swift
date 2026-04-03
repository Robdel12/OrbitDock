import SwiftUI

struct CodexAccountSetupPane: View {
  let viewModel: CodexAccountSetupViewModel

  var body: some View {
    SettingsSection(title: "CODEX CLI", icon: "sparkles") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Spacing.sm) {
            accountHeaderLabel
            Spacer()
            codexAuthBadge
          }

          VStack(alignment: .leading, spacing: Spacing.sm_) {
            accountHeaderLabel
            codexAuthBadge
          }
        }

        switch viewModel.accountState {
          case .apiKey:
            Text("Connected with API key. Switch to ChatGPT sign-in for subscription-backed limits.")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
          case let .chatgpt(email, planType):
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

        ViewThatFits(in: .horizontal) {
          HStack(spacing: Spacing.md_) {
            accountActionButtons
            Spacer(minLength: 0)
          }

          VStack(alignment: .leading, spacing: Spacing.sm) {
            accountActionButtons
          }
        }

        if let error = viewModel.authError, !error.isEmpty {
          HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.statusPermission)
            Text(error)
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textSecondary)
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: Spacing.sm) {
          Text("Session Config")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(
            "OrbitDock always starts Codex sessions from the Codex config that applies to the selected folder, including your user config and any project-level `.codex` config."
          )
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)

          Text(
            "You can still add temporary per-session overrides from the New Session sheet without changing your Codex files."
          )
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @ViewBuilder
  private var codexAuthBadge: some View {
    if viewModel.isSigningIn {
      Label("Signing In", systemImage: "clock")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.statusWorking.opacity(0.18), in: Capsule())
        .foregroundStyle(Color.statusWorking)
    } else if !viewModel.hasConnectedAccount {
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

  private var accountHeaderLabel: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: viewModel.accountHeaderIconName)
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(viewModel.accountHeaderIconColor)
      Text("Account")
        .font(.system(size: TypeScale.body, weight: .semibold))
    }
  }

  @ViewBuilder
  private var accountActionButtons: some View {
    if viewModel.isSigningIn {
      Button {
        viewModel.cancelLogin()
      } label: {
        Label("Cancel Sign-In", systemImage: "xmark.circle")
          .font(.system(size: TypeScale.caption, weight: .semibold))
      }
      .buttonStyle(.bordered)
    } else if !viewModel.hasConnectedAccount {
      Button {
        viewModel.startLogin()
      } label: {
        Label("Sign in with ChatGPT", systemImage: "sparkles")
          .font(.system(size: TypeScale.caption, weight: .semibold))
      }
      .buttonStyle(.borderedProminent)
      .tint(Color.accent)
    }

    if viewModel.hasConnectedAccount {
      Button("Usage") {
        viewModel.openUsagePage()
      }
      .font(.system(size: TypeScale.caption, weight: .semibold))
      .buttonStyle(.bordered)

      Button("Sign Out") {
        viewModel.logout()
      }
      .font(.system(size: TypeScale.caption, weight: .semibold))
      .buttonStyle(.bordered)
    }
  }
}
