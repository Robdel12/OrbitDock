import Foundation

#if os(macOS)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
  #if canImport(CoreHaptics)
    import CoreHaptics
  #endif
#endif

enum AppHapticLevel: String, CaseIterable, Identifiable {
  case off
  case minimal
  case full

  var id: String { rawValue }

  var title: String {
    switch self {
      case .off: "Off"
      case .minimal: "Minimal"
      case .full: "Full"
    }
  }

  var detail: String {
    switch self {
      case .off:
        "Disable all in-app haptic feedback."
      case .minimal:
        "Feedback for approvals, send/stop actions, and confirmed outcomes."
      case .full:
        "Stronger, more frequent feedback across navigation, expand/collapse, and picker interactions."
    }
  }
}

enum AppHaptic {
  case selection
  case navigation
  case expansion
  case action
  case success
  case warning
  case error
  case destructive

  fileprivate var minimumLevel: AppHapticLevel {
    switch self {
      case .selection, .navigation, .expansion:
        .full
      case .action, .success, .warning, .error, .destructive:
        .minimal
    }
  }
}

private extension AppHapticLevel {
  func allows(_ haptic: AppHaptic) -> Bool {
    switch self {
      case .off:
        false
      case .minimal:
        haptic.minimumLevel == .minimal
      case .full:
        true
    }
  }
}

@MainActor
protocol PlatformServices {
  var capabilities: PlatformCapabilities { get }

  @discardableResult
  func openURL(_ url: URL) -> Bool

  @discardableResult
  func revealInFileBrowser(_ path: String) -> Bool

  @discardableResult
  func openMicrophonePrivacySettings() -> Bool

  func copyToClipboard(_ text: String)
  func playHaptic(_ haptic: AppHaptic)
}

enum Platform {
  @MainActor
  static let services: any PlatformServices = {
    #if os(macOS)
      MacPlatformServices()
    #elseif canImport(UIKit)
      IOSPlatformServices()
    #else
      NoopPlatformServices()
    #endif
  }()
}

#if os(macOS)
  @MainActor
  private final class MacPlatformServices: PlatformServices {
    let capabilities = PlatformCapabilities.current

    @discardableResult
    func openURL(_ url: URL) -> Bool {
      NSWorkspace.shared.open(url)
    }

    @discardableResult
    func revealInFileBrowser(_ path: String) -> Bool {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        return true
      }

      NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
      return true
    }

    @discardableResult
    func openMicrophonePrivacySettings() -> Bool {
      guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
      else { return false }
      return NSWorkspace.shared.open(url)
    }

    func copyToClipboard(_ text: String) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }

    func playHaptic(_ haptic: AppHaptic) {
      _ = haptic
    }
  }

#elseif canImport(UIKit)
  @MainActor
  private final class IOSPlatformServices: PlatformServices {
    private enum HapticPlaybackError: Error {
      case engineUnavailable
    }

    let capabilities = PlatformCapabilities.current
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let softImpactGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let rigidImpactGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let heavyImpactGenerator = UIImpactFeedbackGenerator(style: .heavy)
    #if canImport(CoreHaptics)
      private var hapticEngine: CHHapticEngine?
      private var isHapticEngineRunning = false
    #endif

    init() {
      prepareGenerators()
      #if canImport(CoreHaptics)
        configureHapticEngine()
      #endif
    }

    private var currentHapticLevel: AppHapticLevel {
      AppHapticLevel(
        rawValue: UserDefaults.standard.string(forKey: "hapticFeedbackLevel") ?? AppHapticLevel.minimal.rawValue
      ) ?? .minimal
    }

    @discardableResult
    func openURL(_ url: URL) -> Bool {
      guard UIApplication.shared.canOpenURL(url) else { return false }
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
      return true
    }

    @discardableResult
    func revealInFileBrowser(_ path: String) -> Bool {
      _ = path
      return false
    }

    @discardableResult
    func openMicrophonePrivacySettings() -> Bool {
      guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
      guard UIApplication.shared.canOpenURL(url) else { return false }
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
      return true
    }

    func copyToClipboard(_ text: String) {
      UIPasteboard.general.string = text
    }

    func playHaptic(_ haptic: AppHaptic) {
      guard UIApplication.shared.applicationState == .active else { return }
      let currentLevel = currentHapticLevel
      guard currentLevel.allows(haptic) else { return }

      if currentLevel == .full, playEnhancedFullHaptic(haptic) {
        prepareGenerators()
        return
      }

      playSystemHaptic(haptic, level: currentLevel)
      prepareGenerators()
    }

    private func prepareGenerators() {
      selectionGenerator.prepare()
      notificationGenerator.prepare()
      softImpactGenerator.prepare()
      lightImpactGenerator.prepare()
      mediumImpactGenerator.prepare()
      rigidImpactGenerator.prepare()
      heavyImpactGenerator.prepare()
    }

    private func playSystemHaptic(_ haptic: AppHaptic, level: AppHapticLevel) {
      switch haptic {
        case .selection:
          if level == .full {
            rigidImpactGenerator.impactOccurred(intensity: 0.7)
          } else {
            selectionGenerator.selectionChanged()
          }

        case .navigation:
          if level == .full {
            lightImpactGenerator.impactOccurred(intensity: 1)
          } else {
            softImpactGenerator.impactOccurred(intensity: 0.8)
          }

        case .expansion:
          if level == .full {
            rigidImpactGenerator.impactOccurred(intensity: 0.78)
          } else {
            softImpactGenerator.impactOccurred(intensity: 0.65)
          }

        case .action:
          if level == .full {
            mediumImpactGenerator.impactOccurred(intensity: 1)
          } else {
            lightImpactGenerator.impactOccurred(intensity: 0.95)
          }

        case .success:
          notificationGenerator.notificationOccurred(.success)
          if level == .full {
            lightImpactGenerator.impactOccurred(intensity: 0.8)
          }

        case .warning:
          notificationGenerator.notificationOccurred(.warning)
          if level == .full {
            mediumImpactGenerator.impactOccurred(intensity: 0.78)
          }

        case .error:
          notificationGenerator.notificationOccurred(.error)
          if level == .full {
            rigidImpactGenerator.impactOccurred(intensity: 0.82)
          }

        case .destructive:
          if level == .full {
            heavyImpactGenerator.impactOccurred(intensity: 1)
          } else {
            mediumImpactGenerator.impactOccurred(intensity: 1)
          }
      }
    }

    private func playEnhancedFullHaptic(_ haptic: AppHaptic) -> Bool {
      #if canImport(CoreHaptics)
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return false }

        do {
          let engine = try activeHapticEngine()
          let pattern = try CHHapticPattern(events: fullPatternEvents(for: haptic), parameters: [])
          let player = try engine.makePlayer(with: pattern)
          try player.start(atTime: CHHapticTimeImmediate)
          return true
        } catch {
          return false
        }
      #else
        _ = haptic
        return false
      #endif
    }

    #if canImport(CoreHaptics)
      private func configureHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

        do {
          let engine = try CHHapticEngine()
          engine.playsHapticsOnly = true
          engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
              self?.hapticEngine = nil
              self?.isHapticEngineRunning = false
            }
          }
          engine.resetHandler = { [weak self] in
            Task { @MainActor [weak self] in
              self?.isHapticEngineRunning = false
              self?.configureHapticEngine()
            }
          }
          try engine.start()
          hapticEngine = engine
          isHapticEngineRunning = true
        } catch {
          hapticEngine = nil
          isHapticEngineRunning = false
        }
      }

      private func activeHapticEngine() throws -> CHHapticEngine {
        if hapticEngine == nil {
          configureHapticEngine()
        }

        guard let hapticEngine else {
          throw HapticPlaybackError.engineUnavailable
        }

        if !isHapticEngineRunning {
          try hapticEngine.start()
          isHapticEngineRunning = true
        }

        return hapticEngine
      }

      private func fullPatternEvents(for haptic: AppHaptic) -> [CHHapticEvent] {
        switch haptic {
          case .selection:
            [transientEvent(at: 0, intensity: 0.58, sharpness: 0.82)]

          case .navigation:
            [transientEvent(at: 0, intensity: 0.66, sharpness: 0.68)]

          case .expansion:
            [
              transientEvent(at: 0, intensity: 0.74, sharpness: 0.42),
              transientEvent(at: 0.06, intensity: 0.28, sharpness: 0.2),
            ]

          case .action:
            [
              transientEvent(at: 0, intensity: 0.88, sharpness: 0.7),
              transientEvent(at: 0.07, intensity: 0.46, sharpness: 0.5),
            ]

          case .success:
            [
              transientEvent(at: 0, intensity: 0.52, sharpness: 0.62),
              transientEvent(at: 0.09, intensity: 0.96, sharpness: 0.88),
            ]

          case .warning:
            [
              transientEvent(at: 0, intensity: 0.84, sharpness: 0.38),
              transientEvent(at: 0.12, intensity: 0.42, sharpness: 0.18),
            ]

          case .error:
            [
              transientEvent(at: 0, intensity: 0.96, sharpness: 0.36),
              transientEvent(at: 0.1, intensity: 0.72, sharpness: 0.16),
            ]

          case .destructive:
            [
              transientEvent(at: 0, intensity: 1, sharpness: 0.52),
              transientEvent(at: 0.08, intensity: 0.82, sharpness: 0.28),
            ]
        }
      }

      private func transientEvent(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
          ],
          relativeTime: time
        )
      }
    #endif
  }
#else
  @MainActor
  private final class NoopPlatformServices: PlatformServices {
    let capabilities = PlatformCapabilities.current

    @discardableResult
    func openURL(_ url: URL) -> Bool {
      _ = url
      return false
    }

    @discardableResult
    func revealInFileBrowser(_ path: String) -> Bool {
      _ = path
      return false
    }

    @discardableResult
    func openMicrophonePrivacySettings() -> Bool {
      false
    }

    func copyToClipboard(_ text: String) {
      _ = text
    }

    func playHaptic(_ haptic: AppHaptic) {
      _ = haptic
    }
  }
#endif
