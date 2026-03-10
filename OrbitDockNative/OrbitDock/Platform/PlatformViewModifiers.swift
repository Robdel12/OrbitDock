//
//  PlatformViewModifiers.swift
//  OrbitDock
//
//  Cross-platform View extensions that encapsulate macOS/iOS differences.
//  Call sites stay clean — no #if os(iOS) needed.
//

import SwiftUI

// MARK: - Platform Hover

extension View {
  /// Tracks hover state on macOS; no-op on iOS (touch has no hover).
  func platformHover(_ isHovering: Binding<Bool>) -> some View {
    #if os(macOS)
      onHover { isHovering.wrappedValue = $0 }
    #else
      self
    #endif
  }

  /// Closure variant for complex hover logic (e.g. setting a hovered index).
  func platformHover(perform action: @escaping (Bool) -> Void) -> some View {
    #if os(macOS)
      onHover(perform: action)
    #else
      self
    #endif
  }
}

// MARK: - Platform Popover

extension View {
  /// Popover on macOS, sheet with medium/large detents + themed background on iOS.
  func platformPopover(
    isPresented: Binding<Bool>,
    arrowEdge: Edge = .bottom,
    @ViewBuilder content: @escaping () -> some View
  ) -> some View {
    #if os(iOS)
      sheet(isPresented: isPresented) {
        content()
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
          .presentationBackground(Color.backgroundSecondary)
      }
    #else
      popover(isPresented: isPresented, arrowEdge: arrowEdge, content: content)
    #endif
  }
}

// MARK: - Platform Cursor

extension View {
  /// Pointing-hand cursor on macOS hover; no-op on iOS.
  func platformCursorOnHover() -> some View {
    #if os(macOS)
      onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    #else
      self
    #endif
  }
}

// MARK: - Generic Platform Conditionals

extension View {
  /// Apply a modifier chain only on macOS; identity on iOS.
  /// The closure must use APIs available on both platforms (most SwiftUI modifiers are).
  @ViewBuilder
  func ifMacOS(_ transform: (Self) -> some View) -> some View {
    #if os(macOS)
      transform(self)
    #else
      self
    #endif
  }

  /// Apply a modifier chain only on iOS; identity on macOS.
  /// The closure must use APIs available on both platforms (most SwiftUI modifiers are).
  @ViewBuilder
  func ifIOS(_ transform: (Self) -> some View) -> some View {
    #if os(iOS)
      transform(self)
    #else
      self
    #endif
  }
}
