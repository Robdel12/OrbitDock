import Foundation

struct PlatformCapabilities {
  let canInstallLocalServer: Bool
  let canUseAppleScript: Bool
  let canFocusTerminal: Bool
  let canManageClaudeHooks: Bool
  let canRevealInFileBrowser: Bool
  let canPlaySystemSounds: Bool
  let canAccessPasteboard: Bool
  let canOpenExternalURLs: Bool

  #if os(macOS)
    static let current = PlatformCapabilities(
      canInstallLocalServer: true,
      canUseAppleScript: true,
      canFocusTerminal: true,
      canManageClaudeHooks: true,
      canRevealInFileBrowser: true,
      canPlaySystemSounds: true,
      canAccessPasteboard: true,
      canOpenExternalURLs: true
    )
  #else
    static let current = PlatformCapabilities(
      canInstallLocalServer: false,
      canUseAppleScript: false,
      canFocusTerminal: false,
      canManageClaudeHooks: false,
      canRevealInFileBrowser: false,
      canPlaySystemSounds: true,
      canAccessPasteboard: true,
      canOpenExternalURLs: true
    )
  #endif
}
