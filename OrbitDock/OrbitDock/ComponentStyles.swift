//
//  ComponentStyles.swift
//  OrbitDock
//
//  Reusable component styles for the Cosmic Harbor design system.
//  Codifies card, badge, and button patterns used across the app.
//

import SwiftUI

// MARK: - Button Styles

/// Primary filled action button — accent or status-colored background.
///
/// Usage:
///   Button("Approve") { ... }
///     .buttonStyle(CosmicButtonStyle(color: .statusPermission))
struct CosmicButtonStyle: ButtonStyle {
  let color: Color
  var size: Size = .regular

  enum Size {
    case compact
    case regular
    case large

    var fontSize: CGFloat {
      switch self {
        case .compact: TypeScale.mini
        case .regular: TypeScale.caption
        case .large: TypeScale.body
      }
    }

    var hPad: CGFloat {
      switch self {
        case .compact: Spacing.sm
        case .regular: Spacing.md
        case .large: Spacing.lg
      }
    }

    var vPad: CGFloat {
      switch self {
        case .compact: Spacing.xs
        case .regular: Spacing.sm
        case .large: Spacing.md
      }
    }
  }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: size.fontSize, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, size.hPad)
      .padding(.vertical, size.vPad)
      .background(
        color.opacity(configuration.isPressed ? 0.7 : 1.0),
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .animation(Motion.hover, value: configuration.isPressed)
  }
}

/// Ghost button — transparent at rest, tinted text, subtle background on press.
/// For toolbar actions and inline secondary actions.
///
/// Usage:
///   Button("Cancel") { ... }
///     .buttonStyle(GhostButtonStyle(color: .textSecondary))
struct GhostButtonStyle: ButtonStyle {
  let color: Color
  var size: CosmicButtonStyle.Size = .regular

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: size.fontSize, weight: .medium))
      .foregroundStyle(color)
      .padding(.horizontal, size.hPad)
      .padding(.vertical, size.vPad)
      .background(
        configuration.isPressed ? Color.surfaceHover : Color.clear,
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .animation(Motion.hover, value: configuration.isPressed)
  }
}

/// Destructive button — red warning variant.
///
/// Usage:
///   Button("Delete") { ... }
///     .buttonStyle(DestructiveButtonStyle())
struct DestructiveButtonStyle: ButtonStyle {
  var size: CosmicButtonStyle.Size = .regular

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: size.fontSize, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, size.hPad)
      .padding(.vertical, size.vPad)
      .background(
        Color.statusError.opacity(configuration.isPressed ? 0.7 : 1.0),
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .animation(Motion.hover, value: configuration.isPressed)
  }
}

// MARK: - Card Modifier

/// Card container matching the ToolCardContainer pattern.
///
/// Usage:
///   VStack { ... }
///     .cosmicCard()
///
///   VStack { ... }
///     .cosmicCard(borderColor: .toolBash)
extension View {
  func cosmicCard(
    cornerRadius: CGFloat = Radius.lg,
    fillOpacity: Double = 0.5,
    borderColor: Color = .surfaceBorder,
    borderOpacity: Double = OpacityTier.subtle
  ) -> some View {
    self
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(Color.backgroundTertiary.opacity(fillOpacity))
      )
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(borderColor.opacity(borderOpacity), lineWidth: 1)
      )
  }
}

// MARK: - Badge Modifier

/// Badge size presets matching existing CapabilityBadge / ModelBadge patterns.
enum BadgeSize {
  /// CapabilityBadge, WorktreeBadge: icon 8pt, text 9pt
  case mini
  /// EndpointBadge: icon 8pt, text 10pt
  case compact
  /// ModelBadge regular: icon 9pt, text 10pt
  case regular

  var iconSize: CGFloat {
    switch self {
      case .mini: IconScale.xs
      case .compact: IconScale.xs
      case .regular: IconScale.sm
    }
  }

  var textSize: CGFloat {
    switch self {
      case .mini: TypeScale.mini
      case .compact: TypeScale.micro
      case .regular: TypeScale.micro
    }
  }

  var spacing: CGFloat {
    switch self {
      case .mini: 3
      case .compact: 4
      case .regular: 5
    }
  }

  var hPad: CGFloat {
    switch self {
      case .mini: 6
      case .compact: 6
      case .regular: 8
    }
  }

  var vPad: CGFloat {
    switch self {
      case .mini: 3
      case .compact: 3
      case .regular: 4
    }
  }

  var cornerRadius: CGFloat {
    switch self {
      case .mini: Radius.sm
      case .compact: Radius.sm
      case .regular: Radius.md
    }
  }
}

/// Badge shape — capsule (pill) or rounded rect.
enum BadgeShape {
  case capsule
  case roundedRect
}

/// Applies the standard Cosmic Harbor badge styling to a view.
///
/// Usage:
///   HStack(spacing: 3) {
///     Image(systemName: "bolt.fill")
///       .font(.system(size: BadgeSize.mini.iconSize, weight: .semibold))
///     Text("Fast")
///       .font(.system(size: BadgeSize.mini.textSize, weight: .semibold))
///   }
///   .cosmicBadge(color: .accent)
extension View {
  func cosmicBadge(
    color: Color,
    shape: BadgeShape = .capsule,
    backgroundOpacity: Double = OpacityTier.light
  ) -> some View {
    self
      .foregroundStyle(color)
      .background { badgeBackground(color: color, shape: shape, opacity: backgroundOpacity) }
  }

  @ViewBuilder
  private func badgeBackground(color: Color, shape: BadgeShape, opacity: Double) -> some View {
    switch shape {
      case .capsule:
        Capsule()
          .fill(color.opacity(opacity))
      case .roundedRect:
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(color.opacity(opacity))
    }
  }
}
