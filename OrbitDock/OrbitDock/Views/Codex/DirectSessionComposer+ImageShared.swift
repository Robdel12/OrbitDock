//
//  DirectSessionComposer+ImageShared.swift
//  OrbitDock
//

import SwiftUI
import UniformTypeIdentifiers

extension DirectSessionComposer {
  var shouldEncodeLocalFileImagesAsDataURI: Bool {
    ServerConnection.shared.isRemoteConnection
  }

  func appendAttachedImage(_ attached: AttachedImage) {
    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
      attachedImages.append(attached)
    }
  }

  func appendImageAttachment(
    thumbnail: PlatformImage,
    imageData: Data,
    mimeType: String
  ) {
    let input = ServerImageInput(inputType: "url", value: dataURI(from: imageData, mimeType: mimeType))
    appendAttachedImage(AttachedImage(
      id: UUID().uuidString,
      thumbnail: thumbnail,
      serverInput: input
    ))
  }

  func dataURI(from data: Data, mimeType: String) -> String {
    let base64 = data.base64EncodedString()
    return "data:\(mimeType);base64,\(base64)"
  }

  func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
      case "png": "image/png"
      case "jpg", "jpeg": "image/jpeg"
      case "gif": "image/gif"
      case "webp": "image/webp"
      case "bmp": "image/bmp"
      case "tiff", "tif": "image/tiff"
      default: "image/png"
    }
  }

  func isImageFileURL(_ url: URL) -> Bool {
    guard !url.pathExtension.isEmpty else { return false }
    guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
      return false
    }
    return type.conforms(to: .image)
  }

  func serverInputForImageFile(url: URL, encodeAsDataURI: Bool) -> ServerImageInput? {
    if encodeAsDataURI {
      guard let data = try? Data(contentsOf: url) else { return nil }
      return ServerImageInput(inputType: "url", value: dataURI(from: data, mimeType: mimeType(for: url)))
    }
    return ServerImageInput(inputType: "path", value: url.path)
  }
}
