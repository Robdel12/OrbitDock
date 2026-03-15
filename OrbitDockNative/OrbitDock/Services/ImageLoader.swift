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
      cache.setObject(loaded, forKey: image.id as NSString)
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
    #if os(macOS)
      NSImage(contentsOfFile: path)
    #else
      UIImage(contentsOfFile: path)
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
    #if os(macOS)
      NSImage(data: data)
    #else
      UIImage(data: data)
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
      netLog(.error, cat: .api, "Failed to download image attachment",
             data: ["sessionId": ref.sessionId, "attachmentId": ref.attachmentId,
                    "error": error.localizedDescription])
      return nil
    }
  }
}
