import SwiftUI

struct MissionPromptSection: View {
  let promptTemplate: String
  let repoRoot: String
  let missionFileName: String
  let isCompact: Bool
  @Binding var showFullTemplate: Bool
  @AppStorage("preferredEditor") private var preferredEditor: String = ""

  var body: some View {
    let previewLines = promptTemplate.split(separator: "\n", omittingEmptySubsequences: false).prefix(6)
    let hasContent = !promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let totalLines = promptTemplate.split(separator: "\n", omittingEmptySubsequences: false).count
    let isLong = totalLines > 6

    missionInstrumentPanel(
      title: "Agent Instructions",
      icon: "text.bubble",
      description: "What each agent is told when it picks up an issue",
      isCompact: isCompact
    ) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        if hasContent {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "doc.text")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)
            Text("\(totalLines) lines")
              .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
              .foregroundStyle(Color.textTertiary)

            if isLong {
              Text("·")
                .foregroundStyle(Color.textQuaternary)
              Button {
                withAnimation(Motion.standard) {
                  showFullTemplate.toggle()
                }
              } label: {
                Text(showFullTemplate ? "Collapse" : "Expand preview")
                  .font(.system(size: TypeScale.micro, weight: .medium))
                  .foregroundStyle(Color.accent)
              }
              .buttonStyle(.plain)
            }
          }

          ScrollView {
            VStack(alignment: .leading, spacing: 2) {
              let lines = showFullTemplate
                ? promptTemplate.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                : previewLines.map(String.init)

              ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                  .font(.system(size: TypeScale.micro, design: .monospaced))
                  .foregroundStyle(Color.textSecondary)
              }

              if !showFullTemplate, isLong {
                Text("...")
                  .font(.system(size: TypeScale.micro, design: .monospaced))
                  .foregroundStyle(Color.textQuaternary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: showFullTemplate ? 400 : nil)
          .padding(Spacing.md)
          .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .fill(Color.backgroundPrimary)
              .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                  .strokeBorder(Color.surfaceBorder, lineWidth: 1)
              )
          )
        } else {
          HStack(spacing: Spacing.sm) {
            Image(systemName: "doc.text.magnifyingglass")
              .font(.system(size: 12))
              .foregroundStyle(Color.textQuaternary)
            Text("No prompt template configured")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          }
          .padding(Spacing.md)
        }

        HStack(spacing: Spacing.md) {
          #if os(macOS)
            Button {
              openMissionFileInEditor()
            } label: {
              HStack(spacing: Spacing.sm_) {
                Image(systemName: "pencil.and.outline")
                  .font(.system(size: 11, weight: .semibold))
                Text("Edit in \(editorName)")
                  .font(.system(size: TypeScale.caption, weight: .medium))
              }
              .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)

            Button {
              let path = repoRoot.hasSuffix("/") ? repoRoot + missionFileName : repoRoot + "/\(missionFileName)"
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(path, forType: .string)
            } label: {
              HStack(spacing: Spacing.sm_) {
                Image(systemName: "doc.on.clipboard")
                  .font(.system(size: 11, weight: .semibold))
                Text("Copy Path")
                  .font(.system(size: TypeScale.caption, weight: .medium))
              }
              .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)
          #endif

          Spacer()

          if !isCompact {
            HStack(spacing: Spacing.sm) {
              variableTag("issue.identifier")
              variableTag("issue.title")
              variableTag("attempt")
              Text("+3 more")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
            }
          }
        }

        HStack(spacing: Spacing.sm_) {
          Image(systemName: "info.circle")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
          Text("This is what each agent receives when dispatched to an issue. Review before starting the orchestrator.")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func variableTag(_ name: String) -> some View {
    Text("{{ \(name) }}")
      .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
      .foregroundStyle(Color.accent.opacity(OpacityTier.strong))
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, 2)
      .background(
        Color.accent.opacity(OpacityTier.subtle),
        in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
      )
  }

  private var editorName: String {
    switch preferredEditor {
      case "code": "VS Code"
      case "cursor": "Cursor"
      case "zed": "Zed"
      case "subl": "Sublime"
      case "emacs": "Emacs"
      case "vim": "Vim"
      case "nvim": "Neovim"
      default: "Editor"
    }
  }

  private func openMissionFileInEditor() {
    let missionPath = repoRoot.hasSuffix("/")
      ? repoRoot + "MISSION.md"
      : repoRoot + "/MISSION.md"

    #if os(macOS)
      if !preferredEditor.isEmpty {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [preferredEditor, missionPath]
        try? process.run()
      } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: missionPath))
      }
    #else
      // iOS: can't open local files in external editors, but the preview still works
    #endif
  }
}
