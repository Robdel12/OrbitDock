//
//  DashboardFormatters.swift
//  OrbitDock
//
//  Shared formatting utilities for dashboard views.
//  Consolidates duplicated formatCost/formatTokens/cleanPrompt/recency/paceLabel.
//

import SwiftUI

enum DashboardFormatters {

  // MARK: - Cost

  static func cost(_ value: Double, zeroDisplay: String = "$0.00") -> String {
    if value <= 0 { return zeroDisplay }
    if value >= 1_000 { return String(format: "$%.1fK", value / 1_000) }
    if value >= 100 { return String(format: "$%.0f", value) }
    if value >= 10 { return String(format: "$%.1f", value) }
    return String(format: "$%.2f", value)
  }

  static func costCompact(_ cost: Double) -> String {
    if cost >= 1_000 { return String(format: "$%.1fK", cost / 1_000) }
    if cost >= 100 { return String(format: "$%.0f", cost) }
    if cost >= 10 { return String(format: "$%.1f", cost) }
    return String(format: "$%.2f", cost)
  }

  // MARK: - Tokens

  static func tokens(_ value: Int, zeroDisplay: String = "0") -> String {
    if value <= 0 { return zeroDisplay }
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
    return "\(value)"
  }

  static func tokensUpperK(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
    return "\(value)"
  }

  // MARK: - Text

  static func cleanPrompt(_ prompt: String, maxLength: Int) -> String {
    let clean = prompt.strippingXMLTags()
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
    if clean.count > maxLength {
      return String(clean.prefix(maxLength - 3)) + "..."
    }
    return clean
  }

  // MARK: - Recency

  static func recency(for date: Date?) -> String? {
    guard let date else { return nil }
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "now" }
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }

  // MARK: - Usage

  static func paceLabel(_ paceStatus: PaceStatus) -> String? {
    switch paceStatus {
      case .critical: "Critical!"
      case .exceeding: "Heavy"
      case .borderline: "Moderate"
      case .onTrack: "On track"
      case .relaxed: "Light"
      case .unknown: nil
    }
  }

  static func projectedColor(_ projectedAtReset: Double) -> Color {
    if projectedAtReset >= 100 { return .statusError }
    if projectedAtReset >= 90 { return .feedbackCaution }
    return .feedbackPositive
  }

  // MARK: - Elapsed / Remaining Time

  static func elapsed(_ seconds: Int) -> String {
    if seconds < 5 { return "just now" }
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3_600 { return "\(seconds / 60)m ago" }
    return "\(seconds / 3_600)h ago"
  }

  static func remaining(_ seconds: Int) -> String {
    if seconds >= 60 {
      let m = seconds / 60
      let s = seconds % 60
      return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }
    return "\(seconds)s"
  }

  static func duration(since start: Date?) -> String? {
    guard let start else { return nil }
    let elapsed = Int(Date().timeIntervalSince(start))
    if elapsed < 60 { return "\(elapsed)s" }
    if elapsed < 3_600 { return "\(elapsed / 60)m" }
    let h = elapsed / 3_600
    let m = (elapsed % 3_600) / 60
    return m > 0 ? "\(h)h \(m)m" : "\(h)h"
  }
}
