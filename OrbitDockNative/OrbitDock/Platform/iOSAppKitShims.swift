#if os(iOS)
  import Foundation
  import SwiftUI
  import UIKit
  import UniformTypeIdentifiers

  typealias NSImage = UIImage
  typealias NSSize = CGSize
  typealias NSRect = CGRect

  enum NSCompositingOperation {
    case copy
  }

  enum NSImageInterpolation {
    case high
  }

  final class NSGraphicsContext {
    static var current: NSGraphicsContext? = NSGraphicsContext()
    var imageInterpolation: NSImageInterpolation = .high
  }

  extension UIImage {
    convenience init(size: CGSize) {
      let renderer = UIGraphicsImageRenderer(size: size)
      let image = renderer.image { _ in }
      if let data = image.pngData(), let decoded = UIImage(data: data) {
        self.init(cgImage: decoded.cgImage!)
      } else {
        self.init()
      }
    }

    convenience init?(contentsOf url: URL) {
      guard let data = try? Data(contentsOf: url) else { return nil }
      self.init(data: data)
    }

    var tiffRepresentation: Data? {
      pngData()
    }

    func lockFocus() {}

    func unlockFocus() {}

    func draw(in rect: CGRect, from srcRect: CGRect, operation: NSCompositingOperation, fraction: CGFloat) {
      _ = srcRect
      _ = operation
      draw(in: rect, blendMode: .normal, alpha: fraction)
    }
  }

  extension Image {
    init(nsImage: NSImage) {
      self.init(uiImage: nsImage)
    }
  }

  final class NSBitmapImageRep {
    enum FileType {
      case png
    }

    private let data: Data

    init?(data: Data) {
      self.data = data
    }

    func representation(using type: FileType, properties: [AnyHashable: Any]) -> Data? {
      _ = type
      _ = properties
      return data
    }
  }

  final class NSCursor {
    static let pointingHand = NSCursor()

    func push() {}

    static func pop() {}
  }

  final class NSWorkspace {
    static let shared = NSWorkspace()

    @discardableResult
    func open(_ url: URL) -> Bool {
      guard UIApplication.shared.canOpenURL(url) else { return false }
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
      return true
    }

    @discardableResult
    func selectFile(_ fullPath: String?, inFileViewerRootedAtPath rootPath: String) -> Bool {
      _ = fullPath
      _ = rootPath
      return false
    }
  }

  struct NSPasteboardType: Hashable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
      self.rawValue = rawValue
    }

    static let string = NSPasteboardType(rawValue: "public.utf8-plain-text")
    static let tiff = NSPasteboardType(rawValue: "public.tiff")
    static let png = NSPasteboardType(rawValue: "public.png")
  }

  final class NSPasteboard {
    typealias PasteboardType = NSPasteboardType

    static let general = NSPasteboard()

    func clearContents() {
      UIPasteboard.general.items = []
    }

    @discardableResult
    func setString(_ string: String, forType type: PasteboardType) -> Bool {
      _ = type
      UIPasteboard.general.string = string
      return true
    }

    func availableType(from types: [PasteboardType]) -> PasteboardType? {
      guard UIPasteboard.general.image != nil else { return nil }
      if types.contains(.png) { return .png }
      if types.contains(.tiff) { return .tiff }
      return nil
    }

    func data(forType type: PasteboardType) -> Data? {
      guard let image = UIPasteboard.general.image else { return nil }
      switch type {
        case .png, .tiff:
          return image.pngData()
        default:
          return nil
      }
    }
  }

  enum NSApplication {
    struct ModalResponse: Equatable {
      let rawValue: Int
      static let OK = ModalResponse(rawValue: 1)
      static let cancel = ModalResponse(rawValue: 0)
    }
  }

  final class NSOpenPanel {
    var allowedContentTypes: [UTType] = []
    var allowsMultipleSelection = false
    var canChooseDirectories = false
    var canChooseFiles = true
    var canCreateDirectories = false
    var prompt: String?
    var message: String?
    var directoryURL: URL?

    var urls: [URL] = []

    var url: URL? {
      urls.first
    }

    func runModal() -> NSApplication.ModalResponse {
      .cancel
    }
  }

  final class NSSound {
    struct Name: Hashable, RawRepresentable {
      let rawValue: String

      init(rawValue: String) {
        self.rawValue = rawValue
      }

      init(_ rawValue: String) {
        self.rawValue = rawValue
      }
    }

    static func beep() {}

    init?(named name: Name) {
      _ = name
    }

    func play() {}
  }
#endif
