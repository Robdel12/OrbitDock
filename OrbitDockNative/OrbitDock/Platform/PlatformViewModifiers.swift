//
//  PlatformViewModifiers.swift
//  OrbitDock
//
//  Cross-platform View extensions that encapsulate macOS/iOS differences.
//  Call sites stay clean — no #if os(iOS) needed.
//

import SwiftUI

enum PlatformTextInputAutocapitalization {
  case never
  case words
}

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

  /// Full-screen image preview on touch platforms, sheet preview elsewhere.
  @ViewBuilder
  func platformImagePreview<Item: Identifiable, Content: View>(
    item: Binding<Item?>,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    #if os(iOS)
      fullScreenCover(item: item, content: content)
    #else
      sheet(item: item, content: content)
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

// MARK: - Platform Gestures

extension View {
  /// Trailing swipe actions on touch platforms; identity elsewhere.
  @ViewBuilder
  func platformTrailingSwipeActions<Actions: View>(
    allowsFullSwipe: Bool = false,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    #if os(iOS)
      swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe) {
        actions()
      }
    #else
      self
    #endif
  }
}

// MARK: - Platform Sheet Chrome

extension View {
  /// Standard OrbitDock sheet treatment on iOS; identity on macOS.
  @ViewBuilder
  func platformSheetChrome(detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
    #if os(iOS)
      presentationDetents(detents)
        .presentationDragIndicator(.visible)
    #else
      self
    #endif
  }

  /// Compact path-preview sheet treatment on iOS; identity on macOS.
  @ViewBuilder
  func platformProjectPreviewSheetChrome() -> some View {
    #if os(iOS)
      presentationDetents([.height(320), .medium])
        .presentationDragIndicator(.visible)
    #else
      self
    #endif
  }

  /// Inline navigation titles where the platform supports that presentation mode.
  @ViewBuilder
  func platformInlineNavigationTitle() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }

  /// Sheet content title treatment for compact navigation stacks.
  @ViewBuilder
  func platformSheetNavigationTitle(_ title: String) -> some View {
    #if os(iOS)
      frame(maxWidth: .infinity)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }

  /// Text-input capitalization exists for touch keyboard entry; identity elsewhere.
  @ViewBuilder
  func platformTextInputAutocapitalization(_ autocapitalization: PlatformTextInputAutocapitalization) -> some View {
    #if os(iOS)
      switch autocapitalization {
        case .never:
          textInputAutocapitalization(.never)
        case .words:
          textInputAutocapitalization(.words)
      }
    #else
      self
    #endif
  }

  /// URL keyboard treatment on iOS; identity on macOS.
  @ViewBuilder
  func platformURLKeyboard() -> some View {
    #if os(iOS)
      keyboardType(.URL)
    #else
      self
    #endif
  }
}

// MARK: - Generic Platform Conditionals

extension View {
  /// Apply a modifier chain conditionally; identity when the condition is false.
  @ViewBuilder
  func `if`<Transformed: View>(
    _ condition: Bool,
    transform: (Self) -> Transformed
  ) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }

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
