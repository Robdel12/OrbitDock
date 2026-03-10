import SwiftUI

extension ReviewCanvas {
  private var preferredEditorSetting: String {
    UserDefaults.standard.string(forKey: "preferredEditor") ?? ""
  }

  func openFileInEditor(_ file: FileDiff) {
    let fullPath = projectPath.hasSuffix("/")
      ? projectPath + file.newPath
      : projectPath + "/" + file.newPath

    guard !preferredEditorSetting.isEmpty else {
      _ = Platform.services.openURL(URL(fileURLWithPath: fullPath))
      return
    }

    #if !os(macOS)
      _ = Platform.services.openURL(URL(fileURLWithPath: fullPath))
      return
    #else
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [preferredEditorSetting, fullPath]
      try? process.run()
    #endif
  }
}
