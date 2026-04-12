import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#endif

#if os(iOS)
  import UIKit
#endif

#if os(macOS)
  extension ControlDeckScreen {
    var supportsImageClipboardPaste: Bool {
      NSPasteboard.general.availableType(from: [.tiff, .png]) != nil
    }

    @discardableResult
    func pasteImageFromClipboard() -> Bool {
      let pasteboard = NSPasteboard.general
      guard let imageType = pasteboard.availableType(from: [.tiff, .png]),
            let data = pasteboard.data(forType: imageType),
            let normalized = Self.normalizedPNG(from: data)
      else { return false }

      let dims = ControlDeckComposerModel.imageDimensions(from: normalized)
      composer.appendDroppedImage(
        ControlDeckImageDraft(
          localId: UUID().uuidString,
          thumbnailData: normalized.count < 500_000 ? normalized : nil,
          uploadData: normalized,
          uploadMimeType: "image/png",
          displayName: "Clipboard Image",
          pixelWidth: dims.width,
          pixelHeight: dims.height
        )
      )
      return true
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
      var handled = false
      for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
          guard let url = Self.droppedFileURL(from: item),
                url.isFileURL,
                UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                let payload = try? ControlDeckComposerModel.makeImagePayloadIfNeeded(from: url)
          else { return }

          Task { @MainActor in
            composer.appendDroppedImage(payload)
          }
        }
        handled = true
      }
      return handled
    }

    private static func normalizedPNG(from data: Data) -> Data? {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return nil }

      let out = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(
        out,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else { return nil }

      CGImageDestinationAddImage(destination, cgImage, nil)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return out as Data
    }

    private static func droppedFileURL(from item: NSSecureCoding?) -> URL? {
      (item as? URL)
        ?? (item as? NSURL) as URL?
        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
    }
  }
#endif

#if os(iOS)
  extension ControlDeckScreen {
    var supportsImageClipboardPaste: Bool {
      UIPasteboard.general.hasImages
    }

    @discardableResult
    func pasteImageFromClipboard() -> Bool {
      guard let image = UIPasteboard.general.image, let data = image.pngData() else { return false }

      let dims = ControlDeckComposerModel.imageDimensions(from: data)
      composer.appendDroppedImage(
        ControlDeckImageDraft(
          localId: UUID().uuidString,
          thumbnailData: data.count < 500_000 ? data : nil,
          uploadData: data,
          uploadMimeType: "image/png",
          displayName: "Clipboard Image",
          pixelWidth: dims.width,
          pixelHeight: dims.height
        )
      )
      return true
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
      var handled = false
      for provider in providers where provider.canLoadObject(ofClass: UIImage.self) {
        provider.loadObject(ofClass: UIImage.self) { object, _ in
          guard let image = object as? UIImage, let data = image.pngData() else { return }

          let dims = ControlDeckComposerModel.imageDimensions(from: data)
          let payload = ControlDeckImageDraft(
            localId: UUID().uuidString,
            thumbnailData: data.count < 500_000 ? data : nil,
            uploadData: data,
            uploadMimeType: "image/png",
            displayName: "Dropped Image",
            pixelWidth: dims.width,
            pixelHeight: dims.height
          )
          Task { @MainActor in
            composer.appendDroppedImage(payload)
          }
        }
        handled = true
      }
      return handled
    }
  }
#endif
