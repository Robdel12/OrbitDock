//
//  MessageImageView.swift
//  OrbitDock
//
//  Renders a grid of message images with loading states and tap-to-fullscreen.
//

import SwiftUI

struct MessageImageView: View {
  let images: [MessageImage]
  let imageLoader: ImageLoader
  let maxWidth: CGFloat

  @State private var loadedImages: [String: PlatformImage] = [:]
  @State private var failedImageIDs: Set<String> = []
  @State private var fullscreenIndex: Int?

  var body: some View {
    if !images.isEmpty {
      let columns = images.count == 1
        ? [GridItem(.flexible())]
        : [GridItem(.flexible()), GridItem(.flexible())]

      LazyVGrid(columns: columns, spacing: Spacing.sm) {
        ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
          thumbnailView(image, index: index)
        }
      }
      .frame(maxWidth: maxWidth)
      .task(id: imageIDs) {
        await loadAll()
      }
      .sheet(item: $fullscreenIndex) { index in
        MessageImageFullscreen(
          images: images,
          imageLoader: imageLoader,
          currentIndex: index
        )
      }
    }
  }

  private var imageIDs: [String] {
    images.map(\.id)
  }

  @ViewBuilder
  private func thumbnailView(_ image: MessageImage, index: Int) -> some View {
    let maxHeight: CGFloat = 240

    Group {
      if let platformImage = loadedImages[image.id] {
        Image(platformImage: platformImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxHeight: maxHeight)
      } else if failedImageIDs.contains(image.id) {
        imageUnavailableView(height: thumbnailPlaceholderHeight(image, maxHeight: maxHeight))
      } else {
        RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
          .fill(Color.backgroundTertiary.opacity(0.5))
          .frame(height: thumbnailPlaceholderHeight(image, maxHeight: maxHeight))
          .overlay {
            ProgressView()
              .controlSize(.small)
          }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      guard loadedImages[image.id] != nil else { return }
      fullscreenIndex = index
    }
  }

  private func imageUnavailableView(height: CGFloat) -> some View {
    VStack(spacing: Spacing.xs) {
      Image(systemName: "photo.badge.exclamationmark")
        .font(.system(size: IconScale.lg, weight: .semibold))
        .foregroundStyle(Color.textQuaternary)
      Text("Image unavailable")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
    }
    .frame(maxWidth: .infinity)
    .frame(height: height)
    .background(Color.backgroundTertiary.opacity(0.5))
  }

  private func thumbnailPlaceholderHeight(_ image: MessageImage, maxHeight: CGFloat) -> CGFloat {
    guard let w = image.pixelWidth, let h = image.pixelHeight, w > 0, h > 0 else {
      return 120
    }
    let aspect = CGFloat(h) / CGFloat(w)
    return min(maxHeight, maxWidth * aspect)
  }

  private func loadAll() async {
    let validIDs = Set(images.map(\.id))
    loadedImages = loadedImages.filter { validIDs.contains($0.key) }
    failedImageIDs = failedImageIDs.filter { validIDs.contains($0) }

    await withTaskGroup(of: (String, PlatformImage?).self) { group in
      for image in images where loadedImages[image.id] == nil && !failedImageIDs.contains(image.id) {
        group.addTask {
          let loaded = await imageLoader.load(image)
          return (image.id, loaded)
        }
      }
      for await (id, image) in group {
        if let image {
          loadedImages[id] = image
          failedImageIDs.remove(id)
        } else {
          failedImageIDs.insert(id)
        }
      }
    }
  }
}

extension Int: @retroactive Identifiable {
  public var id: Int {
    self
  }
}
