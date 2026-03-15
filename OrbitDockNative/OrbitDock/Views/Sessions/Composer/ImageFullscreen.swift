//
//  ImageFullscreen.swift
//  OrbitDock
//
//  Fullscreen image viewer for attachment previews.
//

import SwiftUI

struct ImageFullscreen: View {
  let images: [MessageImage]
  @State var currentIndex: Int
  @Environment(\.dismiss) private var dismiss

  private var currentImage: MessageImage {
    images[currentIndex]
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let platformImage = loadImage(currentImage) {
        #if os(macOS)
          let img = Image(nsImage: platformImage)
        #else
          let img = Image(uiImage: platformImage)
        #endif
        img
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
  }

  private func loadImage(_ image: MessageImage) -> PlatformImage? {
    switch image.source {
    case let .filePath(path):
      #if os(macOS)
        return NSImage(contentsOfFile: path)
      #else
        return UIImage(contentsOfFile: path)
      #endif
    case let .inlineData(data):
      #if os(macOS)
        return NSImage(data: data)
      #else
        return UIImage(data: data)
      #endif
    case let .dataURI(uri):
      guard let commaIndex = uri.firstIndex(of: ","),
            let data = Data(base64Encoded: String(uri[uri.index(after: commaIndex)...]))
      else { return nil }
      #if os(macOS)
        return NSImage(data: data)
      #else
        return UIImage(data: data)
      #endif
    case .serverAttachment:
      // TODO: Load via Kingfisher when added
      return nil
    }
  }
}
