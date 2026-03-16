import SwiftUI

enum QuickSwitcherKeyboardAction: Equatable {
  case moveUp
  case moveDown
  case moveToFirst
  case moveToLast
  case select
  case shiftSelect
  case rename
  case ignored
}

enum QuickSwitcherKeyboardActionResolver {
  static func resolveReturn(modifiers: EventModifiers, supportsShiftSelect: Bool) -> QuickSwitcherKeyboardAction {
    if modifiers.contains(.shift), supportsShiftSelect {
      return .shiftSelect
    }

    return .select
  }

  static func resolveCharacter(_ key: KeyEquivalent, modifiers: EventModifiers) -> QuickSwitcherKeyboardAction {
    if key == "p", modifiers.contains(.control) {
      return .moveUp
    }

    if key == "n", modifiers.contains(.control) {
      return .moveDown
    }

    if key == "a", modifiers.contains(.control) {
      return .moveToFirst
    }

    if key == "e", modifiers.contains(.control) {
      return .moveToLast
    }

    if key == "r", modifiers.contains(.command) {
      return .rename
    }

    return .ignored
  }
}

struct KeyboardNavigationModifier: ViewModifier {
  let isEnabled: Bool
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void
  let onMoveToFirst: () -> Void
  let onMoveToLast: () -> Void
  let onSelect: () -> Void
  let onRename: () -> Void
  let onShiftSelect: (() -> Void)?

  init(
    isEnabled: Bool = true,
    onMoveUp: @escaping () -> Void,
    onMoveDown: @escaping () -> Void,
    onMoveToFirst: @escaping () -> Void,
    onMoveToLast: @escaping () -> Void,
    onSelect: @escaping () -> Void,
    onRename: @escaping () -> Void,
    onShiftSelect: (() -> Void)? = nil
  ) {
    self.isEnabled = isEnabled
    self.onMoveUp = onMoveUp
    self.onMoveDown = onMoveDown
    self.onMoveToFirst = onMoveToFirst
    self.onMoveToLast = onMoveToLast
    self.onSelect = onSelect
    self.onRename = onRename
    self.onShiftSelect = onShiftSelect
  }

  func body(content: Content) -> some View {
    content
      .onKeyPress(keys: [.upArrow]) { _ in
        guard isEnabled else { return .ignored }
        onMoveUp()
        return .handled
      }
      .onKeyPress(keys: [.downArrow]) { _ in
        guard isEnabled else { return .ignored }
        onMoveDown()
        return .handled
      }
      .onKeyPress(keys: [.return]) { keyPress in
        guard isEnabled else { return .ignored }
        switch QuickSwitcherKeyboardActionResolver.resolveReturn(
          modifiers: keyPress.modifiers,
          supportsShiftSelect: onShiftSelect != nil
        ) {
          case .shiftSelect:
            onShiftSelect?()
          case .select:
            onSelect()
          default:
            break
        }
        return .handled
      }
      .onKeyPress { keyPress in
        guard isEnabled else { return .ignored }
        switch QuickSwitcherKeyboardActionResolver.resolveCharacter(
          keyPress.key,
          modifiers: keyPress.modifiers
        ) {
          case .moveUp:
            onMoveUp()
            return .handled
          case .moveDown:
            onMoveDown()
            return .handled
          case .moveToFirst:
            onMoveToFirst()
            return .handled
          case .moveToLast:
            onMoveToLast()
            return .handled
          case .rename:
            onRename()
            return .handled
          case .select, .shiftSelect, .ignored:
            return .ignored
        }
      }
  }
}
