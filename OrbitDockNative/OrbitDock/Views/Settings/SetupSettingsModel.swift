import Foundation
import SwiftUI

@MainActor
@Observable
final class SetupSettingsModel {
  var copied = false
  var hooksConfigured: Bool?

  let hookForwardPath = "/Applications/OrbitDock.app/Contents/Resources/orbitdock"
  let settingsPath = PlatformPaths.homeDirectory
    .appendingPathComponent(".claude/settings.json").path

  private var copyResetTask: Task<Void, Never>?

  var hooksConfigJSON: String {
    ClaudeHooksSetupPlanner.hooksConfigurationJSON(hookForwardPath: hookForwardPath)
  }

  func refreshHooksConfiguration() {
    hooksConfigured = nil

    let settingsPath = settingsPath
    Task {
      let configured = await Self.readHooksConfigured(settingsPath: settingsPath)
      hooksConfigured = configured
    }
  }

  func copyHooksConfiguration() {
    Platform.services.copyToClipboard(hooksConfigJSON)
    copied = true

    copyResetTask?.cancel()
    copyResetTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      copied = false
    }
  }

  func openSettingsFile() {
    if !FileManager.default.fileExists(atPath: settingsPath) {
      let directory = (settingsPath as NSString).deletingLastPathComponent
      try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try? "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)
    }

    _ = Platform.services.openURL(URL(fileURLWithPath: settingsPath))
  }

  private static func readHooksConfigured(settingsPath: String) async -> Bool {
    await Task.detached(priority: .userInitiated) {
      guard FileManager.default.fileExists(atPath: settingsPath),
            let data = FileManager.default.contents(atPath: settingsPath),
            let content = String(data: data, encoding: .utf8)
      else {
        return false
      }

      return ClaudeHooksSetupPlanner.hooksConfigured(contents: content)
    }.value
  }
}
