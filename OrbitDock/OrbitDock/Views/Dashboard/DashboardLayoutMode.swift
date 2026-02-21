import SwiftUI

#if os(iOS)
  import UIKit
#endif

enum DashboardLayoutMode {
  case phoneCompact
  case pad
  case desktop

  static func current(horizontalSizeClass: UserInterfaceSizeClass?) -> DashboardLayoutMode {
    #if os(iOS)
      if UIDevice.current.userInterfaceIdiom == .pad {
        if horizontalSizeClass == .compact {
          return .phoneCompact
        }
        return .pad
      }
      if horizontalSizeClass == .compact {
        return .phoneCompact
      }
      return .pad
    #else
      _ = horizontalSizeClass
      return .desktop
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

  var attentionTopPadding: CGFloat {
    switch self {
      case .phoneCompact: 10
      case .pad: 12
      case .desktop: 14
    }
  }

  var activeTopPadding: CGFloat {
    switch self {
      case .phoneCompact: 14
      case .pad: 16
      case .desktop: 20
    }
  }

  var historyTopPadding: CGFloat {
    switch self {
      case .phoneCompact: 18
      case .pad: 20
      case .desktop: 24
    }
  }
}
