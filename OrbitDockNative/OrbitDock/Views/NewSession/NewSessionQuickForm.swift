import SwiftUI

struct NewSessionQuickForm<
  ProviderToggle: View,
  EndpointSection: View,
  ContinuationSection: View,
  AuthGateSection: View,
  CodexCapabilityNotice: View,
  DirectorySection: View,
  OptionsPanel: View,
  ErrorBanner: View
>: View {
  let showOptions: Bool
  let onToggleOptions: () -> Void
  let shouldShowEndpointSection: Bool
  let continuation: SessionContinuation?
  let isCodexProvider: Bool
  let shouldShowAuthGate: Bool
  let shouldShowCodexCapabilityNotice: Bool
  let hasCodexError: Bool
  let provider: SessionProvider
  let optionsSummary: String

  @ViewBuilder let providerToggle: () -> ProviderToggle
  @ViewBuilder let endpointSection: () -> EndpointSection
  @ViewBuilder let continuationSection: (SessionContinuation) -> ContinuationSection
  @ViewBuilder let authGateSection: () -> AuthGateSection
  @ViewBuilder let codexCapabilityNotice: () -> CodexCapabilityNotice
  @ViewBuilder let directorySection: () -> DirectorySection
  @ViewBuilder let optionsPanel: () -> OptionsPanel
  @ViewBuilder let errorBanner: () -> ErrorBanner

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      providerToggle()

      if shouldShowEndpointSection {
        endpointSection()
      }

      if let continuation {
        continuationSection(continuation)
      }

      if isCodexProvider, shouldShowAuthGate {
        authGateSection()
      }

      if isCodexProvider, shouldShowCodexCapabilityNotice {
        codexCapabilityNotice()
      }

      sectionDivider("Workspace")

      directorySection()

      optionsDisclosure

      if hasCodexError {
        errorBanner()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Section Divider

  private func sectionDivider(_ title: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Text(title)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.light))
        .frame(height: 1)
    }
  }

  // MARK: - Options Disclosure

  private var optionsDisclosure: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(Motion.standard) {
          onToggleOptions()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(provider.color)

          Text("Session options")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          if !showOptions, !optionsSummary.isEmpty {
            Text(optionsSummary)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
              .lineLimit(1)
          }

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(showOptions ? 90 : 0))
            .animation(Motion.snappy, value: showOptions)
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(showOptions ? 1 : 0))
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .platformCursorOnHover()

      if showOptions {
        optionsPanel()
          .padding(.top, Spacing.md)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }
}
