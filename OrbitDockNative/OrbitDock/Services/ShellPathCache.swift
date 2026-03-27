import Foundation

final class ShellPathCache {
  static let shared = ShellPathCache()

  private init() {}

  func captureOnce() {}

  var shellPath: String? {
    nil
  }

  var pathString: String? {
    nil
  }

  var pathEntries: [String] {
    []
  }
}
