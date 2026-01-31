//
//  Session.swift
//  OrbitDock
//

import Foundation

struct Session: Identifiable, Hashable {
    let id: String
    let projectPath: String
    let projectName: String?
    let branch: String?
    let model: String?
    var summary: String?           // Claude-generated conversation title
    var customName: String?        // User-defined custom name (overrides summary)
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
    var workstreamId: String? = nil     // Link to workstream
    var attentionReason: AttentionReason
    var pendingToolName: String?    // Which tool needs permission
    var pendingQuestion: String?    // Question text from AskUserQuestion

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

    enum AttentionReason: String {
        case none               // Working or ended - no attention needed
        case awaitingReply      // Claude finished, waiting for next prompt
        case awaitingPermission // Tool needs approval (Bash, Write, etc.)
        case awaitingQuestion   // AskUserQuestion tool - Claude asked a question

        var label: String {
            switch self {
            case .none: return ""
            case .awaitingReply: return "Ready"
            case .awaitingPermission: return "Permission"
            case .awaitingQuestion: return "Question"
            }
        }

        var icon: String {
            switch self {
            case .none: return "circle"
            case .awaitingReply: return "checkmark.circle"
            case .awaitingPermission: return "lock.fill"
            case .awaitingQuestion: return "questionmark.bubble"
            }
        }
    }

    // Custom initializer with backward compatibility for legacy code using contextLabel
    init(
        id: String,
        projectPath: String,
        projectName: String? = nil,
        branch: String? = nil,
        model: String? = nil,
        summary: String? = nil,
        customName: String? = nil,
        contextLabel: String? = nil,  // Legacy parameter, mapped to customName
        transcriptPath: String? = nil,
        status: SessionStatus,
        workStatus: WorkStatus,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        endReason: String? = nil,
        totalTokens: Int = 0,
        totalCostUSD: Double = 0,
        lastActivityAt: Date? = nil,
        lastTool: String? = nil,
        lastToolAt: Date? = nil,
        promptCount: Int = 0,
        toolCount: Int = 0,
        terminalSessionId: String? = nil,
        terminalApp: String? = nil,
        workstreamId: String? = nil,
        attentionReason: AttentionReason = .none,
        pendingToolName: String? = nil,
        pendingQuestion: String? = nil
    ) {
        self.id = id
        self.projectPath = projectPath
        self.projectName = projectName
        self.branch = branch
        self.model = model
        self.summary = summary
        self.customName = customName ?? contextLabel  // Use contextLabel if customName not provided
        self.transcriptPath = transcriptPath
        self.status = status
        self.workStatus = workStatus
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.lastActivityAt = lastActivityAt
        self.lastTool = lastTool
        self.lastToolAt = lastToolAt
        self.promptCount = promptCount
        self.toolCount = toolCount
        self.terminalSessionId = terminalSessionId
        self.terminalApp = terminalApp
        self.workstreamId = workstreamId
        self.attentionReason = attentionReason
        self.pendingToolName = pendingToolName
        self.pendingQuestion = pendingQuestion
    }

    var displayName: String {
        customName ?? summary ?? projectName ?? projectPath.components(separatedBy: "/").last ?? "Unknown"
    }

    /// For backward compatibility
    var contextLabel: String? {
        get { customName }
        set { customName = newValue }
    }

    var isActive: Bool {
        status == .active
    }

    var needsAttention: Bool {
        isActive && attentionReason != .none && attentionReason != .awaitingReply
    }

    /// Returns true if session is waiting but not blocking (just needs a reply)
    var isReady: Bool {
        isActive && attentionReason == .awaitingReply
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
