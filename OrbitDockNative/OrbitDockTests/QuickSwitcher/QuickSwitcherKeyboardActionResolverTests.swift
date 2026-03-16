@testable import OrbitDock
import SwiftUI
import Testing

@MainActor
struct QuickSwitcherKeyboardActionResolverTests {
  @Test func returnChoosesShiftSelectOnlyWhenSupported() {
    #expect(
      QuickSwitcherKeyboardActionResolver.resolveReturn(
        modifiers: [.shift],
        supportsShiftSelect: true
      ) == .shiftSelect
    )

    #expect(
      QuickSwitcherKeyboardActionResolver.resolveReturn(
        modifiers: [.shift],
        supportsShiftSelect: false
      ) == .select
    )
  }

  @Test func characterBindingsMapToNavigationAndRenameActions() {
    #expect(QuickSwitcherKeyboardActionResolver.resolveCharacter(KeyEquivalent("p"), modifiers: [.control]) == .moveUp)
    #expect(QuickSwitcherKeyboardActionResolver
      .resolveCharacter(KeyEquivalent("n"), modifiers: [.control]) == .moveDown)
    #expect(QuickSwitcherKeyboardActionResolver
      .resolveCharacter(KeyEquivalent("a"), modifiers: [.control]) == .moveToFirst)
    #expect(QuickSwitcherKeyboardActionResolver
      .resolveCharacter(KeyEquivalent("e"), modifiers: [.control]) == .moveToLast)
    #expect(QuickSwitcherKeyboardActionResolver.resolveCharacter(KeyEquivalent("r"), modifiers: [.command]) == .rename)
    #expect(QuickSwitcherKeyboardActionResolver.resolveCharacter(KeyEquivalent("x"), modifiers: []) == .ignored)
  }
}
