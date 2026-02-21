//
//  PlatformTypes.swift
//  OrbitDock
//
//  Cross-platform type aliases and helpers for AppKit/UIKit.
//  Allows NativeMarkdown views and cell models to compile on both platforms.
//

import SwiftUI

#if os(macOS)
  import AppKit

  typealias PlatformFont = NSFont
  typealias PlatformColor = NSColor
  typealias PlatformView = NSView
  typealias PlatformImage = NSImage
#else
  import UIKit

  typealias PlatformFont = UIFont
  typealias PlatformColor = UIColor
  typealias PlatformView = UIView
  typealias PlatformImage = UIImage
#endif

// MARK: - PlatformColor Helpers

extension PlatformColor {
  /// Cross-platform RGBA color constructor.
  /// Maps to `NSColor(calibratedRed:...)` on macOS, `UIColor(red:...)` on iOS.
  static func calibrated(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> PlatformColor {
    #if os(macOS)
      NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    #else
      UIColor(red: red, green: green, blue: blue, alpha: alpha)
    #endif
  }

  /// Cross-platform secondary label color.
  /// macOS: `NSColor.secondaryLabelColor`; iOS: `UIColor.secondaryLabel`.
  static var secondaryLabelCompat: PlatformColor {
    #if os(macOS)
      NSColor.secondaryLabelColor
    #else
      UIColor.secondaryLabel
    #endif
  }
}

// MARK: - PlatformFont Helpers

extension PlatformFont {
  /// Create an italic variant of this font, preserving weight.
  /// macOS uses `.italic` symbolic trait; iOS uses `.traitItalic`.
  func withItalic() -> PlatformFont {
    #if os(macOS)
      let descriptor = fontDescriptor.withSymbolicTraits(.italic)
      return NSFont(descriptor: descriptor, size: pointSize) ?? self
    #else
      let descriptor = fontDescriptor.withSymbolicTraits(.traitItalic)
      return descriptor.map { UIFont(descriptor: $0, size: pointSize) } ?? self
    #endif
  }

  /// Create a bold+italic variant of this font.
  func withBoldItalic() -> PlatformFont {
    #if os(macOS)
      let boldDesc = PlatformFont.systemFont(ofSize: pointSize, weight: .bold).fontDescriptor
      let descriptor = boldDesc.withSymbolicTraits(.italic)
      return NSFont(descriptor: descriptor, size: pointSize)
        ?? PlatformFont.systemFont(ofSize: pointSize, weight: .bold)
    #else
      let boldDesc = PlatformFont.systemFont(ofSize: pointSize, weight: .bold).fontDescriptor
      let descriptor = boldDesc.withSymbolicTraits([.traitBold, .traitItalic])
      return descriptor.map { UIFont(descriptor: $0, size: pointSize) }
        ?? PlatformFont.systemFont(ofSize: pointSize, weight: .bold)
    #endif
  }

  // Create a font with a specific design (e.g. `.serif`), if available.
  #if os(macOS)
    func withDesign(_ design: NSFontDescriptor.SystemDesign) -> PlatformFont? {
      guard let descriptor = fontDescriptor.withDesign(design) else { return nil }
      return NSFont(descriptor: descriptor, size: pointSize)
    }
  #else
    func withDesign(_ design: UIFontDescriptor.SystemDesign) -> PlatformFont? {
      guard let descriptor = fontDescriptor.withDesign(design) else { return nil }
      return UIFont(descriptor: descriptor, size: pointSize)
    }
  #endif
}
