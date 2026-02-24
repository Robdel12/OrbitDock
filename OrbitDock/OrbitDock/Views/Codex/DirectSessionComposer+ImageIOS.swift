#if os(iOS)
  //
  //  DirectSessionComposer+ImageIOS.swift
  //  OrbitDock
  //

  import PhotosUI
  import SwiftUI
  import UIKit
  import UniformTypeIdentifiers

  extension DirectSessionComposer {
    var supportedImagePasteboardTypes: [String] {
      [
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.gif.identifier,
        "public.webp",
        UTType.heic.identifier,
      ]
    }

    var canPasteImageFromClipboard: Bool {
      let pasteboard = UIPasteboard.general
      if pasteboard.hasImages {
        return true
      }

      if let urlData = pasteboard.data(forPasteboardType: UTType.fileURL.identifier),
         let url = URL(dataRepresentation: urlData, relativeTo: nil),
         isImageFileURL(url)
      {
        return true
      }

      return pasteboard.contains(pasteboardTypes: supportedImagePasteboardTypes)
    }

    func encodedAttachmentData(from image: UIImage) -> (data: Data, mimeType: String)? {
      if let pngData = image.pngData() {
        return (pngData, "image/png")
      }
      if let jpegData = image.jpegData(compressionQuality: 0.92) {
        return (jpegData, "image/jpeg")
      }
      return nil
    }

    @discardableResult
    func appendUIImageAttachment(_ image: UIImage) -> Bool {
      guard let encoded = encodedAttachmentData(from: image) else {
        return false
      }
      let thumbnail = createThumbnail(from: image)
      appendImageAttachment(thumbnail: thumbnail, imageData: encoded.data, mimeType: encoded.mimeType)
      return true
    }

    func handlePhotoPickerSelection(_ newItems: [PhotosPickerItem]) {
      photoPickerLoadTask?.cancel()
      guard !newItems.isEmpty else { return }

      photoPickerLoadTask = Task {
        for item in newItems {
          guard !Task.isCancelled else { break }
          guard let data = try? await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
          else { continue }

          await MainActor.run {
            _ = appendUIImageAttachment(image)
          }
        }

        await MainActor.run {
          photoPickerItems = []
          photoPickerLoadTask = nil
        }
      }
    }

    func pickImages() {
      photoPickerItems = []
      Task { @MainActor in
        isPhotoPickerPresented = true
      }
    }

    func pasteImageFromClipboard() -> Bool {
      let pasteboard = UIPasteboard.general

      if let image = pasteboard.image {
        return appendUIImageAttachment(image)
      }

      if let urlData = pasteboard.data(forPasteboardType: UTType.fileURL.identifier),
         let url = URL(dataRepresentation: urlData, relativeTo: nil),
         isImageFileURL(url),
         let fileData = try? Data(contentsOf: url),
         let image = UIImage(data: fileData)
      {
        return appendUIImageAttachment(image)
      }

      for pasteboardType in supportedImagePasteboardTypes {
        guard let imageData = pasteboard.data(forPasteboardType: pasteboardType),
              let image = UIImage(data: imageData)
        else { continue }

        return appendUIImageAttachment(image)
      }

      return false
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
      var handled = false
      for provider in providers {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
          provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = if let urlData = item as? Data {
              URL(dataRepresentation: urlData, relativeTo: nil)
            } else {
              item as? URL
            }

            guard let resolvedURL = url,
                  isImageFileURL(resolvedURL),
                  let fileData = try? Data(contentsOf: resolvedURL),
                  let image = UIImage(data: fileData)
            else { return }

            DispatchQueue.main.async {
              _ = appendUIImageAttachment(image)
            }
          }
          handled = true
        } else if provider.canLoadObject(ofClass: UIImage.self) {
          provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage,
                  let pngData = image.pngData()
            else { return }

            let thumbnail = createThumbnail(from: image)
            DispatchQueue.main.async {
              appendImageAttachment(thumbnail: thumbnail, imageData: pngData, mimeType: "image/png")
            }
          }
          handled = true
        }
      }
      return handled
    }

    func createThumbnail(from image: UIImage) -> UIImage {
      let size = CGSize(width: 80, height: 80)
      let renderer = UIGraphicsImageRenderer(size: size)
      return renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
    }
  }
#endif
