import SwiftUI

extension DirectSessionComposer {
  @ViewBuilder
  var turnActionsMenuContent: some View {
    if obs.isDirectCodex || serverState.session(sessionId).hasSlashCommand("undo") {
      Button {
        Task { try? await serverState.undoLastTurn(sessionId) }
      } label: {
        Label("Undo Last Turn", systemImage: "arrow.uturn.backward")
      }
      .disabled(serverState.session(sessionId).undoInProgress)
    }

    if obs.isDirect, let lastUserMsg = serverState.conversation(sessionId).messages.last(where: \.isUser) {
      let hasRecentCheckpoint = obs.lastFilesPersistedAt.map { Date().timeIntervalSince($0) < 300 } ?? false
      Button {
        Task { try? await serverState.rewindFiles(sessionId, userMessageId: lastUserMsg.id) }
      } label: {
        Label(
          hasRecentCheckpoint ? "Rewind Files (checkpoint saved)" : "Rewind Files",
          systemImage: "arrow.uturn.backward.circle"
        )
      }
      .disabled(obs.workStatus == .working)
    }

    Button {
      Task { try? await serverState.forkSession(sessionId: sessionId, nthUserMessage: nil) }
    } label: {
      Label("Fork Conversation", systemImage: "arrow.triangle.branch")
    }
    .disabled(!canForkConversation)

    Button {
      openForkToWorktreeSheet()
    } label: {
      Label("Fork to New Worktree", systemImage: "arrow.triangle.branch")
    }
    .disabled(!canForkToWorktree)

    Button {
      openForkToExistingWorktreeSheet()
    } label: {
      Label("Fork to Existing Worktree", systemImage: "arrow.triangle.branch.circlepath")
    }
    .disabled(!canForkToExistingWorktree)

    Menu {
      Button {
        router.openNewSession(provider: .claude, continuation: currentContinuation)
      } label: {
        Label("Claude Session", systemImage: "sparkles")
      }

      Button {
        router.openNewSession(provider: .codex, continuation: currentContinuation)
      } label: {
        Label("Codex Session", systemImage: "chevron.left.forwardslash.chevron.right")
      }
    } label: {
      Label("Continue in New Session", systemImage: "arrow.right.circle")
    }
    .disabled(!canContinueInNewSession)

    if obs.hasTokenUsage {
      Button {
        Task { try? await serverState.compactContext(sessionId) }
      } label: {
        Label("Compact Context", systemImage: "arrow.triangle.2.circlepath")
      }
    }

    if hasMcpData {
      Divider()
      Button {
        Task { try? await serverState.refreshMcpServers(sessionId) }
      } label: {
        Label("Refresh MCP Servers", systemImage: "arrow.clockwise")
      }
    }
  }

  var compactWorkflowOverflowMenu: some View {
    let composeIndicatorCount = selectedSkills.count + (manualShellMode ? 1 : 0)

    return Menu {
      Section("Compose") {
        Button {
          pickImages()
        } label: {
          Label("Attach Image", systemImage: "photo.badge.plus")
        }

        Button {
          openFilePicker()
        } label: {
          Label("Attach File (@)", systemImage: "doc.badge.plus")
        }

        if hasSkillsPanel {
          Button {
            Task { try? await serverState.listSkills(sessionId: sessionId) }
            activateCommandDeck(prefill: "skill")
          } label: {
            Label("Attach Skills", systemImage: "bolt.fill")
          }
        }

        if hasMcpData {
          Button {
            activateCommandDeck(prefill: "mcp")
          } label: {
            Label("Browse MCP", systemImage: "square.stack.3d.up.fill")
          }
        }

        Button {
          withAnimation(Motion.gentle) {
            manualShellMode.toggle()
            if manualShellMode { manualReviewMode = false }
          }
        } label: {
          Label(
            manualShellMode ? "Disable Shell Mode" : "Enable Shell Mode",
            systemImage: "terminal"
          )
        }
      }

      Section("Turn") {
        turnActionsMenuContent
      }
    } label: {
      actionDockLabel(
        icon: "ellipsis.circle",
        title: "More",
        tint: Color.textTertiary,
        isActive: composeIndicatorCount > 0
      )
      .overlay(alignment: .topTrailing) {
        if composeIndicatorCount > 0 {
          Text("\(min(composeIndicatorCount, 9))")
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(Color.accent, in: Capsule())
            .offset(x: 6, y: -5)
        }
      }
    }
    .menuStyle(.borderlessButton)
    .help("More actions")
  }

  var desktopWorkflowOverflowMenu: some View {
    let hasActiveState = !selectedSkills.isEmpty || manualShellMode

    return Menu {
      Section("Compose") {
        if hasSkillsPanel {
          Button {
            Task { try? await serverState.listSkills(sessionId: sessionId) }
            activateCommandDeck(prefill: "skill")
          } label: {
            Label("Attach Skills", systemImage: "bolt.fill")
          }
        }

        if hasMcpData {
          Button {
            activateCommandDeck(prefill: "mcp")
          } label: {
            Label("Browse MCP", systemImage: "square.stack.3d.up.fill")
          }
        }

        Button {
          withAnimation(Motion.gentle) {
            manualShellMode.toggle()
            if manualShellMode { manualReviewMode = false }
          }
        } label: {
          Label(
            manualShellMode ? "Disable Shell Mode" : "Enable Shell Mode",
            systemImage: "terminal"
          )
        }
      }

      Section("Turn") {
        turnActionsMenuContent
      }
    } label: {
      actionDockLabel(
        icon: "ellipsis.circle",
        title: "More",
        tint: Color.textTertiary,
        isActive: hasActiveState
      )
    }
    .menuStyle(.borderlessButton)
    .help("More actions")
  }
}
