//
//  DirectSessionComposer+ImageShared.swift
//  OrbitDock
//

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension DirectSessionComposer {
  var shouldEncodeLocalFileImagesAsDataURI: Bool {
    false
  }

  @discardableResult
  func appendAttachedImage(_ attached: AttachedImage) -> Bool {
    let isDuplicate = attachedImages.contains {
      $0.uploadMimeType == attached.uploadMimeType
        && $0.uploadData == attached.uploadData
    }
    guard !isDuplicate else { return false }

    let usedRawBytes = ComposerImageAttachmentPolicy.usedRawBytes(
      attachedImages.map(\.uploadData.count)
    )
    let validation = ComposerImageAttachmentPolicy.validateAddition(
      existingCount: attachedImages.count,
      usedRawBytes: usedRawBytes,
      candidateRawBytes: attached.uploadData.count
    )
    guard validation == .allowed else {
      errorMessage = ComposerImageAttachmentPolicy.message(for: validation)
      Platform.services.playHaptic(.error)
      requestComposerFocus()
      return false
    }

    withAnimation(Motion.gentle) {
      if let errorMessage, ComposerImageAttachmentPolicy.isPolicyMessage(errorMessage) {
        self.errorMessage = nil
      }
      attachedImages.append(attached)
    }
    return true
  }

  @discardableResult
  func appendImageAttachment(
    thumbnail: PlatformImage,
    imageData: Data,
    mimeType: String,
    displayName: String? = nil
  ) -> Bool {
    guard let preparedPayload = optimizedAttachmentPayload(
      imageData: imageData,
      mimeType: mimeType,
      maxBytes: ComposerImageAttachmentPolicy.maxSingleImageBytes
    ) else {
      errorMessage = ComposerImageAttachmentPolicy.message(
        for: .tooLarge(maxBytes: ComposerImageAttachmentPolicy.maxSingleImageBytes)
      )
      Platform.services.playHaptic(.error)
      requestComposerFocus()
      return false
    }

    let dimensions = imagePixelDimensions(from: preparedPayload.data)
    let attached = AttachedImage(
      id: UUID().uuidString,
      thumbnail: thumbnail,
      uploadData: preparedPayload.data,
      uploadMimeType: preparedPayload.mimeType,
      displayName: displayName,
      pixelWidth: dimensions.width,
      pixelHeight: dimensions.height
    )
    return appendAttachedImage(attached)
  }

  func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
      case "png": "image/png"
      case "jpg", "jpeg": "image/jpeg"
      case "gif": "image/gif"
      case "webp": "image/webp"
      case "heic": "image/heic"
      case "heif": "image/heif"
      case "svg": "image/svg+xml"
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

  @discardableResult
  func appendLocalFileImage(
    url: URL,
    thumbnail: PlatformImage,
    encodeAsDataURI: Bool
  ) -> Bool {
    _ = encodeAsDataURI
    guard let data = try? Data(contentsOf: url) else { return false }
    return appendImageAttachment(
      thumbnail: thumbnail,
      imageData: data,
      mimeType: mimeType(for: url),
      displayName: url.lastPathComponent
    )
  }

  func optimizedAttachmentPayload(
    imageData: Data,
    mimeType: String,
    maxBytes: Int
  ) -> (data: Data, mimeType: String)? {
    guard maxBytes > 0 else { return nil }
    guard imageData.count > maxBytes else {
      return (imageData, mimeType)
    }

    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(imageData as CFData, sourceOptions) else {
      return nil
    }

    let candidatePixelSizes = optimizedAttachmentPixelSizes(for: source)
    let prefersLossless = prefersLosslessAttachmentEncoding(for: mimeType)
    let jpegQualities: [CGFloat] = [0.9, 0.82, 0.74, 0.66, 0.58, 0.5, 0.42]

    for pixelSize in candidatePixelSizes {
      guard let cgImage = downsampledAttachmentImage(from: source, maxPixelSize: pixelSize) else {
        continue
      }

      if prefersLossless,
         let pngData = encodedAttachmentData(from: cgImage, type: .png),
         pngData.count <= maxBytes
      {
        return (pngData, "image/png")
      }

      for quality in jpegQualities {
        guard let jpegData = encodedAttachmentData(
          from: cgImage,
          type: .jpeg,
          compressionQuality: quality
        ) else { continue }

        if jpegData.count <= maxBytes {
          return (jpegData, "image/jpeg")
        }
      }

      if !prefersLossless,
         let pngData = encodedAttachmentData(from: cgImage, type: .png),
         pngData.count <= maxBytes
      {
        return (pngData, "image/png")
      }
    }

    return nil
  }

  func optimizedAttachmentPixelSizes(for source: CGImageSource) -> [Int] {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let originalMaxDimension = max(width, height)
    let baselineSizes = [2_400, 2_000, 1_600, 1_280, 1_024, 768, 640, 512, 384]

    var candidates: [Int] = []
    var seen: Set<Int> = []

    let seedSizes = if originalMaxDimension > 0 {
      baselineSizes.map { min($0, originalMaxDimension) }
    } else {
      baselineSizes
    }

    for size in seedSizes where size > 0 && !seen.contains(size) {
      seen.insert(size)
      candidates.append(size)
    }

    return candidates
  }

  func prefersLosslessAttachmentEncoding(for mimeType: String) -> Bool {
    switch mimeType {
      case "image/png", "image/gif", "image/svg+xml":
        true
      default:
        false
    }
  }

  func downsampledAttachmentImage(
    from source: CGImageSource,
    maxPixelSize: Int
  ) -> CGImage? {
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
  }

  func encodedAttachmentData(
    from cgImage: CGImage,
    type: UTType,
    compressionQuality: CGFloat? = nil
  ) -> Data? {
    let outputData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      outputData,
      type.identifier as CFString,
      1,
      nil
    ) else { return nil }

    var properties: [CFString: Any] = [:]
    if let compressionQuality, type == .jpeg {
      properties[kCGImageDestinationLossyCompressionQuality] = compressionQuality
    }

    CGImageDestinationAddImage(
      destination,
      cgImage,
      properties.isEmpty ? nil : properties as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return outputData as Data
  }

  func imagePixelDimensions(from data: Data) -> (width: Int?, height: Int?) {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      return (nil, nil)
    }

    return (
      properties[kCGImagePropertyPixelWidth] as? Int,
      properties[kCGImagePropertyPixelHeight] as? Int
    )
  }
}
