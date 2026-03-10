//
//  QuickSwitcherNavigationModel.swift
//  OrbitDock
//
//  Pure keyboard navigation rules for QuickSwitcher selection state.
//

import Foundation

enum QuickSwitcherNavigationModel {
  static func moveSelection(
    currentIndex: Int,
    delta: Int,
    totalItems: Int
  ) -> Int {
    guard totalItems > 0 else { return currentIndex }

    let nextIndex = currentIndex + delta
    let wrappedIndex = nextIndex % totalItems
    return wrappedIndex >= 0 ? wrappedIndex : wrappedIndex + totalItems
  }

  static func moveToFirst(
    currentIndex: Int,
    totalItems: Int
  ) -> Int {
    guard totalItems > 0 else { return currentIndex }
    return 0
  }

  static func moveToLast(
    currentIndex: Int,
    totalItems: Int
  ) -> Int {
    guard totalItems > 0 else { return currentIndex }
    return totalItems - 1
  }
}
