import SwiftUI

struct MissionSetupCard: View {
  let missionId: String
  let repoRoot: String
  let http: ServerHTTPClient?
  let onApplyDetail: (MissionDetailResponse) -> Void
  let onRefresh: () async -> Void

  @State private var isScaffolding = false
  @State private var scaffoldError: String?
  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with accent edge
      headerSection
        .padding(Spacing.lg)
        .padding(.top, Spacing.xs)

      Divider()
        .foregroundStyle(Color.surfaceBorder)

      // Steps
      stepsSection
        .padding(Spacing.lg)

      Divider()
        .foregroundStyle(Color.surfaceBorder)

      // Actions
      actionsSection
        .padding(Spacing.lg)

      if let scaffoldError {
        Text(scaffoldError)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.feedbackNegative)
          .padding(.horizontal, Spacing.lg)
          .padding(.bottom, Spacing.lg)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(
          LinearGradient(
            colors: [
              Color.accent.opacity(OpacityTier.medium),
              Color.accent.opacity(OpacityTier.subtle),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 1
        )
    )
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
  }

  // MARK: - Header

  private var headerSection: some View {
    HStack(spacing: Spacing.md) {
      // Glowing icon container
      ZStack {
        RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
          .fill(Color.accent.opacity(OpacityTier.light))

        Image(systemName: "bolt.horizontal.circle")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(Color.accent)
      }
      .frame(width: 36, height: 36)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text("Initialize Mission")
          .font(.system(size: TypeScale.large, weight: .bold))
          .foregroundStyle(Color.textPrimary)

        Text("Configure how agents work on issues from your tracker")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textSecondary)
      }
    }
  }

  // MARK: - Steps

  private var stepsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      stepRow(
        number: "1",
        label: "Tracker Connection",
        detail: "Which issue tracker to poll (Linear, GitHub)"
      )
      stepRow(
        number: "2",
        label: "Orchestration Rules",
        detail: "Concurrency limits, retry policies, stall detection"
      )
      stepRow(
        number: "3",
        label: "Agent Instructions",
        detail: "What each agent is told when it picks up an issue"
      )
    }
  }

  private func stepRow(number: String, label: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      Text(number)
        .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.accent)
        .frame(width: 20, height: 20)
        .background(
          Color.accent.opacity(OpacityTier.subtle),
          in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        )

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(label)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        Text(detail)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }

  // MARK: - Actions

  private var actionsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Button {
        Task { await scaffoldWorkflow() }
      } label: {
        HStack(spacing: Spacing.sm) {
          if isScaffolding {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "wand.and.stars")
          }
          Text("Generate MISSION.md")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(CosmicButtonStyle(color: .accent, size: .large))
      .shadow(color: isHovering ? Color.accent.opacity(0.3) : .clear, radius: 8, y: 2)
      .disabled(isScaffolding)
      .onHover { hovering in
        withAnimation(Motion.hover) { isHovering = hovering }
      }

      // Manual path hint
      HStack(spacing: Spacing.sm_) {
        Image(systemName: "terminal")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color.textQuaternary)

        Text("Or create manually:")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)

        Text(repoRoot + "/MISSION.md")
          .font(.system(size: TypeScale.micro, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Networking

  private func scaffoldWorkflow() async {
    guard let http else { return }

    isScaffolding = true
    scaffoldError = nil

    do {
      let response: MissionDetailResponse = try await http.post(
        "/api/missions/\(missionId)/scaffold",
        body: EmptyBody()
      )
      onApplyDetail(response)
    } catch {
      scaffoldError = "Failed to generate template: \(error.localizedDescription)"
    }

    isScaffolding = false
  }
}
