import Foundation

struct PlatformCapabilities {
  let canRevealInFileBrowser: Bool
  let canPlaySystemSounds: Bool
  let canAccessPasteboard: Bool
  let canOpenExternalURLs: Bool
  let canUseLoopbackDevelopmentHost: Bool

  #if os(macOS)
    static let current = PlatformCapabilities(
      canRevealInFileBrowser: true,
      canPlaySystemSounds: true,
      canAccessPasteboard: true,
      canOpenExternalURLs: true,
      canUseLoopbackDevelopmentHost: true
    )
  #else
    static let current = PlatformCapabilities(
      canRevealInFileBrowser: false,
      canPlaySystemSounds: true,
      canAccessPasteboard: true,
      canOpenExternalURLs: true,
      canUseLoopbackDevelopmentHost: {
        #if targetEnvironment(simulator)
          true
        #else
          false
        #endif
      }()
    )
  #endif
}
