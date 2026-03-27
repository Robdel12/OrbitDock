import Foundation

struct PlatformCapabilities {
  let canRevealInFileBrowser: Bool
  let canPlaySystemSounds: Bool
  let canAccessPasteboard: Bool
  let canOpenExternalURLs: Bool

  #if os(macOS)
    static let current = PlatformCapabilities(
      canRevealInFileBrowser: true,
      canPlaySystemSounds: true,
      canAccessPasteboard: true,
      canOpenExternalURLs: true
    )
  #else
    static let current = PlatformCapabilities(
      canRevealInFileBrowser: false,
      canPlaySystemSounds: true,
      canAccessPasteboard: true,
      canOpenExternalURLs: true
    )
  #endif
}
