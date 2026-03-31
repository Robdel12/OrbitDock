//
//  ImageLoader.swift
//  OrbitDock
//
//  Resolves MessageImage.Source → PlatformImage with in-memory caching.
//  Single source of truth for all image loading in the app.
//

import Foundation
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

final class ImageLoader: Sendable {
  private let cache = NSCache<NSString, PlatformImage>()
  private let conversationClient: ConversationClient
  private static let maxDecodeDimension: CGFloat = 2_048

  init(conversationClient: ConversationClient) {
    self.conversationClient = conversationClient
    cache.countLimit = 100
    cache.totalCostLimit = 50 * 1_024 * 1_024 // 50 MB
  }

  /// Synchronous cache lookup — returns immediately if cached, nil otherwise.
  func cachedImage(for id: String) -> PlatformImage? {
    cache.object(forKey: id as NSString)
  }

  /// Loads and caches a platform image from any MessageImage source.
  func load(_ image: MessageImage) async -> PlatformImage? {
    if let cached = cachedImage(for: image.id) {
      return cached
    }

    let loaded = await resolve(image)
    if let loaded {
      cache.setObject(loaded, forKey: image.id as NSString, cost: estimateCacheCost(for: loaded))
    }
    return loaded
  }

  /// Preload a batch of images into cache.
  func prefetch(_ images: [MessageImage]) async {
    await withTaskGroup(of: Void.self) { group in
      for image in images where cachedImage(for: image.id) == nil {
        group.addTask { [self] in
          _ = await load(image)
        }
      }
    }
  }

  // MARK: - Source Resolution

  private func resolve(_ image: MessageImage) async -> PlatformImage? {
    switch image.source {
      case let .filePath(path):
        loadFromFile(path)
      case let .dataURI(uri):
        decodeDataURI(uri)
      case let .inlineData(data):
        decodePlatformImage(from: data)
      case let .serverAttachment(ref):
        await downloadAttachment(ref)
    }
  }

  private func loadFromFile(_ path: String) -> PlatformImage? {
    if let downsampled = ImageDecoding.downsampledImage(fromFile: path, maxDimension: Self.maxDecodeDimension) {
      return downsampled
    }
    #if os(macOS)
      return NSImage(contentsOfFile: path)
    #else
      return UIImage(contentsOfFile: path)
    #endif
  }

  private func decodeDataURI(_ uri: String) -> PlatformImage? {
    guard uri.hasPrefix("data:"),
          let commaIndex = uri.firstIndex(of: ","),
          let data = Data(base64Encoded: String(uri[uri.index(after: commaIndex)...]))
    else { return nil }
    return decodePlatformImage(from: data)
  }

  private func decodePlatformImage(from data: Data) -> PlatformImage? {
    if let downsampled = ImageDecoding.downsampledImage(fromData: data, maxDimension: Self.maxDecodeDimension) {
      return downsampled
    }
    #if os(macOS)
      return NSImage(data: data)
    #else
      return UIImage(data: data)
    #endif
  }

  private func downloadAttachment(_ ref: ServerAttachmentImageReference) async -> PlatformImage? {
    do {
      let data = try await conversationClient.downloadImageAttachment(
        sessionId: ref.sessionId,
        attachmentId: ref.attachmentId
      )
      return decodePlatformImage(from: data)
    } catch {
      netLog(
        .error,
        cat: .api,
        "Failed to download image attachment",
        data: [
          "sessionId": ref.sessionId,
          "attachmentId": ref.attachmentId,
          "error": error.localizedDescription,
        ]
      )
      return nil
    }
  }

  private func estimateCacheCost(for image: PlatformImage) -> Int {
    #if os(macOS)
      if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        return max(cgImage.bytesPerRow * cgImage.height, 1)
      }
      let width = max(Int(image.size.width.rounded(.up)), 1)
      let height = max(Int(image.size.height.rounded(.up)), 1)
      return width * height * 4
    #else
      if let cgImage = image.cgImage {
        return max(cgImage.bytesPerRow * cgImage.height, 1)
      }
      let width = max(Int((image.size.width * image.scale).rounded(.up)), 1)
      let height = max(Int((image.size.height * image.scale).rounded(.up)), 1)
      return width * height * 4
    #endif
  }
}
