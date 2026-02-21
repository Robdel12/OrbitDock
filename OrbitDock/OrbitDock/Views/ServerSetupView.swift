//
//  ServerSetupView.swift
//  OrbitDock
//
//  First-launch onboarding when no server is reachable.
//  Walks the user through local install or remote connection.
//

import SwiftUI

struct ServerSetupView: View {
  @StateObject private var serverManager = ServerManager.shared
  @State private var showRemoteSheet = false

  var body: some View {
    VStack(spacing: Spacing.xl) {
      Spacer()

      // Header
      VStack(spacing: Spacing.md) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.system(size: 48))
          .foregroundStyle(Color.accent)

        Text("Connect to Server")
          .font(.system(size: TypeScale.headline, weight: .bold))
          .foregroundStyle(Color.textPrimary)

        Text("OrbitDock needs a running server to track your AI sessions.")
          .font(.system(size: TypeScale.subhead))
          .foregroundStyle(Color.textSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 400)
      }

      // Option cards
      VStack(spacing: Spacing.md) {
        #if os(macOS)
          localInstallCard
        #endif
        remoteConnectCard
      }
      .frame(maxWidth: 420)

      // Error display
      if let error = serverManager.installError {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(Color.statusPermission)
            .font(.system(size: 12))
          Text(error)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.statusPermission)
        }
        .padding(.horizontal, Spacing.lg)
      }

      Spacer()
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.backgroundPrimary)
    .sheet(isPresented: $showRemoteSheet) {
      ServerSettingsSheet()
    }
  }

  // MARK: - Local Install Card

  #if os(macOS)
    private var localInstallCard: some View {
      Button {
        Task {
          try? await serverManager.install()
          if serverManager.installState == .running {
            ServerConnection.shared.connect(to: ServerEndpointSettings.effectiveURL)
          }
        }
      } label: {
        HStack(spacing: Spacing.md) {
          Image(systemName: "server.rack")
            .font(.system(size: 24))
            .foregroundStyle(Color.accent)
            .frame(width: 40)

          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Install Locally")
              .font(.system(size: TypeScale.subhead, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
            Text("Runs as a background service, auto-starts at login")
              .font(.system(size: TypeScale.body))
              .foregroundStyle(Color.textTertiary)
          }

          Spacer()

          if serverManager.isInstalling {
            ProgressView()
              .controlSize(.small)
          } else if serverManager.installState == .running {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(Color.statusWorking)
              .font(.system(size: 18))
          } else {
            Image(systemName: "chevron.right")
              .foregroundStyle(Color.textQuaternary)
              .font(.system(size: 12))
          }
        }
        .padding(Spacing.lg)
        .background(
          Color.backgroundSecondary,
          in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(Color.panelBorder, lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
      .disabled(serverManager.isInstalling)
    }
  #endif

  // MARK: - Remote Connect Card

  private var remoteConnectCard: some View {
    Button {
      showRemoteSheet = true
    } label: {
      HStack(spacing: Spacing.md) {
        Image(systemName: "network")
          .font(.system(size: 24))
          .foregroundStyle(Color.accent)
          .frame(width: 40)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Connect to Remote Server")
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
          Text("Connect to a server running on another machine")
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.textTertiary)
        }

        Spacer()

        Image(systemName: "chevron.right")
          .foregroundStyle(Color.textQuaternary)
          .font(.system(size: 12))
      }
      .padding(Spacing.lg)
      .background(
        Color.backgroundSecondary,
        in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .stroke(Color.panelBorder, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}

#Preview {
  ServerSetupView()
    .frame(width: 600, height: 500)
    .preferredColorScheme(.dark)
}
