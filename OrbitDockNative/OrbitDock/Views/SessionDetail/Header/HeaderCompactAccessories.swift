import SwiftUI

struct StatusPillCompact: View {
  let workStatus: Session.WorkStatus
  let currentTool: String?

  private var color: Color {
    switch workStatus {
      case .working: .statusWorking
      case .waiting: .statusReply
      case .permission: .statusPermission
      case .unknown: .secondary
    }
  }

  private var icon: String {
    switch workStatus {
      case .working: "bolt.fill"
      case .waiting: "clock"
      case .permission: "lock.fill"
      case .unknown: "circle"
    }
  }

  private var label: String {
    switch workStatus {
      case .working:
        if let tool = currentTool {
          return tool
        }
        return "Working"
      case .waiting: return "Waiting"
      case .permission: return "Permission"
      case .unknown: return ""
    }
  }

  var body: some View {
    if workStatus != .unknown {
      HStack(spacing: Spacing.xs) {
        if workStatus == .working {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: icon)
            .font(.system(size: 8, weight: .bold))
        }
        Text(label)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .lineLimit(1)
      }
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(color.opacity(OpacityTier.light), in: Capsule())
    }
  }
}

struct ContextGaugeCompact: View {
  let stats: TranscriptUsageStats

  private var progressColor: Color {
    if stats.contextPercentage > 0.9 { return .statusError }
    if stats.contextPercentage > 0.7 { return .feedbackCaution }
    return .accent
  }

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .fill(Color.primary.opacity(0.1))

          RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .fill(progressColor)
            .frame(width: geo.size.width * stats.contextPercentage)
        }
      }
      .frame(width: 32, height: 4)

      Text("\(Int(stats.contextPercentage * 100))%")
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(progressColor)
    }
  }
}

struct CodexTokenBadge: View {
  let sessionId: String
  @Environment(SessionStore.self) private var serverState

  private var obs: SessionObservable {
    serverState.session(sessionId)
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      if let window = obs.contextWindow, window > 0 {
        Text("\(contextPercent)%")
          .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
          .foregroundStyle(contextColor)

        Text("of \(formatTokenCount(window))")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textTertiary)
      } else {
        Text(formatTokenCount(obs.effectiveContextInputTokens))
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
        Text("tokens")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textTertiary)
      }

      if cacheSavingsPercent >= 10 {
        HStack(spacing: Spacing.xxs) {
          Image(systemName: "bolt.fill")
            .font(.system(size: 8))
          Text("\(cacheSavingsPercent)%")
            .font(.system(size: TypeScale.micro, design: .monospaced))
        }
        .foregroundStyle(Color.feedbackPositive.opacity(0.85))
      }
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.vertical, 5)
    .background(Color.surfaceHover, in: Capsule())
    .help(tokenTooltip)
  }

  private var contextPercent: Int {
    min(100, Int(obs.contextFillPercent))
  }

  private var contextColor: Color {
    if contextPercent >= 90 { return .statusError }
    if contextPercent >= 70 { return .feedbackCaution }
    return .secondary
  }

  private var cacheSavingsPercent: Int {
    Int(obs.effectiveCacheHitPercent)
  }

  private var tokenTooltip: String {
    var parts: [String] = []

    if let input = obs.inputTokens {
      parts.append("Input: \(formatTokenCount(input))")
    }
    if let output = obs.outputTokens {
      parts.append("Output: \(formatTokenCount(output))")
    }
    if let cached = obs.cachedTokens, cached > 0,
       obs.effectiveContextInputTokens > 0
    {
      let percent = Int(obs.effectiveCacheHitPercent)
      parts.append("Cached: \(formatTokenCount(cached)) (\(percent)% savings)")
    }
    if let window = obs.contextWindow {
      parts.append("Context window: \(formatTokenCount(window))")
    }

    return parts.isEmpty ? "Token usage" : parts.joined(separator: "\n")
  }

  private func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
      return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
      return String(format: "%.1fk", Double(count) / 1_000)
    }
    return "\(count)"
  }
}
