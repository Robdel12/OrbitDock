import Foundation

enum PlatformPaths {
  nonisolated static var homeDirectory: URL {
    #if os(macOS)
      FileManager.default.homeDirectoryForCurrentUser
    #else
      URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    #endif
  }

  nonisolated static var orbitDockBaseDirectory: URL {
    #if os(macOS)
      homeDirectory.appendingPathComponent(".orbitdock", isDirectory: true)
    #else
      let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
      return appSupport.appendingPathComponent("OrbitDock", isDirectory: true)
    #endif
  }

  nonisolated static var orbitDockLogsDirectory: URL {
    orbitDockBaseDirectory.appendingPathComponent("logs", isDirectory: true)
  }

  nonisolated static var orbitDockBinDirectory: URL {
    orbitDockBaseDirectory.appendingPathComponent("bin", isDirectory: true)
  }

  nonisolated static var orbitDockCacheDirectory: URL {
    orbitDockBaseDirectory.appendingPathComponent("cache", isDirectory: true)
  }

  nonisolated static func ensureDirectory(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
}
