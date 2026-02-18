//
//  UsageManager.swift
//  OrbitDock
//

import Foundation

struct DailyActivity: Codable, Identifiable {
  let date: String
  let messageCount: Int
  let sessionCount: Int
  let toolCallCount: Int

  var id: String {
    date
  }

  var dateValue: Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: date)
  }
}

struct StatsCache: Codable {
  let version: Int
  let lastComputedDate: String
  let dailyActivity: [DailyActivity]
}

@Observable
class UsageManager {
  static let shared = UsageManager()

  private(set) var dailyActivity: [DailyActivity] = []
  private(set) var lastUpdated: Date?

  private let statsCachePath: String
  private var fileMonitor: DispatchSourceFileSystemObject?

  private init() {
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    statsCachePath = homeDir.appendingPathComponent(".claude/stats-cache.json").path
    loadStats()
    startFileMonitoring()
  }

  deinit {
    fileMonitor?.cancel()
  }

  // MARK: - File Monitoring

  private func startFileMonitoring() {
    guard FileManager.default.fileExists(atPath: statsCachePath) else { return }

    let fileDescriptor = open(statsCachePath, O_EVTONLY)
    guard fileDescriptor >= 0 else { return }

    fileMonitor = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .extend],
      queue: .main
    )

    fileMonitor?.setEventHandler { [weak self] in
      self?.loadStats()
    }

    fileMonitor?.setCancelHandler {
      close(fileDescriptor)
    }

    fileMonitor?.resume()
  }

  func loadStats() {
    guard FileManager.default.fileExists(atPath: statsCachePath) else {
      return
    }

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: statsCachePath)) else {
      return
    }

    do {
      let decoder = JSONDecoder()
      let cache = try decoder.decode(StatsCache.self, from: data)
      dailyActivity = cache.dailyActivity
      lastUpdated = Date()
    } catch {
      print("Failed to decode stats cache: \(error)")
    }
  }

  // MARK: - Computed Stats

  var todayActivity: DailyActivity? {
    let today = formattedDate(Date())
    return dailyActivity.first { $0.date == today }
  }

  var yesterdayActivity: DailyActivity? {
    let yesterday = formattedDate(Date().addingTimeInterval(-86_400))
    return dailyActivity.first { $0.date == yesterday }
  }

  var thisWeekActivity: [DailyActivity] {
    let calendar = Calendar.current
    let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    return dailyActivity.filter { activity in
      guard let date = activity.dateValue else { return false }
      return date >= weekAgo
    }
  }

  var thisMonthActivity: [DailyActivity] {
    let calendar = Calendar.current
    let monthAgo = calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    return dailyActivity.filter { activity in
      guard let date = activity.dateValue else { return false }
      return date >= monthAgo
    }
  }

  var totalMessagesToday: Int {
    todayActivity?.messageCount ?? 0
  }

  var totalSessionsToday: Int {
    todayActivity?.sessionCount ?? 0
  }

  var totalToolCallsToday: Int {
    todayActivity?.toolCallCount ?? 0
  }

  var totalMessagesThisWeek: Int {
    thisWeekActivity.reduce(0) { $0 + $1.messageCount }
  }

  var totalSessionsThisWeek: Int {
    thisWeekActivity.reduce(0) { $0 + $1.sessionCount }
  }

  var averageMessagesPerDay: Double {
    guard !thisWeekActivity.isEmpty else { return 0 }
    return Double(totalMessagesThisWeek) / Double(thisWeekActivity.count)
  }

  // MARK: - Helpers

  private func formattedDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}
