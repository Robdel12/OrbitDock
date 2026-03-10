@testable import OrbitDock
import Testing

struct QuickSwitcherNavigationModelTests {
  @Test func moveSelectionAdvancesWithinBounds() {
    let moved = QuickSwitcherNavigationModel.moveSelection(
      currentIndex: 1,
      delta: 1,
      totalItems: 4
    )

    #expect(moved == 2)
  }

  @Test func moveSelectionWrapsFromStartToEnd() {
    let moved = QuickSwitcherNavigationModel.moveSelection(
      currentIndex: 0,
      delta: -1,
      totalItems: 4
    )

    #expect(moved == 3)
  }

  @Test func moveSelectionWrapsFromEndToStart() {
    let moved = QuickSwitcherNavigationModel.moveSelection(
      currentIndex: 3,
      delta: 1,
      totalItems: 4
    )

    #expect(moved == 0)
  }

  @Test func moveSelectionHandlesLargerDeltasDeterministically() {
    let moved = QuickSwitcherNavigationModel.moveSelection(
      currentIndex: 1,
      delta: 7,
      totalItems: 5
    )

    #expect(moved == 3)
  }

  @Test func moveSelectionLeavesIndexUnchangedWhenThereAreNoItems() {
    let moved = QuickSwitcherNavigationModel.moveSelection(
      currentIndex: 2,
      delta: 1,
      totalItems: 0
    )

    #expect(moved == 2)
  }

  @Test func moveToFirstReturnsZeroWhenItemsExist() {
    let moved = QuickSwitcherNavigationModel.moveToFirst(
      currentIndex: 3,
      totalItems: 4
    )

    #expect(moved == 0)
  }

  @Test func moveToFirstLeavesIndexUnchangedWhenThereAreNoItems() {
    let moved = QuickSwitcherNavigationModel.moveToFirst(
      currentIndex: 3,
      totalItems: 0
    )

    #expect(moved == 3)
  }

  @Test func moveToLastReturnsLastIndexWhenItemsExist() {
    let moved = QuickSwitcherNavigationModel.moveToLast(
      currentIndex: 1,
      totalItems: 4
    )

    #expect(moved == 3)
  }

  @Test func moveToLastLeavesIndexUnchangedWhenThereAreNoItems() {
    let moved = QuickSwitcherNavigationModel.moveToLast(
      currentIndex: 1,
      totalItems: 0
    )

    #expect(moved == 1)
  }
}
