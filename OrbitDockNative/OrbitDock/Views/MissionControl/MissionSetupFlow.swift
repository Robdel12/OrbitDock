import SwiftUI

struct MissionSetupFlow: View {
  let mission: MissionSummary
  let missionId: String
  let missionFileExists: Bool
  let workflowMigrationAvailable: Bool
  let settings: MissionSettings?
  let http: ServerHTTPClient?
  let onApplyDetail: (MissionDetailResponse) -> Void
  let onRefresh: () async -> Void
  let onSelectTab: (MissionTab) -> Void

  @State private var isScaffoldingFresh = false
  @State private var isMigrating = false
  @State private var actionError: String?

  var body: some View {
    Group {
      if !missionFileExists, settings == nil {
        if workflowMigrationAvailable {
          missionSetupWithMigration
        } else {
          MissionSetupCard(
            missionId: missionId,
            repoRoot: mission.repoRoot,
            http: http,
            onApplyDetail: onApplyDetail,
            onRefresh: onRefresh
          )
        }
      } else if workflowMigrationAvailable {
        workflowMigrationBanner
      }

      if mission.parseError != nil, settings == nil, missionFileExists {
        configNeededBanner
      }

      if mission.orchestratorStatus == "no_api_key" {
        MissionApiKeyBanner(missionId: missionId, http: http) {
          await onRefresh()
        }
      }
    }
    .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(actionError ?? "")
    }
  }

  // MARK: - Setup with Migration

  private var missionSetupWithMigration: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Spacing.md) {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .fill(Color.accent.opacity(OpacityTier.light))

          Image(systemName: "arrow.right.doc.on.clipboard")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.accent)
        }
        .frame(width: 36, height: 36)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Existing Workflow Found")
            .font(.system(size: TypeScale.large, weight: .bold))
            .foregroundStyle(Color.textPrimary)

          Text("Import your WORKFLOW.md config into a MISSION.md")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
        }
      }
      .padding(Spacing.lg)
      .padding(.top, Spacing.xs)

      Divider().foregroundStyle(Color.surfaceBorder)

      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "doc.text")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)

          Text(mission.repoRoot + "/WORKFLOW.md")
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Button {
          Task { await migrateWorkflow() }
        } label: {
          HStack(spacing: Spacing.sm) {
            if isMigrating {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "arrow.right.doc")
            }
            Text("Import Settings")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(CosmicButtonStyle(color: .accent, size: .large))
        .disabled(isMigrating)
      }
      .padding(Spacing.lg)

      Divider().foregroundStyle(Color.surfaceBorder)

      HStack(spacing: Spacing.sm_) {
        Text("Or")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)

        Button {
          Task { await scaffoldFresh() }
        } label: {
          HStack(spacing: Spacing.xs) {
            if isScaffoldingFresh {
              ProgressView()
                .controlSize(.mini)
            } else {
              Image(systemName: "wand.and.stars")
                .font(.system(size: 9))
            }
            Text("start fresh with a blank MISSION.md")
              .font(.system(size: TypeScale.micro))
          }
          .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
        .disabled(isScaffoldingFresh)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)
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

  // MARK: - Workflow Migration Banner

  private var workflowMigrationBanner: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.right.arrow.left.circle.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.accent)
        Text("Migrate from WORKFLOW.md")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
      }

      Text(
        "A WORKFLOW.md with compatible settings was found. Import your tracker, polling, and provider settings into a new MISSION.md."
      )
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textSecondary)
      .fixedSize(horizontal: false, vertical: true)

      Button {
        Task { await migrateWorkflow() }
      } label: {
        HStack(spacing: Spacing.sm) {
          if isMigrating {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.right.doc")
          }
          Text("Import Settings")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(CosmicButtonStyle(color: .accent, size: .large))
      .disabled(isMigrating)
    }
    .statusBanner(color: Color.accent)
  }

  // MARK: - Config Needed Banner

  private var configNeededBanner: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "info.circle.fill")
          .foregroundStyle(Color.feedbackCaution)
        Text("Configuration Needed")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
      }

      Text(
        "Your MISSION.md doesn't contain OrbitDock configuration yet. Open Settings to configure — your existing file content will be preserved."
      )
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textSecondary)
      .fixedSize(horizontal: false, vertical: true)

      Button {
        onSelectTab(.settings)
      } label: {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "gearshape")
          Text("Open Settings")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(CosmicButtonStyle(color: .accent, size: .large))
    }
    .statusBanner(color: Color.feedbackCaution)
  }

  // MARK: - Networking

  private func scaffoldFresh() async {
    guard let http else { return }
    isScaffoldingFresh = true
    do {
      let response: MissionDetailResponse = try await http.post(
        "/api/missions/\(missionId)/scaffold",
        body: EmptyBody()
      )
      onApplyDetail(response)
    } catch {
      actionError = error.localizedDescription
      await onRefresh()
    }
    isScaffoldingFresh = false
  }

  private func migrateWorkflow() async {
    guard let http else { return }
    isMigrating = true
    do {
      let response: MissionDetailResponse = try await http.post(
        "/api/missions/\(missionId)/migrate-workflow",
        body: EmptyBody()
      )
      onApplyDetail(response)
    } catch {
      actionError = error.localizedDescription
      await onRefresh()
    }
    isMigrating = false
  }
}
