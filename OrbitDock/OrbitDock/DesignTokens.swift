//
//  DesignTokens.swift
//  OrbitDock
//
//  Extended design tokens for the Cosmic Harbor design system.
//  Complements Theme.swift with icon, shadow, motion, and line-height scales.
//

import SwiftUI

// MARK: - Icon Scale

/// Formalized icon size tiers — replaces ad-hoc 7-16pt mix across the app.
enum IconScale {
  /// Mini badge decorations (8pt)
  static let xs: CGFloat = 8
  /// Compact badge icons, chevrons (9pt)
  static let sm: CGFloat = 9
  /// Standard UI icons in tool cards (10pt)
  static let md: CGFloat = 10
  /// Labels, section header icons (11pt)
  static let lg: CGFloat = 11
  /// Banners, status indicators (12pt)
  static let xl: CGFloat = 12
  /// Dialogs, empty states (14pt)
  static let xxl: CGFloat = 14
  /// Onboarding, hero moments (16pt)
  static let hero: CGFloat = 16
}

// MARK: - Line Height

/// Line height tokens for native AppKit/UIKit cell layout.
/// SwiftUI views mostly derive line height from the font; use these
/// when doing manual frame/constraint calculations.
enum LineHeight {
  /// Micro text, compact list items (10pt text)
  static let tight: CGFloat = 14
  /// Standard body text (13pt text)
  static let body: CGFloat = 18
  /// Code blocks, monospaced content (13-14pt text)
  static let code: CGFloat = 21
  /// Chat body, prose reading (15pt text)
  static let reading: CGFloat = 22
  /// Headlines (22pt text)
  static let heading: CGFloat = 28
}

// MARK: - Shadow

/// Shadow tokens — consolidates ad-hoc shadow calls into semantic tiers.
struct ShadowToken {
  let color: Color
  let radius: CGFloat
  let x: CGFloat
  let y: CGFloat
}

enum Shadow {
  /// Subtle lift for chips, small badges
  static let sm = ShadowToken(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
  /// Standard card/panel elevation
  static let md = ShadowToken(color: .black.opacity(0.22), radius: 6, x: 0, y: 2)
  /// Floating panels, modals, toasts
  static let lg = ShadowToken(color: .black.opacity(0.30), radius: 12, x: 0, y: 4)

  /// Status glow — use with a status/accent color instead of black.
  static func glow(color: Color, intensity: Double = 0.4) -> ShadowToken {
    ShadowToken(color: color.opacity(intensity), radius: 4, x: 0, y: 0)
  }
}

extension View {
  /// Apply a design-system shadow token.
  func themeShadow(_ token: ShadowToken) -> some View {
    self.shadow(color: token.color, radius: token.radius, x: token.x, y: token.y)
  }
}

// MARK: - Motion

/// Animation tokens — consolidates 15+ spring combos into semantic presets.
///
/// Mapping from old values:
///   spring(0.20, 0.90) → .snappy
///   spring(0.25, 0.80-0.90) → .standard
///   spring(0.30-0.35, 0.80) → .gentle
///   spring(0.30, 0.70) → .bouncy
enum Motion {
  /// Instant feedback: hover, press, toggle
  static let snappy = Animation.spring(response: 0.20, dampingFraction: 0.90)
  /// Standard UI: expand/collapse, selection, navigation
  static let standard = Animation.spring(response: 0.25, dampingFraction: 0.85)
  /// Comfortable: panel slides, content entry, messages
  static let gentle = Animation.spring(response: 0.35, dampingFraction: 0.80)
  /// Playful: picker selection, sheet present
  static let bouncy = Animation.spring(response: 0.30, dampingFraction: 0.70)

  /// Micro ease for hover opacity transitions
  static let hover = Animation.easeOut(duration: 0.15)
  /// Fade in/out for loading states
  static let fade = Animation.easeOut(duration: 0.25)
}
