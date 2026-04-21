import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

enum PlatformAttachmentInput {
  static var supportsImageClipboardPaste: Bool {
    #if os(macOS)
      NSPasteboard.general.availableType(from: [.tiff, .png]) != nil
    #else
      UIPasteboard.general.hasImages
    #endif
  }

  static func pasteImageFromClipboard() -> ControlDeckImageDraft? {
    #if os(macOS)
      let pasteboard = NSPasteboard.general
      guard let imageType = pasteboard.availableType(from: [.tiff, .png]),
            let data = pasteboard.data(forType: imageType),
            let normalized = normalizedPNG(from: data)
      else { return nil }

      return imageDraft(
        data: normalized,
        displayName: "Clipboard Image"
      )
    #else
      guard let image = UIPasteboard.general.image,
            let data = image.pngData()
      else { return nil }

      return imageDraft(
        data: data,
        displayName: "Clipboard Image"
      )
    #endif
  }

  static func handleDrop(
    _ providers: [NSItemProvider],
    onImage: @escaping @MainActor (ControlDeckImageDraft) -> Void
  ) -> Bool {
    #if os(macOS)
      var handled = false
      for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
          guard let url = droppedFileURL(from: item),
                url.isFileURL,
                UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                let payload = try? ControlDeckComposerModel.makeImagePayloadIfNeeded(from: url)
          else { return }

          Task { @MainActor in
            onImage(payload)
          }
        }
        handled = true
      }
      return handled
    #else
      var handled = false
      for provider in providers where provider.canLoadObject(ofClass: UIImage.self) {
        provider.loadObject(ofClass: UIImage.self) { object, _ in
          guard let image = object as? UIImage,
                let data = image.pngData()
          else { return }

          let payload = imageDraft(data: data, displayName: "Dropped Image")
          Task { @MainActor in
            onImage(payload)
          }
        }
        handled = true
      }
      return handled
    #endif
  }

  private static func imageDraft(data: Data, displayName: String) -> ControlDeckImageDraft {
    let dims = ControlDeckComposerModel.imageDimensions(from: data)
    return ControlDeckImageDraft(
      localId: UUID().uuidString,
      thumbnailData: data.count < 500_000 ? data : nil,
      uploadData: data,
      uploadMimeType: "image/png",
      displayName: displayName,
      pixelWidth: dims.width,
      pixelHeight: dims.height
    )
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

  #if os(macOS)
    private static func droppedFileURL(from item: NSSecureCoding?) -> URL? {
      (item as? URL)
        ?? (item as? NSURL) as URL?
        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
    }
  #endif
}
