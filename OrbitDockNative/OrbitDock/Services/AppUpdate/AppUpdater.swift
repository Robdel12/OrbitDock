import Foundation

#if os(macOS)
  import Sparkle

  enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta
    case nightly

    var id: String { rawValue }

    var displayName: String {
      switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        case .nightly: "Nightly"
      }
    }

    var description: String {
      switch self {
        case .stable:
          "Production releases only."
        case .beta:
          "Pre-release builds for testing upcoming features."
        case .nightly:
          "Latest automated builds — may be unstable."
      }
    }

    /// Sparkle channel identifiers sent via `allowedChannels(for:)`.
    /// Stable returns empty (matches items with no channel tag).
    var sparkleChannels: Set<String> {
      switch self {
        case .stable: []
        case .beta: ["beta"]
        case .nightly: ["nightly"]
      }
    }

    /// The appcast filename for this channel.
    var appcastFilename: String {
      switch self {
        case .stable: "appcast.xml"
        case .beta: "appcast-beta.xml"
        case .nightly: "appcast-nightly.xml"
      }
    }

    /// Feed URL for this channel on GitHub Releases.
    func feedURL(owner: String = "Robdel12", repo: String = "OrbitDock") -> URL? {
      let base = "https://github.com/\(owner)/\(repo)/releases"
      let urlString: String
      switch self {
        case .stable:
          urlString = "\(base)/latest/download/\(appcastFilename)"
        case .beta:
          urlString = "\(base)/latest/download/\(appcastFilename)"
        case .nightly:
          urlString = "\(base)/download/nightly/\(appcastFilename)"
      }
      return URL(string: urlString)
    }
  }

  @MainActor
  @Observable
  final class AppUpdater {
    private(set) var isConfigured: Bool

    var selectedChannel: UpdateChannel {
      didSet {
        UserDefaults.standard.set(selectedChannel.rawValue, forKey: "updateChannel")
        applyChannelFeedURL()
      }
    }

    @ObservationIgnored private let updaterController: SPUStandardUpdaterController?
    @ObservationIgnored private let updaterDelegate: AppUpdaterDelegate?
    @ObservationIgnored private var hasStarted = false

    init(bundle: Bundle = .main) {
      let feedURL = Self.infoString("SUFeedURL", bundle: bundle)
      let publicKey = Self.infoString("SUPublicEDKey", bundle: bundle)
      let isConfigured = !feedURL.isEmpty && !publicKey.isEmpty
      self.isConfigured = isConfigured

      let storedChannel = UserDefaults.standard.string(forKey: "updateChannel") ?? "stable"
      let channel = UpdateChannel(rawValue: storedChannel) ?? .stable
      self.selectedChannel = channel

      if isConfigured {
        let delegate = AppUpdaterDelegate(channel: channel)
        self.updaterDelegate = delegate
        updaterController = SPUStandardUpdaterController(
          startingUpdater: false,
          updaterDelegate: delegate,
          userDriverDelegate: nil
        )
      } else {
        self.updaterDelegate = nil
        updaterController = nil
      }
    }

    var canCheckForUpdates: Bool {
      isConfigured && hasStarted
    }

    func start() {
      guard !hasStarted, let updaterController else { return }
      applyChannelFeedURL()
      hasStarted = true
      updaterController.startUpdater()
    }

    func checkForUpdates() {
      guard let updaterController else { return }
      updaterController.checkForUpdates(nil)
    }

    private func applyChannelFeedURL() {
      updaterDelegate?.channel = selectedChannel
    }

    private static func infoString(_ key: String, bundle: Bundle) -> String {
      guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
        return ""
      }
      return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  // MARK: - Sparkle Delegate

  final class AppUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var channel: UpdateChannel

    init(channel: UpdateChannel) {
      self.channel = channel
      super.init()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
      channel.sparkleChannels
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
      channel.feedURL()?.absoluteString
    }
  }
#endif
