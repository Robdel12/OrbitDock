import SwiftUI

struct NewSessionProviderPicker: View {
  let provider: SessionProvider
  let onSelect: (SessionProvider) -> Void

  var body: some View {
    HStack(spacing: Spacing.sm) {
      ForEach(SessionProvider.allCases) { option in
        let isSelected = provider == option
        Button {
          onSelect(option)
        } label: {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: option.icon)
              .font(.system(size: 11, weight: .semibold))
            Text(option.displayName)
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .foregroundStyle(isSelected ? Color.backgroundPrimary : option.color)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm_)
          .background(
            Capsule()
              .fill(isSelected ? option.color : option.color.opacity(OpacityTier.light))
          )
          .overlay(
            Capsule()
              .stroke(option.color.opacity(isSelected ? 0 : OpacityTier.light), lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
      }

      Spacer()
    }
  }
}

struct NewSessionHeader: View {
  let provider: SessionProvider
  let codexAccount: ServerCodexAccount?
  let onDismiss: () -> Void

  var body: some View {
    #if os(iOS)
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
          headerIcon

          Text("New Session")
            .font(.system(size: TypeScale.large, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.9)

          Spacer(minLength: Spacing.sm)

          if provider == .codex, let codexAccount {
            NewSessionConnectedBadge(account: codexAccount)
          }

          closeButton
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)
    #else
      HStack(spacing: Spacing.sm) {
        headerIcon

        Text("New Session")
          .font(.system(size: TypeScale.subhead, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        Spacer()

        if provider == .codex, let codexAccount {
          NewSessionConnectedBadge(account: codexAccount)
        }

        closeButton
      }
      .padding(.horizontal, Spacing.xl)
      .padding(.vertical, Spacing.md)
    #endif
  }

  private var headerIcon: some View {
    ZStack {
      Circle()
        .fill(provider.color.opacity(OpacityTier.light))
        .frame(width: 28, height: 28)

      Circle()
        .stroke(provider.color.opacity(OpacityTier.medium), lineWidth: 1)
        .frame(width: 28, height: 28)

      Image(systemName: "plus")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(provider.color)
    }
    .shadow(color: provider.color.opacity(0.25), radius: 8, y: 0)
    .animation(Motion.standard, value: provider)
  }

  private var closeButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 24, height: 24)
        .background(Color.backgroundTertiary, in: Circle())
        .overlay(
          Circle()
            .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    #if !os(iOS)
      .onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    #endif
  }
}

struct NewSessionConnectedBadge: View {
  let account: ServerCodexAccount

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Circle()
        .fill(Color.feedbackPositive)
        .frame(width: 6, height: 6)
        .shadow(color: Color.feedbackPositive.opacity(0.45), radius: 4, y: 0)

      switch account {
        case .apiKey:
          Text("API Key Connected")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textSecondary)

        case let .chatgpt(email, planType):
          if let email {
            Text(email)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(1)
          }

          if let planType {
            Text(planType.uppercased())
              .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
              .foregroundStyle(Color.providerCodex)
              .padding(.horizontal, Spacing.sm_)
              .padding(.vertical, Spacing.gap)
              .background(Color.providerCodex.opacity(OpacityTier.light), in: Capsule())
              .overlay(
                Capsule()
                  .stroke(Color.providerCodex.opacity(OpacityTier.medium), lineWidth: 1)
              )
          }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundTertiary, in: Capsule())
    .overlay(
      Capsule()
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }
}

struct NewSessionContinuationSection: View {
  let continuation: SessionContinuation
  let supportsContinuation: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "arrow.right.circle.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.accent)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Continue From \(continuation.displayName)")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(continuation.sourceSummary)
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textTertiary)

          Text(
            "This starts a fresh session, then asks the new agent to inspect session `\(continuation.sessionId)` with the OrbitDock CLI for context."
          )
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      if !supportsContinuation {
        Text(
          "Continue from session is limited to the same local OrbitDock server for now. Switch back to the source endpoint or use the normal new-session flow."
        )
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.statusPermission)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(Spacing.lg)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }
}

struct NewSessionAuthGateSection: View {
  let loginInProgress: Bool
  let authError: String?
  let onStartLogin: () -> Void
  let onCancelLogin: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 11))
          .foregroundStyle(Color.statusPermission)

        Text("Connect your ChatGPT account to create sessions")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)
      }

      HStack(spacing: Spacing.sm) {
        if loginInProgress {
          Button(action: onCancelLogin) {
            Label("Cancel", systemImage: "xmark.circle")
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .buttonStyle(.bordered)

          HStack(spacing: Spacing.sm) {
            ProgressView()
              .controlSize(.small)
            Text("Waiting for browser…")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          }
        } else {
          Button(action: onStartLogin) {
            Label("Sign in with ChatGPT", systemImage: "sparkles")
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.accent)
        }
      }

      if let authError, !authError.isEmpty {
        Text(authError)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.statusPermission)
      }
    }
    .padding(Spacing.lg)
    .background(
      Color.statusPermission.opacity(OpacityTier.tint),
      in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.statusPermission.opacity(OpacityTier.light), lineWidth: 1)
    )
  }
}

struct NewSessionToolRestrictionsCard: View {
  @Binding var showToolConfig: Bool
  @Binding var allowedToolsText: String
  @Binding var disallowedToolsText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(Motion.bouncy) {
          showToolConfig.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Circle()
            .fill(Color.textQuaternary.opacity(OpacityTier.light))
            .frame(width: 20, height: 20)
            .overlay(
              Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
            )

          Text("Tool Restrictions")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          Text("OPTIONAL")
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.textTertiary.opacity(OpacityTier.light), in: Capsule())

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(showToolConfig ? 90 : 0))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      #if !os(iOS)
        .onHover { hovering in
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }
      #endif

      if showToolConfig {
        Divider()
          .padding(.horizontal, Spacing.lg)

        VStack(alignment: .leading, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
              Text("Allowed Tools")
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
              Text("•")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
              Text("Comma-separated list")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textTertiary)
            }
            TextField("e.g. Read, Glob, Bash(git:*)", text: $allowedToolsText)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.caption, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
              Text("Disallowed Tools")
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
              Text("•")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
              Text("Comma-separated list")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textTertiary)
            }
            TextField("e.g. Write, Edit", text: $disallowedToolsText)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.caption, design: .monospaced))
          }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }
}

struct NewSessionFooter: View {
  let provider: SessionProvider
  let codexAccount: ServerCodexAccount?
  let isCreating: Bool
  let canCreateSession: Bool
  let onSignOut: () -> Void
  let onCancel: () -> Void
  let onLaunch: () -> Void

  var body: some View {
    #if os(iOS)
      VStack(alignment: .leading, spacing: Spacing.md) {
        if provider == .codex, codexAccount != nil {
          signOutButton
        }

        HStack(spacing: Spacing.sm) {
          cancelButton
            .frame(maxWidth: .infinity)
          launchButton
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.top, Spacing.md)
      .padding(.bottom, Spacing.lg)
    #else
      HStack(spacing: Spacing.md) {
        if provider == .codex, codexAccount != nil {
          signOutButton
        }

        Spacer()

        cancelButton
        launchButton
      }
      .padding(.horizontal, Spacing.xl)
      .padding(.vertical, Spacing.md)
    #endif
  }

  private var signOutButton: some View {
    Button(action: onSignOut) {
      Text("Sign Out")
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm_)
        .background(Color.backgroundTertiary, in: Capsule())
        .overlay(
          Capsule()
            .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    #if !os(iOS)
      .onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    #endif
  }

  private var cancelButton: some View {
    Button("Cancel", action: onCancel)
      .buttonStyle(.bordered)
      .tint(Color.textTertiary)
    #if os(iOS)
      .controlSize(.large)
    #else
      .keyboardShortcut(.escape, modifiers: [])
    #endif
  }

  private var launchButton: some View {
    Button(action: onLaunch) {
      if isCreating {
        HStack(spacing: Spacing.sm) {
          ProgressView()
            .controlSize(.small)
          Text("Launch")
            .font(.system(size: TypeScale.body, weight: .semibold))
        }
        .frame(minWidth: 90)
      } else {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "paperplane.fill")
            .font(.system(size: 12, weight: .semibold))
          Text("Launch")
            .font(.system(size: TypeScale.body, weight: .semibold))
        }
        .frame(minWidth: 90)
      }
    }
    .buttonStyle(.borderedProminent)
    .tint(provider.color)
    .disabled(!canCreateSession)
    #if os(iOS)
      .controlSize(.large)
    #else
      .keyboardShortcut(.return, modifiers: .command)
    #endif
  }
}

struct NewSessionErrorBanner: View {
  let message: String

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 11))
        .foregroundStyle(Color.statusPermission)
      Text(message)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
    }
    .padding(Spacing.md)
    .background(Color.statusPermission.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md))
  }
}
