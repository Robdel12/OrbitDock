import SwiftUI

struct MissionSetupFlow: View {
  let mission: MissionSummary
  let missionId: String
  let missionFileExists: Bool
  let settings: MissionSettings?
  let missionsClient: MissionsClient?
  let onApplyDetail: (MissionDetailResponse) -> Void
  let onRefresh: () async -> Void
  let onSelectTab: (MissionTab) -> Void

  var body: some View {
    Group {
      if !missionFileExists, settings == nil {
        MissionSetupCard(
          missionId: missionId,
          repoRoot: mission.repoRoot,
          missionFileName: mission.resolvedFileName,
          missionsClient: missionsClient,
          onApplyDetail: onApplyDetail
        )
      }

      if mission.parseError != nil, settings == nil, missionFileExists {
        configNeededBanner
      }

      if mission.orchestratorStatus == "no_api_key" {
        MissionApiKeyBanner(
          missionId: missionId,
          trackerKind: mission.trackerKind,
          missionsClient: missionsClient
        ) {
          await onRefresh()
        }
      }
    }
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
        "Your \(mission.resolvedFileName) doesn't contain OrbitDock configuration yet. Open Settings to configure — your existing file content will be preserved."
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

}
