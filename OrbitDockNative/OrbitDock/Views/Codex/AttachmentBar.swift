//
//  AttachmentBar.swift
//  OrbitDock
//
//  Rich attachment tray for composer images and file mentions.
//

import SwiftUI

struct AttachedImage: Identifiable, Equatable {
  let id: String
  let thumbnail: PlatformImage
  let uploadData: Data
  let uploadMimeType: String
  let displayName: String?
  let pixelWidth: Int?
  let pixelHeight: Int?

  static func == (lhs: AttachedImage, rhs: AttachedImage) -> Bool {
    lhs.id == rhs.id
  }
}

struct AttachedMention: Identifiable, Equatable {
  let id: String
  let name: String
  let path: String
}

struct AttachmentBar: View {
  @Binding var images: [AttachedImage]
  @Binding var mentions: [AttachedMention]
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var previewSelection: AttachmentPreviewSelection?

  private var isCompactLayout: Bool {
    horizontalSizeClass == .compact
  }

  private var totalImageBytes: Int {
    images.reduce(0) { $0 + $1.uploadData.count }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        if !images.isEmpty {
          Label("\(images.count) image\(images.count == 1 ? "" : "s")", systemImage: "photo.on.rectangle.angled")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
        }

        if !images.isEmpty {
          Text(byteCountLabel(totalImageBytes))
            .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }

        if !mentions.isEmpty {
          Text("•")
            .foregroundStyle(Color.textQuaternary)
          Label("\(mentions.count) mention\(mentions.count == 1 ? "" : "s")", systemImage: "paperclip")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
        }

        Spacer(minLength: 0)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: Spacing.md) {
          ForEach(images.indices, id: \.self) { index in
            imageCard(images[index], index: index)
              .transition(.move(edge: .top).combined(with: .opacity))
          }

          ForEach(mentions) { mention in
            mentionCard(mention)
              .transition(.move(edge: .top).combined(with: .opacity))
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(isCompactLayout ? 0.72 : 0.58))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
    )
    .themeShadow(Shadow.sm)
    .sheet(item: $previewSelection) { selection in
      ImageFullscreen(
        images: previewImages,
        currentIndex: selection.index
      )
    }
  }

  private var previewImages: [MessageImage] {
    images.map { image in
      MessageImage(
        id: image.id,
        source: .inlineData(image.uploadData),
        mimeType: image.uploadMimeType,
        byteCount: image.uploadData.count,
        pixelWidth: image.pixelWidth,
        pixelHeight: image.pixelHeight
      )
    }
  }

  private func imageCard(_ image: AttachedImage, index: Int) -> some View {
    Button {
      previewSelection = AttachmentPreviewSelection(index: index)
    } label: {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        ZStack(alignment: .topTrailing) {
          Group {
            #if os(macOS)
              Image(nsImage: image.thumbnail)
                .resizable()
            #else
              Image(uiImage: image.thumbnail)
                .resizable()
            #endif
          }
          .aspectRatio(contentMode: .fill)
          .frame(width: 112, height: 84)
          .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
              .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
          )

          removeButton {
            removeImage(withID: image.id)
          }
          .padding(Spacing.xxs)
        }

        VStack(alignment: .leading, spacing: 3) {
          Text(image.displayName ?? image.uploadMimeType.replacingOccurrences(of: "image/", with: "").uppercased())
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)

          Text(imageMetadata(image))
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .lineLimit(1)
        }
        .frame(width: 112, alignment: .leading)
      }
      .padding(Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .fill(Color.backgroundSecondary.opacity(0.78))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
      )
      .themeShadow(Shadow.sm)
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Preview Image") {
        previewSelection = AttachmentPreviewSelection(index: index)
      }
      Button("Remove Image", role: .destructive) {
        removeImage(withID: image.id)
      }
    }
  }

  private func mentionCard(_ mention: AttachedMention) -> some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      Image(systemName: fileIcon(for: mention.name))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.accent)

      VStack(alignment: .leading, spacing: 2) {
        Text(mention.name)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
          .lineLimit(1)
        Text(mention.path)
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      removeButton {
        removeMention(withID: mention.id)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm)
    .frame(width: 240, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.accent.opacity(0.09))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(Color.accent.opacity(0.16), lineWidth: 1)
    )
    .themeShadow(Shadow.sm)
    .contextMenu {
      Button("Remove Mention", role: .destructive) {
        removeMention(withID: mention.id)
      }
    }
  }

  private func imageMetadata(_ image: AttachedImage) -> String {
    let size = byteCountLabel(image.uploadData.count)
    guard let width = image.pixelWidth, let height = image.pixelHeight, width > 0, height > 0 else {
      return size
    }
    return "\(width)×\(height) • \(size)"
  }

  private func byteCountLabel(_ bytes: Int) -> String {
    if bytes < 1_024 {
      return "\(bytes) B"
    }
    if bytes < 1_024 * 1_024 {
      return String(format: "%.1f KB", Double(bytes) / 1_024)
    }
    return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
  }

  private func removeImage(withID id: String) {
    withAnimation(Motion.gentle) {
      images.removeAll { $0.id == id }
    }
  }

  private func removeMention(withID id: String) {
    withAnimation(Motion.gentle) {
      mentions.removeAll { $0.id == id }
    }
  }

  private func removeButton(action: @escaping () -> Void) -> some View {
    #if os(iOS)
      let buttonSize: CGFloat = 22
      let iconSize: CGFloat = 10
    #else
      let buttonSize: CGFloat = 18
      let iconSize: CGFloat = 9
    #endif

    return Button(action: action) {
      ZStack {
        Circle()
          .fill(.black.opacity(0.72))
        Image(systemName: "xmark")
          .font(.system(size: iconSize, weight: .bold))
          .foregroundStyle(Color.white.opacity(0.92))
      }
      .frame(width: buttonSize, height: buttonSize)
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .themeShadow(Shadow.sm)
  }

  private func fileIcon(for name: String) -> String {
    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
    switch ext {
      case "swift": return "swift"
      case "rs": return "gearshape.2"
      case "js", "ts", "jsx", "tsx": return "curlybraces"
      case "py": return "chevron.left.forwardslash.chevron.right"
      case "sh", "bash", "zsh": return "terminal"
      case "json", "yaml", "yml", "toml": return "doc.text"
      case "md", "txt": return "doc.plaintext"
      case "html", "css": return "globe"
      default: return "doc"
    }
  }
}

private struct AttachmentPreviewSelection: Identifiable {
  let index: Int

  var id: Int { index }
}
