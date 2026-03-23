import Foundation

#if os(macOS)
  import Sparkle

  @MainActor
  @Observable
  final class AppUpdater {
    private(set) var isConfigured: Bool

    @ObservationIgnored private let updaterController: SPUStandardUpdaterController?
    @ObservationIgnored private var hasStarted = false

    init(bundle: Bundle = .main) {
      let feedURL = Self.infoString("SUFeedURL", bundle: bundle)
      let publicKey = Self.infoString("SUPublicEDKey", bundle: bundle)
      let isConfigured = !feedURL.isEmpty && !publicKey.isEmpty
      self.isConfigured = isConfigured

      if isConfigured {
        updaterController = SPUStandardUpdaterController(
          startingUpdater: false,
          updaterDelegate: nil,
          userDriverDelegate: nil
        )
      } else {
        updaterController = nil
      }
    }

    var canCheckForUpdates: Bool {
      isConfigured && hasStarted
    }

    func start() {
      guard !hasStarted, let updaterController else { return }
      hasStarted = true
      updaterController.startUpdater()
    }

    func checkForUpdates() {
      guard let updaterController else { return }
      updaterController.checkForUpdates(nil)
    }

    private static func infoString(_ key: String, bundle: Bundle) -> String {
      guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
        return ""
      }
      return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
#endif
