import SwiftUI

struct NewSessionSheetShell<Header: View, FormContent: View, Footer: View>: View {
  @ViewBuilder let header: () -> Header
  @ViewBuilder let formContent: () -> FormContent
  @ViewBuilder let footer: () -> Footer

  var body: some View {
    VStack(spacing: 0) {
      header()

      Divider()
        .overlay(Color.surfaceBorder)

      formContent()

      Divider()
        .overlay(Color.surfaceBorder)

      footer()
    }
    #if os(iOS)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    #else
    .frame(minWidth: 500, idealWidth: 600, maxWidth: 700)
    #endif
    .background(Color.backgroundSecondary)
  }
}

struct NewSessionFormShell<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    #if os(iOS)
      ScrollView(showsIndicators: false) {
        content()
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.lg)
          .padding(.bottom, Spacing.sm)
      }
    #else
      ScrollView(showsIndicators: true) {
        content()
          .padding(.horizontal, Spacing.xl)
          .padding(.vertical, Spacing.lg)
      }
    #endif
  }
}

struct NewSessionFormSections<
  ProviderPicker: View,
  EndpointSection: View,
  ContinuationSection: View,
  AuthGateSection: View,
  DirectorySection: View,
  WorktreeSection: View,
  ConfigurationCard: View,
  ToolRestrictionsCard: View,
  ErrorBanner: View
>: View {
  let formSectionSpacing: CGFloat
  let shouldShowEndpointSection: Bool
  let continuation: SessionContinuation?
  let isCodexProvider: Bool
  let isClaudeProvider: Bool
  let shouldShowAuthGate: Bool
  let hasSelectedPath: Bool
  let hasCodexError: Bool
  @ViewBuilder let providerPicker: () -> ProviderPicker
  @ViewBuilder let endpointSection: () -> EndpointSection
  @ViewBuilder let continuationSection: (SessionContinuation) -> ContinuationSection
  @ViewBuilder let authGateSection: () -> AuthGateSection
  @ViewBuilder let directorySection: () -> DirectorySection
  @ViewBuilder let worktreeSection: () -> WorktreeSection
  @ViewBuilder let configurationCard: () -> ConfigurationCard
  @ViewBuilder let toolRestrictionsCard: () -> ToolRestrictionsCard
  @ViewBuilder let errorBanner: () -> ErrorBanner

  var body: some View {
    VStack(alignment: .leading, spacing: formSectionSpacing) {
      providerPicker()

      if shouldShowEndpointSection {
        endpointSection()
      }

      if let continuation {
        continuationSection(continuation)
      }

      if isCodexProvider && shouldShowAuthGate {
        authGateSection()
      }

      directorySection()

      if hasSelectedPath {
        worktreeSection()
      }

      configurationCard()

      if isClaudeProvider {
        toolRestrictionsCard()
      }

      if hasCodexError {
        errorBanner()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
