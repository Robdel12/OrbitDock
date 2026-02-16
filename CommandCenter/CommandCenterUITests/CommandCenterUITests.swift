//
//  CommandCenterUITests.swift
//  CommandCenterUITests
//
//  Created by Robert DeLuca on 1/30/26.
//

import Vizzly
import XCTest

final class CommandCenterUITests: XCTestCase {
  let app = XCUIApplication()

  override class func setUp() {
    super.setUp()
    // Set up test database once for all tests
    TestDatabaseHelper.setupTestDatabase()
  }

  override class func tearDown() {
    TestDatabaseHelper.teardownTestDatabase()
    super.tearDown()
  }

  override func setUpWithError() throws {
    continueAfterFailure = false

    // Point app to test database
    app.launchEnvironment["ORBITDOCK_TEST_DB"] = TestDatabaseHelper.testDbPath
  }

  override func tearDownWithError() throws {
    // Ensure app is terminated between tests to avoid race conditions
    app.terminate()
  }

  // MARK: - Dashboard Tests

  @MainActor
  func testDashboardWithSessions() {
    app.launch()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))

    // Dashboard shows active sessions with various status indicators
    // The seed data includes: working, permission, question, awaiting reply
    app.vizzlyScreenshot(name: "dashboard-with-sessions")
  }

  // MARK: - Session Detail Tests

  @MainActor
  func testSessionDetailView() {
    app.launch()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))

    // Click on first session to open detail view
    let sessionRow = app.outlines.firstMatch.cells.firstMatch
    if sessionRow.waitForExistence(timeout: 3) {
      sessionRow.click()

      // Wait for detail view to load
      let detailView = app.groups["SessionDetail"]
      if detailView.waitForExistence(timeout: 2) {
        app.vizzlyScreenshot(name: "session-detail")
      }
    }
  }

  // MARK: - Settings Tests

  @MainActor
  func testSettingsView() {
    app.launch()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))

    // Open settings via keyboard shortcut
    app.typeKey(",", modifierFlags: .command)

    let settingsWindow = app.windows["Settings"]
    if settingsWindow.waitForExistence(timeout: 3) {
      app.vizzlyScreenshot(name: "settings-view")
    }
  }

  // MARK: - Quick Switcher Tests

  @MainActor
  func testQuickSwitcher() {
    app.launch()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))

    // Open quick switcher (Cmd+K)
    app.typeKey("k", modifierFlags: .command)

    // Quick switcher should show sessions from seed data
    let quickSwitcher = app.otherElements["QuickSwitcher"]
    if quickSwitcher.waitForExistence(timeout: 2) {
      app.vizzlyScreenshot(name: "quick-switcher-with-sessions")
    }
  }

  @MainActor
  func testQuickSwitcherSearch() {
    app.launch()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))

    app.typeKey("k", modifierFlags: .command)

    let quickSwitcher = app.otherElements["QuickSwitcher"]
    if quickSwitcher.waitForExistence(timeout: 2) {
      // Type a search query
      app.typeText("vizzly")
      app.vizzlyScreenshot(name: "quick-switcher-filtered")
    }
  }

  // MARK: - Menu Bar Tests

  @MainActor
  func testMenuBarPopover() {
    app.launch()

    let menuBarItem = app.menuBars.statusItems.firstMatch
    if menuBarItem.waitForExistence(timeout: 5) {
      menuBarItem.click()
      app.vizzlyScreenshot(name: "menu-bar-popover")
    }
  }

  // MARK: - Quest Tests

  @MainActor
  func testQuestListView() {
    app.launch()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))

    // Navigate to Quests (assuming sidebar navigation)
    let questsNavItem = app.outlines.firstMatch.staticTexts["Quests"]
    if questsNavItem.waitForExistence(timeout: 3) {
      questsNavItem.click()
      app.vizzlyScreenshot(name: "quest-list")
    }
  }

  @MainActor
  func testQuestDetailView() {
    app.launch()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))

    // Navigate to Quests and select one
    let questsNavItem = app.outlines.firstMatch.staticTexts["Quests"]
    if questsNavItem.waitForExistence(timeout: 3) {
      questsNavItem.click()

      // Click on first quest
      let questRow = app.tables.firstMatch.cells.firstMatch
      if questRow.waitForExistence(timeout: 2) {
        questRow.click()
        app.vizzlyScreenshot(name: "quest-detail")
      }
    }
  }

  // MARK: - Inbox Tests

  @MainActor
  func testInboxView() {
    app.launch()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))

    // Navigate to Inbox
    let inboxNavItem = app.outlines.firstMatch.staticTexts["Inbox"]
    if inboxNavItem.waitForExistence(timeout: 3) {
      inboxNavItem.click()
      app.vizzlyScreenshot(name: "inbox-with-items")
    }
  }

  // MARK: - Performance Tests

  @MainActor
  func testLaunchPerformance() {
    measure(metrics: [XCTApplicationLaunchMetric()]) {
      app.launchEnvironment["ORBITDOCK_TEST_DB"] = TestDatabaseHelper.testDbPath
      app.launch()
    }
  }
}
