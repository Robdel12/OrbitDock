import Foundation

#if os(macOS)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

@MainActor
protocol PlatformServices {
  var capabilities: PlatformCapabilities { get }

  @discardableResult
  func openURL(_ url: URL) -> Bool

  @discardableResult
  func revealInFileBrowser(_ path: String) -> Bool

  func copyToClipboard(_ text: String)
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

    func copyToClipboard(_ text: String) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }
  }

#elseif canImport(UIKit)
  @MainActor
  private final class IOSPlatformServices: PlatformServices {
    let capabilities = PlatformCapabilities.current

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

    func copyToClipboard(_ text: String) {
      UIPasteboard.general.string = text
    }
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

    func copyToClipboard(_ text: String) {
      _ = text
    }
  }
#endif
