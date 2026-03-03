//
//  AttachmentBar.swift
//  OrbitDock
//
//  Horizontal strip showing attached images and file mentions
//  above the input row, with remove buttons.
//

import SwiftUI

struct AttachedImage: Identifiable, Equatable {
  let id: String
  let thumbnail: PlatformImage
  let serverInput: ServerImageInput

  static func == (lhs: AttachedImage, rhs: AttachedImage) -> Bool {
    lhs.id == rhs.id
  }
}

struct AttachedMention: Identifiable, Equatable {
  let id: String // relative path
  let name: String // filename
  let path: String // absolute path
}

struct AttachmentBar: View {
  @Binding var images: [AttachedImage]
  @Binding var mentions: [AttachedMention]
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isCompactLayout: Bool {
    horizontalSizeClass == .compact
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.sm) {
        if !images.isEmpty {
          attachmentCountBadge(
            icon: "photo",
            count: images.count,
            tint: Color.accent
          )
        }
        if !mentions.isEmpty {
          attachmentCountBadge(
            icon: "paperclip",
            count: mentions.count,
            tint: Color.composerPrompt
          )
        }

        ForEach(images) { image in
          imageChip(image)
            .transition(.scale.combined(with: .opacity))
        }
        ForEach(mentions) { mention in
          mentionChip(mention)
            .transition(.scale.combined(with: .opacity))
        }
      }
      .padding(.horizontal, isCompactLayout ? Spacing.md_ : Spacing.sm)
      .padding(.vertical, Spacing.xxs)
      .animation(Motion.gentle, value: images.count)
      .animation(Motion.gentle, value: mentions.count)
    }
    .padding(.horizontal, isCompactLayout ? Spacing.xs : 0)
    .padding(.vertical, isCompactLayout ? Spacing.gap : 0)
    .background(
      Group {
        if isCompactLayout {
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(0.5))
        }
      }
    )
    .overlay(
      Group {
        if isCompactLayout {
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        }
      }
    )
    .padding(.horizontal, Spacing.md)
    .padding(.top, isCompactLayout ? Spacing.gap : 1)
  }

  private func imageChip(_ image: AttachedImage) -> some View {
    #if os(iOS)
      let chipSize: CGFloat = 44
    #else
      let chipSize: CGFloat = 38
    #endif

    return ZStack(alignment: .topTrailing) {
      #if os(macOS)
        Image(nsImage: image.thumbnail)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: chipSize, height: chipSize)
          .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
      #else
        Image(uiImage: image.thumbnail)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: chipSize, height: chipSize)
          .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
      #endif

      removeButton {
        removeImage(withID: image.id)
      }
      .padding(Spacing.xxs)
      .zIndex(1)
    }
    .frame(width: chipSize, height: chipSize)
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .strokeBorder(Color.white.opacity(isCompactLayout ? 0.07 : 0.05), lineWidth: 1)
    )
    .themeShadow(Shadow.sm)
    .contentShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
    .contextMenu {
      Button("Remove Image", role: .destructive) {
        removeImage(withID: image.id)
      }
    }
  }

  private func mentionChip(_ mention: AttachedMention) -> some View {
    HStack(spacing: 5) {
      Image(systemName: fileIcon(for: mention.name))
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.accent)

      Text(mention.name)
        .font(.caption2.weight(.medium))
        .lineLimit(1)

      Button {
        removeMention(withID: mention.id)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.textSecondary.opacity(0.9))
      }
      .buttonStyle(.plain)
      .contentShape(Circle())
      .padding(.vertical, 1)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, isCompactLayout ? Spacing.xs : Spacing.gap)
    .background(Color.accent.opacity(isCompactLayout ? 0.12 : 0.08))
    .overlay {
      if isCompactLayout {
        Capsule()
          .strokeBorder(Color.accent.opacity(0.22), lineWidth: 1)
      }
    }
    .clipShape(Capsule())
    .themeShadow(Shadow.sm)
    .help(mention.path)
    .contextMenu {
      Button("Remove Mention", role: .destructive) {
        removeMention(withID: mention.id)
      }
    }
  }

  private func attachmentCountBadge(icon: String, count: Int, tint: Color) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: 9, weight: .semibold))
      Text("\(count)")
        .font(.system(size: 10, weight: .bold, design: .monospaced))
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 7)
    .padding(.vertical, Spacing.xs)
    .background(tint.opacity(0.14), in: Capsule())
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
