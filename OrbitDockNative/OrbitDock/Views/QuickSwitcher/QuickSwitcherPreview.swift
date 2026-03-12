import SwiftUI

#Preview {
  ZStack {
    Color.black.opacity(0.5)
      .ignoresSafeArea()

    QuickSwitcher(
      sessions: [
        RootSessionRecord(summary: SessionSummary(session: Session(
          id: "1",
          projectPath: "/Users/developer/Developer/vizzly-cli",
          projectName: "vizzly-cli",
          branch: "feat/auth",
          model: "claude-opus-4-5-20251101",
          contextLabel: "Auth refactor",
          transcriptPath: nil,
          status: .active,
          workStatus: .working,
          startedAt: Date(),
          endedAt: nil,
          endReason: nil,
          totalTokens: 0,
          totalCostUSD: 0,
          lastActivityAt: nil,
          lastTool: nil,
          lastToolAt: nil,
          promptCount: 0,
          toolCount: 0,
          terminalSessionId: nil,
          terminalApp: nil
        ))),
        RootSessionRecord(summary: SessionSummary(session: Session(
          id: "2",
          projectPath: "/Users/developer/Developer/backchannel",
          projectName: "backchannel",
          branch: "main",
          model: "claude-sonnet-4-20250514",
          contextLabel: "API review",
          transcriptPath: nil,
          status: .active,
          workStatus: .waiting,
          startedAt: Date(),
          endedAt: nil,
          endReason: nil,
          totalTokens: 0,
          totalCostUSD: 0,
          lastActivityAt: nil,
          lastTool: nil,
          lastToolAt: nil,
          promptCount: 0,
          toolCount: 0,
          terminalSessionId: nil,
          terminalApp: nil
        ))),
        RootSessionRecord(summary: SessionSummary(session: Session(
          id: "3",
          projectPath: "/Users/developer/Developer/docs",
          projectName: "docs",
          branch: "main",
          model: "claude-haiku-3-5-20241022",
          contextLabel: nil,
          transcriptPath: nil,
          status: .ended,
          workStatus: .unknown,
          startedAt: Date().addingTimeInterval(-7_200),
          endedAt: Date().addingTimeInterval(-3_600),
          endReason: nil,
          totalTokens: 0,
          totalCostUSD: 0,
          lastActivityAt: nil,
          lastTool: nil,
          lastToolAt: nil,
          promptCount: 0,
          toolCount: 0,
          terminalSessionId: nil,
          terminalApp: nil
        ))),
      ],
      onQuickLaunchClaude: nil,
      onQuickLaunchCodex: nil
    )
    .environment(AppRouter())
  }
  .frame(width: 800, height: 600)
  .environment(SessionStore())
}
