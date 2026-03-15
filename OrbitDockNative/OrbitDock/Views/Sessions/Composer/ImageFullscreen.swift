//
//  ImageFullscreen.swift
//  OrbitDock
//
//  Fullscreen image viewer — uses ImageLoader for all source types.
//

import SwiftUI

struct ImageFullscreen: View {
  let images: [MessageImage]
  let imageLoader: ImageLoader
  @State var currentIndex: Int
  @Environment(\.dismiss) private var dismiss

  @State private var loadedImages: [String: PlatformImage] = [:]

  private var currentImage: MessageImage {
    images[currentIndex]
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let platformImage = loadedImages[currentImage.id] {
        platformImageView(platformImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(Spacing.lg)
          .id(currentIndex)
      } else {
        ProgressView()
          .tint(.white)
      }

      // Top bar
      VStack {
        HStack {
          if images.count > 1 {
            Text("\(currentIndex + 1) of \(images.count)")
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(.white.opacity(0.9))
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm_)
              .background(.black.opacity(0.5), in: Capsule())
          }

          Spacer()

          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 22))
              .foregroundStyle(.white.opacity(0.7))
          }
          .buttonStyle(.plain)
        }
        .padding(Spacing.lg)

        Spacer()

        // Navigation arrows for multi-image
        if images.count > 1 {
          HStack {
            Button {
              currentIndex = max(0, currentIndex - 1)
            } label: {
              Image(systemName: "chevron.left.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(currentIndex > 0 ? 0.8 : 0.3))
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == 0)

            Spacer()

            Button {
              currentIndex = min(images.count - 1, currentIndex + 1)
            } label: {
              Image(systemName: "chevron.right.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(currentIndex < images.count - 1 ? 0.8 : 0.3))
            }
            .buttonStyle(.plain)
            .disabled(currentIndex >= images.count - 1)
          }
          .padding(.horizontal, Spacing.xl)
          .padding(.bottom, Spacing.xl)
        }
      }
    }
    .frame(minWidth: 400, minHeight: 300)
    .task(id: currentImage.id) {
      await loadCurrent()
    }
  }

  private func loadCurrent() async {
    let image = currentImage
    guard loadedImages[image.id] == nil else { return }
    if let loaded = await imageLoader.load(image) {
      loadedImages[image.id] = loaded
    }
  }

  private func platformImageView(_ image: PlatformImage) -> Image {
    #if os(macOS)
      Image(nsImage: image)
    #else
      Image(uiImage: image)
    #endif
  }
}
