#if os(macOS)
  //
  //  DirectSessionComposer+ImageMacOS.swift
  //  OrbitDock
  //

  import AppKit
  import SwiftUI
  import UniformTypeIdentifiers

  extension DirectSessionComposer {
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
        guard let nsImage = NSImage(contentsOf: url),
              let input = serverInputForImageFile(url: url, encodeAsDataURI: encodeAsDataURI)
        else { continue }
        let thumbnail = createThumbnail(from: nsImage)
        appendAttachedImage(AttachedImage(id: UUID().uuidString, thumbnail: thumbnail, serverInput: input))
      }
    }

    func pasteImageFromClipboard() -> Bool {
      let pasteboard = NSPasteboard.general
      let encodeAsDataURI = shouldEncodeLocalFileImagesAsDataURI

      if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
        for url in urls where url.isFileURL && isImageFileURL(url) {
          guard let nsImage = NSImage(contentsOf: url),
                let input = serverInputForImageFile(url: url, encodeAsDataURI: encodeAsDataURI)
          else { continue }

          let thumbnail = createThumbnail(from: nsImage)
          appendAttachedImage(AttachedImage(id: UUID().uuidString, thumbnail: thumbnail, serverInput: input))
          return true
        }
      }

      guard let imageType = pasteboard.availableType(from: [.tiff, .png]),
            let data = pasteboard.data(forType: imageType),
            let nsImage = NSImage(data: data),
            let tiffData = nsImage.tiffRepresentation,
            let bitmapRep = NSBitmapImageRep(data: tiffData),
            let pngData = bitmapRep.representation(using: .png, properties: [:])
      else {
        return false
      }

      let thumbnail = createThumbnail(from: nsImage)
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
                  let nsImage = NSImage(contentsOf: url),
                  let input = serverInputForImageFile(url: url, encodeAsDataURI: encodeAsDataURI)
            else { return }

            let thumbnail = createThumbnail(from: nsImage)
            let attached = AttachedImage(id: UUID().uuidString, thumbnail: thumbnail, serverInput: input)

            DispatchQueue.main.async {
              appendAttachedImage(attached)
            }
          }
          handled = true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
          provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { data, _ in
            guard let imageData = data as? Data,
                  let nsImage = NSImage(data: imageData),
                  let tiffData = nsImage.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmapRep.representation(using: .png, properties: [:])
            else { return }

            let thumbnail = createThumbnail(from: nsImage)
            DispatchQueue.main.async {
              appendImageAttachment(thumbnail: thumbnail, imageData: pngData, mimeType: "image/png")
            }
          }
          handled = true
        }
      }

      return handled
    }

    func createThumbnail(from image: NSImage) -> NSImage {
      let size = NSSize(width: 80, height: 80)
      let thumbnail = NSImage(size: size)
      thumbnail.lockFocus()
      NSGraphicsContext.current?.imageInterpolation = .high
      image.draw(
        in: NSRect(origin: .zero, size: size),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1.0
      )
      thumbnail.unlockFocus()
      return thumbnail
    }
  }
#endif
