import SwiftUI

extension ReviewCanvas {
  func openFile(_ file: FileDiff) {
    let fullPath = projectPath.hasSuffix("/")
      ? projectPath + file.newPath
      : projectPath + "/" + file.newPath

    _ = Platform.services.openURL(URL(fileURLWithPath: fullPath))
  }
}
