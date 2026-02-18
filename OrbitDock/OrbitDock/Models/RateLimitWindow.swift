//
//  RateLimitWindow.swift
//  OrbitDock
//
//  Unified rate limit window model for all providers.
//  Contains utilization data and pace calculations.
//

import Foundation
import SwiftUI

/// Represents a rate limit window with utilization tracking and pace calculations
struct RateLimitWindow: Sendable, Identifiable {
  let id: String
  let label: String
  let utilization: Double // 0-100
  let resetsAt: Date?
  let windowDuration: TimeInterval

  var remaining: Double {
    max(0, 100 - utilization)
  }

  var resetsInDescription: String? {
    guard let resetsAt else { return nil }
    let interval = resetsAt.timeIntervalSinceNow
    if interval <= 0 { return "now" }

    let hours = Int(interval / 3_600)
    let minutes = Int((interval.truncatingRemainder(dividingBy: 3_600)) / 60)

    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }

  /// Time remaining until reset
  var timeRemaining: TimeInterval {
    guard let resetsAt else { return 0 }
    return max(0, resetsAt.timeIntervalSinceNow)
  }

  /// Time elapsed since window started
  var timeElapsed: TimeInterval {
    windowDuration - timeRemaining
  }

  /// Current burn rate (% per hour)
  var burnRatePerHour: Double {
    guard timeElapsed > 0 else { return 0 }
    return utilization / (timeElapsed / 3_600)
  }

  /// Projected usage at reset if current pace continues
  var projectedAtReset: Double {
    guard timeElapsed > 60 else { return utilization } // Need at least 1 min of data
    let rate = utilization / timeElapsed
    return max(0, rate * windowDuration)
  }

  /// Whether on track to exceed the limit
  var willExceed: Bool {
    projectedAtReset > 95 // Give 5% buffer
  }

  /// Pace status
  var paceStatus: PaceStatus {
    // If very early in window, not enough data
    if timeElapsed < 60 { return .unknown } // 1 min minimum

    let sustainableRate = 100.0 / (windowDuration / 3_600) // % per hour to use exactly 100%
    let ratio = burnRatePerHour / sustainableRate

    if ratio < 0.5 { return .relaxed }
    if ratio < 0.9 { return .onTrack }
    if ratio < 1.1 { return .borderline }
    if ratio < 1.5 { return .exceeding }
    return .critical
  }

  /// Format reset time as "3:45 PM" or "Mon 3:45 PM" for multi-day windows
  func resetsAtFormatted(showDay: Bool = false) -> String? {
    guard let resetsAt else { return nil }
    let formatter = DateFormatter()
    if showDay, !Calendar.current.isDateInToday(resetsAt) {
      formatter.dateFormat = "EEE h:mm a"
    } else {
      formatter.dateFormat = "h:mm a"
    }
    return formatter.string(from: resetsAt)
  }
}

// MARK: - Pace Status

enum PaceStatus: String, Sendable {
  case unknown = "—"
  case relaxed = "Relaxed"
  case onTrack = "On Track"
  case borderline = "Borderline"
  case exceeding = "Exceeding"
  case critical = "Critical"

  var color: Color {
    switch self {
      case .unknown: .secondary
      case .relaxed: .accent
      case .onTrack: .statusSuccess
      case .borderline: .statusWaiting
      case .exceeding, .critical: .statusError
    }
  }

  var icon: String {
    switch self {
      case .unknown: "minus"
      case .relaxed: "tortoise.fill"
      case .onTrack: "checkmark.circle.fill"
      case .borderline: "exclamationmark.circle.fill"
      case .exceeding: "flame.fill"
      case .critical: "bolt.fill"
    }
  }
}

// MARK: - Convenience Initializers

extension RateLimitWindow {
  /// Create a 5-hour session window
  static func fiveHour(id: String = "5h", utilization: Double, resetsAt: Date?) -> RateLimitWindow {
    RateLimitWindow(
      id: id,
      label: "5h",
      utilization: utilization,
      resetsAt: resetsAt,
      windowDuration: 5 * 3_600
    )
  }

  /// Create a 7-day rolling window
  static func sevenDay(
    id: String = "7d",
    label: String = "7d",
    utilization: Double,
    resetsAt: Date?
  ) -> RateLimitWindow {
    RateLimitWindow(
      id: id,
      label: label,
      utilization: utilization,
      resetsAt: resetsAt,
      windowDuration: 7 * 24 * 3_600
    )
  }

  /// Create a window with duration in minutes (for Codex variable windows)
  static func fromMinutes(id: String, utilization: Double, windowMinutes: Int, resetsAt: Date) -> RateLimitWindow {
    let hours = windowMinutes / 60
    let label: String
    if hours >= 24 {
      let days = hours / 24
      label = "\(days)d"
    } else if hours > 0 {
      label = "\(hours)h"
    } else {
      label = "\(windowMinutes)m"
    }
    return RateLimitWindow(
      id: id,
      label: label,
      utilization: utilization,
      resetsAt: resetsAt,
      windowDuration: TimeInterval(windowMinutes * 60)
    )
  }
}
