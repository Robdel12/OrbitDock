#if os(macOS)
  //
  //  DirectSessionComposer+ImageMacOS.swift
  //  OrbitDock
  //

  import AppKit
  import ImageIO
  import SwiftUI
  import UniformTypeIdentifiers

  extension DirectSessionComposer {
    private static let thumbnailMaxPixelSize = 160

    var canPasteImageFromClipboard: Bool {
      let pasteboard = NSPasteboard.general
      if pasteboard.availableType(from: [.tiff, .png]) != nil {
        return true
      }

      guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
        return false
      }
      return urls.contains(where: { $0.isFileURL && isImageFileURL($0) })
    }

    func pickImages() {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.image]
      panel.allowsMultipleSelection = true
      panel.canChooseDirectories = false
      panel.message = "Select images to attach"

      guard panel.runModal() == .OK else { return }
      let encodeAsDataURI = shouldEncodeLocalFileImagesAsDataURI

      for url in panel.urls {
        guard let thumbnail = createThumbnail(from: url),
              let input = serverInputForImageFile(url: url, encodeAsDataURI: encodeAsDataURI)
        else { continue }
        appendAttachedImage(AttachedImage(id: UUID().uuidString, thumbnail: thumbnail, serverInput: input))
      }
    }

    func pasteImageFromClipboard() -> Bool {
      let pasteboard = NSPasteboard.general
      let encodeAsDataURI = shouldEncodeLocalFileImagesAsDataURI

      if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
        for url in urls where url.isFileURL && isImageFileURL(url) {
          guard let thumbnail = createThumbnail(from: url),
                let input = serverInputForImageFile(url: url, encodeAsDataURI: encodeAsDataURI)
          else { continue }

          appendAttachedImage(AttachedImage(id: UUID().uuidString, thumbnail: thumbnail, serverInput: input))
          return true
        }
      }

      guard let imageType = pasteboard.availableType(from: [.tiff, .png]),
            let data = pasteboard.data(forType: imageType),
            let thumbnail = createThumbnail(from: data),
            let pngData = normalizedPNGImageData(from: data)
      else {
        return false
      }

      appendImageAttachment(thumbnail: thumbnail, imageData: pngData, mimeType: "image/png")
      return true
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
      var handled = false
      let encodeAsDataURI = shouldEncodeLocalFileImagesAsDataURI

      for provider in providers {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
          provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let urlData = data as? Data,
                  let url = URL(dataRepresentation: urlData, relativeTo: nil),
                  let thumbnail = createThumbnail(from: url),
                  let input = serverInputForImageFile(url: url, encodeAsDataURI: encodeAsDataURI)
            else { return }

            let attached = AttachedImage(id: UUID().uuidString, thumbnail: thumbnail, serverInput: input)

            DispatchQueue.main.async {
              appendAttachedImage(attached)
            }
          }
          handled = true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
          provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { data, _ in
            guard let imageData = data as? Data,
                  let thumbnail = createThumbnail(from: imageData),
                  let pngData = normalizedPNGImageData(from: imageData)
            else { return }

            DispatchQueue.main.async {
              appendImageAttachment(thumbnail: thumbnail, imageData: pngData, mimeType: "image/png")
            }
          }
          handled = true
        }
      }

      return handled
    }

    private func createThumbnail(from fileURL: URL) -> NSImage? {
      let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
      guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else { return nil }
      return createThumbnail(from: source)
    }

    private func createThumbnail(from data: Data) -> NSImage? {
      let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
      guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
      return createThumbnail(from: source)
    }

    private func createThumbnail(from source: CGImageSource) -> NSImage? {
      let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailMaxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
        return nil
      }
      return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func normalizedPNGImageData(from data: Data) -> Data? {
      let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
      guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return nil }

      let outputData = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(
        outputData,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else { return nil }

      CGImageDestinationAddImage(destination, cgImage, nil)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return outputData as Data
    }
  }
#endif
