//
//  CommandBar.swift
//  OrbitDock
//
//  Mission control command bar - rich stats strip at top of dashboard
//  Shows subscription usage, today's activity, and all-time totals
//

import SwiftUI

struct CommandBar: View {
    let sessions: [Session]

    // Calculate today's stats
    private var todayStats: TodayStats {
        let calendar = Calendar.current
        let todaySessions = sessions.filter {
            guard let start = $0.startedAt else { return false }
            return calendar.isDateInToday(start)
        }

        // Get session IDs that started today
        let todayIds = Set(todaySessions.map { $0.id })

        // Get stats for today's sessions from MessageStore
        let allStats = MessageStore.shared.readAllSessionStats()
        let todayStatsFiltered = allStats.filter { todayIds.contains($0.sessionId) }

        let cost = todayStatsFiltered.reduce(0) { $0 + $1.stats.estimatedCostUSD }
        let tokens = todayStatsFiltered.reduce(0) { $0 + $1.stats.inputTokens + $1.stats.outputTokens }

        return TodayStats(
            sessionCount: todaySessions.count,
            cost: cost,
            tokens: tokens
        )
    }

    // All-time aggregate stats
    private var allTimeStats: AllTimeStats {
        let allStats = MessageStore.shared.readAllSessionStats()
        let totalCost = allStats.reduce(0) { $0 + $1.stats.estimatedCostUSD }
        let totalTokens = allStats.reduce(0) { $0 + $1.stats.inputTokens + $1.stats.outputTokens }
        return AllTimeStats(
            sessionCount: sessions.count,
            cost: totalCost,
            tokens: totalTokens
        )
    }

    // Model distribution for the mini chart
    private var modelDistribution: ModelDistribution {
        var opus = 0
        var sonnet = 0
        var haiku = 0

        for session in sessions {
            guard let model = session.model?.lowercased() else { continue }
            if model.contains("opus") { opus += 1 }
            else if model.contains("sonnet") { sonnet += 1 }
            else if model.contains("haiku") { haiku += 1 }
        }

        return ModelDistribution(opus: opus, sonnet: sonnet, haiku: haiku)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Subscription Usage - Hero section
            SubscriptionUsagePanel()

            verticalDivider

            // Today's Activity
            TodayPanel(stats: todayStats)

            verticalDivider

            // All-Time Totals
            AllTimePanel(stats: allTimeStats, modelDistribution: modelDistribution)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.backgroundTertiary.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.surfaceBorder.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.surfaceBorder.opacity(0.3))
            .frame(width: 1)
            .padding(.vertical, 4)
            .padding(.horizontal, 20)
    }
}

// MARK: - Data Models

private struct TodayStats {
    let sessionCount: Int
    let cost: Double
    let tokens: Int
}

private struct AllTimeStats {
    let sessionCount: Int
    let cost: Double
    let tokens: Int
}

private struct ModelDistribution {
    let opus: Int
    let sonnet: Int
    let haiku: Int

    var total: Int { opus + sonnet + haiku }

    var opusPercent: Double {
        total > 0 ? Double(opus) / Double(total) : 0
    }
    var sonnetPercent: Double {
        total > 0 ? Double(sonnet) / Double(total) : 0
    }
    var haikuPercent: Double {
        total > 0 ? Double(haiku) / Double(total) : 0
    }
}

// MARK: - Subscription Usage Panel

private struct SubscriptionUsagePanel: View {
    let service = SubscriptionUsageService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section label
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accent)

                Text("RATE LIMITS")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
            }

            if let usage = service.usage {
                HStack(spacing: 16) {
                    // 5-hour gauge (larger, hero)
                    RateLimitGauge(
                        value: usage.fiveHour.utilization,
                        label: "5h",
                        resetsIn: usage.fiveHour.resetsInDescription,
                        paceStatus: usage.fiveHour.paceStatus,
                        projectedUsage: usage.fiveHour.projectedAtReset,
                        size: .hero
                    )

                    // 7-day gauge
                    if let sevenDay = usage.sevenDay {
                        RateLimitGauge(
                            value: sevenDay.utilization,
                            label: "7d",
                            resetsIn: sevenDay.resetsInDescription,
                            paceStatus: sevenDay.paceStatus,
                            projectedUsage: sevenDay.projectedAtReset,
                            size: .regular
                        )
                    }

                    // Plan badge
                    if let plan = usage.planName {
                        VStack(spacing: 2) {
                            Text(plan)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.accent)
                            Text("Plan")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.quaternary)
                        }
                        .padding(.horizontal, 8)
                    }
                }
            } else if service.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 52)
            } else {
                Text("—")
                    .foregroundStyle(.quaternary)
            }
        }
    }
}

// MARK: - Rate Limit Gauge

private struct RateLimitGauge: View {
    let value: Double
    let label: String
    let resetsIn: String?
    var paceStatus: SubscriptionUsage.Window.PaceStatus? = nil
    var projectedUsage: Double? = nil
    var size: GaugeSize = .regular

    enum GaugeSize {
        case regular, hero

        var diameter: CGFloat {
            switch self {
            case .regular: return 44
            case .hero: return 52
            }
        }

        var lineWidth: CGFloat {
            switch self {
            case .regular: return 4
            case .hero: return 5
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .regular: return 12
            case .hero: return 14
            }
        }
    }

    private var color: Color {
        if value >= 90 { return .statusError }
        if value >= 70 { return .statusWaiting }
        return .accent
    }

    private var paceColor: Color {
        guard let pace = paceStatus else { return .secondary }
        switch pace {
        case .unknown: return .secondary
        case .relaxed: return .accent
        case .onTrack: return .statusSuccess
        case .borderline: return .statusWaiting
        case .exceeding, .critical: return .statusError
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.primary.opacity(0.06), lineWidth: size.lineWidth)

                // Projected usage (faint)
                if let projected = projectedUsage, projected > value {
                    Circle()
                        .trim(from: min(1, value / 100), to: min(1, projected / 100))
                        .stroke(
                            paceColor.opacity(0.2),
                            style: StrokeStyle(lineWidth: size.lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }

                // Progress arc
                Circle()
                    .trim(from: 0, to: min(1, value / 100))
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: size.lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                // Center value
                Text("\(Int(value))")
                    .font(.system(size: size.fontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }
            .frame(width: size.diameter, height: size.diameter)

            // Label + reset
            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let resets = resetsIn {
                    Text(resets)
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let pace = paceStatus, pace != .unknown, pace != .onTrack, pace != .relaxed {
                Image(systemName: pace.icon)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(paceColor)
                    .padding(3)
                    .background(Color.backgroundTertiary, in: Circle())
                    .offset(x: 4, y: -2)
            }
        }
    }
}

// MARK: - Today Panel

private struct TodayPanel: View {
    let stats: TodayStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section label
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.statusWaiting)

                Text("TODAY")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
            }

            HStack(spacing: 20) {
                // Sessions
                StatBlock(
                    value: "\(stats.sessionCount)",
                    label: "sessions",
                    icon: "cpu"
                )

                // Cost
                StatBlock(
                    value: formatCost(stats.cost),
                    label: "spent",
                    icon: "dollarsign.circle"
                )

                // Tokens
                StatBlock(
                    value: formatTokens(stats.tokens),
                    label: "tokens",
                    icon: "textformat"
                )
            }
        }
    }

    private func formatCost(_ cost: Double) -> String {
        if cost >= 100 {
            return String(format: "$%.0f", cost)
        } else if cost >= 10 {
            return String(format: "$%.1f", cost)
        } else if cost >= 1 {
            return String(format: "$%.2f", cost)
        }
        return String(format: "$%.2f", cost)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.0fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}

// MARK: - All Time Panel

private struct AllTimePanel: View {
    let stats: AllTimeStats
    let modelDistribution: ModelDistribution

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section label
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accent.opacity(0.7))

                Text("TRACKED")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
            }

            HStack(spacing: 20) {
                // Total cost
                StatBlock(
                    value: formatCost(stats.cost),
                    label: "total",
                    icon: "dollarsign.circle.fill",
                    color: .statusSuccess
                )

                // Total tokens
                StatBlock(
                    value: formatTokens(stats.tokens),
                    label: "tokens",
                    icon: "textformat.abc"
                )

                // Sessions
                StatBlock(
                    value: "\(stats.sessionCount)",
                    label: "sessions",
                    icon: "cpu.fill"
                )

                // Model distribution mini chart
                if modelDistribution.total > 0 {
                    ModelDistributionChart(distribution: modelDistribution)
                }
            }
        }
    }

    private func formatCost(_ cost: Double) -> String {
        if cost >= 1000 {
            return String(format: "$%.1fK", cost / 1000)
        } else if cost >= 100 {
            return String(format: "$%.0f", cost)
        } else if cost >= 10 {
            return String(format: "$%.1f", cost)
        }
        return String(format: "$%.2f", cost)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 {
            return String(format: "%.1fB", Double(tokens) / 1_000_000_000)
        } else if tokens >= 1_000_000 {
            return String(format: "%.0fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.0fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}

// MARK: - Stat Block

private struct StatBlock: View {
    let value: String
    let label: String
    let icon: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Value
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color.opacity(0.9))

            // Label with icon
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .medium))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Model Distribution Chart

private struct ModelDistributionChart: View {
    let distribution: ModelDistribution

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section label
            Text("MODELS")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.quaternary)
                .tracking(0.5)

            // Legend with counts - vertical stack for clarity
            VStack(alignment: .leading, spacing: 4) {
                if distribution.opus > 0 {
                    modelRow(name: "Opus", count: distribution.opus, color: .modelOpus)
                }
                if distribution.sonnet > 0 {
                    modelRow(name: "Sonnet", count: distribution.sonnet, color: .modelSonnet)
                }
                if distribution.haiku > 0 {
                    modelRow(name: "Haiku", count: distribution.haiku, color: .modelHaiku)
                }
            }
        }
    }

    private func modelRow(name: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)

            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 24) {
        CommandBar(sessions: [
            Session(
                id: "1",
                projectPath: "/path/a",
                projectName: "project-a",
                model: "claude-opus-4-5-20251101",
                status: .active,
                workStatus: .working,
                startedAt: Date()
            ),
            Session(
                id: "2",
                projectPath: "/path/b",
                projectName: "project-b",
                model: "claude-sonnet-4-20250514",
                status: .active,
                workStatus: .waiting,
                startedAt: Date()
            ),
            Session(
                id: "3",
                projectPath: "/path/c",
                projectName: "project-c",
                model: "claude-sonnet-4-20250514",
                status: .ended,
                workStatus: .unknown,
                startedAt: Date().addingTimeInterval(-86400)
            ),
            Session(
                id: "4",
                projectPath: "/path/d",
                projectName: "project-d",
                model: "claude-haiku-3-5-20241022",
                status: .ended,
                workStatus: .unknown,
                startedAt: Date().addingTimeInterval(-172800)
            )
        ])
    }
    .padding(24)
    .background(Color.backgroundPrimary)
    .frame(width: 900)
}
