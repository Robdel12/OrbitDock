import SwiftUI

#if os(iOS)
  import UIKit
#endif

enum DashboardLayoutMode {
  case phoneCompact
  case pad
  case desktop

  private static let compactWidthThreshold: CGFloat = 680
  private static let desktopWidthThreshold: CGFloat = 1_120
  private static let missionControlSidebarThreshold: CGFloat = 820

  static func current(
    horizontalSizeClass: UserInterfaceSizeClass?,
    containerWidth: CGFloat? = nil
  ) -> DashboardLayoutMode {
    #if os(iOS)
      let width = containerWidth ?? UIScreen.main.bounds.width

      if horizontalSizeClass == .compact || width < compactWidthThreshold {
        return .phoneCompact
      }

      if UIDevice.current.userInterfaceIdiom == .pad {
        return width >= desktopWidthThreshold ? .desktop : .pad
      }

      return width >= desktopWidthThreshold ? .desktop : .pad
    #else
      _ = containerWidth
      _ = horizontalSizeClass
      return .desktop
    #endif
  }

  static func shouldShowMissionControlSidebar(
    horizontalSizeClass: UserInterfaceSizeClass?,
    containerWidth: CGFloat
  ) -> Bool {
    #if os(iOS)
      let layoutMode = current(
        horizontalSizeClass: horizontalSizeClass,
        containerWidth: containerWidth
      )
      guard layoutMode != .phoneCompact else { return false }
      return containerWidth >= missionControlSidebarThreshold
    #else
      _ = horizontalSizeClass
      _ = containerWidth
      return true
    #endif
  }

  var isPhoneCompact: Bool {
    self == .phoneCompact
  }

  var isPad: Bool {
    self == .pad
  }

  var contentPadding: CGFloat {
    switch self {
      case .phoneCompact: 14
      case .pad: 18
      case .desktop: 24
    }
  }

  var historyTopPadding: CGFloat {
    switch self {
      case .phoneCompact: 18
      case .pad: 20
      case .desktop: 24
    }
  }

  var showSidebar: Bool {
    self == .desktop
  }

  var cardSpacing: CGFloat {
    switch self {
      case .phoneCompact: 6
      case .pad: 8
      case .desktop: 8
    }
  }
}
