//
//  Session.swift
//  CommandCenter
//

import Foundation

struct Session: Identifiable, Hashable {
    let id: String
    let projectPath: String
    let projectName: String?
    let branch: String?
    let model: String?
    var contextLabel: String?
    let transcriptPath: String?
    var status: SessionStatus
    var workStatus: WorkStatus
    let startedAt: Date?
    var endedAt: Date?
    let endReason: String?
    var totalTokens: Int
    var totalCostUSD: Double
    var lastActivityAt: Date?
    var lastTool: String?
    var lastToolAt: Date?
    var promptCount: Int
    var toolCount: Int
    var terminalSessionId: String?
    var terminalApp: String?

    enum SessionStatus: String {
        case active
        case idle
        case ended
    }

    enum WorkStatus: String {
        case working    // Claude is actively processing
        case waiting    // Waiting for user input
        case permission // Waiting for permission approval
        case unknown    // Unknown state
    }

    var displayName: String {
        contextLabel ?? projectName ?? projectPath.components(separatedBy: "/").last ?? "Unknown"
    }

    var isActive: Bool {
        status == .active
    }

    var needsAttention: Bool {
        isActive && (workStatus == .waiting || workStatus == .permission)
    }

    var statusIcon: String {
        if !isActive { return "moon.fill" }
        switch workStatus {
        case .working: return "bolt.fill"
        case .waiting: return "hand.raised.fill"
        case .permission: return "lock.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var statusColor: String {
        if !isActive { return "secondary" }
        switch workStatus {
        case .working: return "green"
        case .waiting: return "orange"
        case .permission: return "yellow"
        case .unknown: return "secondary"
        }
    }

    var statusLabel: String {
        if !isActive { return "Ended" }
        switch workStatus {
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .permission: return "Permission"
        case .unknown: return "Active"
        }
    }

    var duration: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = endedAt ?? Date()
        return end.timeIntervalSince(start)
    }

    var formattedDuration: String {
        guard let duration = duration else { return "--" }
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var formattedCost: String {
        if totalCostUSD > 0 {
            return String(format: "$%.2f", totalCostUSD)
        }
        return "--"
    }

    var lastToolDisplay: String? {
        guard let tool = lastTool, !tool.isEmpty else { return nil }
        return tool
    }
}
