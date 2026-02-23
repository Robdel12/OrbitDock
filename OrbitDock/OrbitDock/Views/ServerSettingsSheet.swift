//
//  ServerSettingsSheet.swift
//  OrbitDock
//
//  Configure remote server endpoint.
//  User just enters an IP address — we handle the rest.
//

import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.orbitdock", category: "server-settings")

struct ServerSettingsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @State private var hostText: String = ServerEndpointSettings
    .remoteEndpoint
    .flatMap { ServerEndpointSettings.hostInput(from: $0.wsURL) } ?? ""
  @State private var testStatus: TestStatus = .idle
  @State private var isSaved: Bool = ServerEndpointSettings.hasRemoteEndpoint

  private enum TestStatus: Equatable {
    case idle
    case testing
    case success
    case failed(String)
  }

  /// The full URL we'd connect to based on current input
  private var resolvedURL: URL? {
    ServerEndpointSettings.buildURL(from: hostText)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          serverHostSection
          connectionStatusSection
          actionButtons
        }
        .padding(20)
      }
      .background(Color.backgroundPrimary)
      .navigationTitle("Server")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
              .foregroundStyle(Color.accent)
          }
        }
    }
    .presentationDetents([.medium, .large])
  }

  // MARK: - Server Host

  private var serverHostSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Server Address")
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      Text("IP address of the machine running orbitdock-server")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)

      TextField("192.168.1.100", text: $hostText)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.title, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
        .padding(12)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .autocorrectionDisabled()
      #if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.numbersAndPunctuation)
      #endif
        .onChange(of: hostText) { _, _ in
          testStatus = .idle
        }

      // Show resolved URL as feedback
      if let url = resolvedURL, !hostText.isEmpty {
        Text(url.absoluteString)
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
      }
    }
  }

  // MARK: - Connection Status

  @ViewBuilder
  private var connectionStatusSection: some View {
    let connStatus = runtimeRegistry.activeConnectionStatus

    VStack(alignment: .leading, spacing: 8) {
      Text("Connection")
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      HStack(spacing: 8) {
        Circle()
          .fill(statusColor(for: connStatus))
          .frame(width: 8, height: 8)

        Text(statusLabel(for: connStatus))
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)

        Spacer()

        if case .failed = connStatus {
          Button("Reconnect") {
            runtimeRegistry.activeConnection.connect()
          }
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.accent)
        }
      }
      .padding(12)
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))

      // Test result
      switch testStatus {
        case .idle:
          EmptyView()
        case .testing:
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.mini)
            Text("Testing connection...")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          }
        case .success:
          HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(Color.statusWorking)
              .font(.system(size: 12))
            Text("Server reachable")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.statusWorking)
          }
        case let .failed(reason):
          HStack(spacing: 6) {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(Color.statusPermission)
              .font(.system(size: 12))
            Text(reason)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.statusPermission)
          }
      }
    }
  }

  // MARK: - Actions

  private var actionButtons: some View {
    VStack(spacing: 10) {
      // Test button
      Button {
        testConnection()
      } label: {
        HStack {
          Spacer()
          if testStatus == .testing {
            ProgressView()
              .controlSize(.small)
              .tint(Color.accent)
          } else {
            Image(systemName: "antenna.radiowaves.left.and.right")
            Text("Test Connection")
          }
          Spacer()
        }
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(Color.accent)
        .padding(.vertical, 12)
        .background(
          Color.accent.opacity(OpacityTier.light),
          in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        )
      }
      .buttonStyle(.plain)
      .disabled(resolvedURL == nil || testStatus == .testing)

      // Save button
      Button {
        saveEndpoint()
      } label: {
        HStack {
          Spacer()
          Image(systemName: "checkmark")
          Text(isSaved ? "Update & Connect" : "Save & Connect")
          Spacer()
        }
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.vertical, 12)
        .background(Color.accent, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
      }
      .buttonStyle(.plain)
      .disabled(resolvedURL == nil)

      // Clear / disconnect
      if isSaved {
        Button {
          clearEndpoint()
        } label: {
          HStack {
            Spacer()
            Text("Disconnect & Clear")
            Spacer()
          }
          .font(.system(size: TypeScale.subhead, weight: .medium))
          .foregroundStyle(Color.statusPermission)
          .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
      }
    }
  }

  // MARK: - Helpers

  private func statusColor(for status: ConnectionStatus) -> Color {
    switch status {
      case .connected: Color.statusWorking
      case .connecting: Color.statusQuestion
      case .disconnected: Color.textQuaternary
      case .failed: Color.statusPermission
    }
  }

  private func statusLabel(for status: ConnectionStatus) -> String {
    switch status {
      case .connected: "Connected"
      case .connecting: "Connecting..."
      case .disconnected: "Disconnected"
      case let .failed(msg): "Failed: \(msg)"
    }
  }

  private func testConnection() {
    guard let url = resolvedURL else {
      testStatus = .failed("Enter a valid IP address")
      return
    }

    testStatus = .testing

    Task {
      let config = URLSessionConfiguration.ephemeral
      config.timeoutIntervalForRequest = 5
      let session = URLSession(configuration: config)
      let wsTask = session.webSocketTask(with: url)
      wsTask.resume()

      do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          wsTask.sendPing { error in
            if let error {
              continuation.resume(throwing: error)
            } else {
              continuation.resume()
            }
          }
        }

        await MainActor.run {
          testStatus = .success
        }
      } catch {
        await MainActor.run {
          testStatus = .failed("Could not reach server")
        }
      }

      wsTask.cancel(with: .goingAway, reason: nil)
      session.invalidateAndCancel()
    }
  }

  private func saveEndpoint() {
    guard let url = resolvedURL else { return }
    ServerEndpointSettings.replaceRemoteEndpoint(hostInput: hostText)
    isSaved = true
    logger.info("Saved remote endpoint: \(url.absoluteString)")

    runtimeRegistry.configureFromSettings(startEnabled: true)
  }

  private func clearEndpoint() {
    ServerEndpointSettings.clearRemoteEndpoints()
    isSaved = false
    hostText = ""
    logger.info("Cleared remote endpoint")

    runtimeRegistry.configureFromSettings(startEnabled: true)
  }
}

#Preview {
  ServerSettingsSheet()
    .environment(ServerRuntimeRegistry.shared)
    .preferredColorScheme(.dark)
}
