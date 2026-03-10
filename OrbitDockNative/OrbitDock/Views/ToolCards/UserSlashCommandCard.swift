import SwiftUI

struct UserSlashCommandCard: View {
  let command: ParsedSlashCommand
  let timestamp: Date

  @State private var isHovering = false

  private let commandColor = Color.toolSkill

  private var hasCommand: Bool {
    !command.name.isEmpty
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: Spacing.md_) {
      HStack(spacing: Spacing.sm) {
        Text(ToolCardTimestamp.format(timestamp))
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)

        Text("You")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }

      if hasCommand {
        HStack(spacing: Spacing.md_) {
          Image(systemName: "slash.circle.fill")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(commandColor)

          Text(command.name)
            .font(.system(size: TypeScale.code, weight: .semibold, design: .monospaced))
            .foregroundStyle(commandColor)

          if command.hasArgs {
            Text(command.args)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(.primary.opacity(0.85))
              .lineLimit(1)
          }

          Spacer()
        }
        .padding(.horizontal, Spacing.lg_)
        .padding(.vertical, Spacing.md_)
        .background(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(commandColor.opacity(isHovering ? 0.12 : 0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(commandColor.opacity(0.15), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
      }

      if command.hasOutput {
        HStack(spacing: Spacing.sm) {
          Image(systemName: hasCommand ? "arrow.turn.down.right" : "text.bubble")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(hasCommand ? Color.textTertiary : commandColor)

          Text(command.stdout)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(hasCommand ? Color.textSecondary : Color.textPrimary)
            .lineLimit(3)

          Spacer()
        }
        .padding(.horizontal, Spacing.lg_)
        .padding(.vertical, hasCommand ? Spacing.sm : Spacing.md_)
        .background(
          RoundedRectangle(cornerRadius: hasCommand ? Radius.ml : Radius.lg, style: .continuous)
            .fill(hasCommand ? Color.backgroundTertiary : commandColor.opacity(0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: hasCommand ? Radius.ml : Radius.lg, style: .continuous)
            .strokeBorder(hasCommand ? Color.clear : commandColor.opacity(0.15), lineWidth: 1)
        )
      }
    }
  }
}

#Preview("Slash Commands") {
  VStack(alignment: .trailing, spacing: Spacing.section) {
    UserSlashCommandCard(
      command: ParsedSlashCommand(
        name: "/rename",
        message: "rename",
        args: "Design system and colors",
        stdout: ""
      ),
      timestamp: Date()
    )

    UserSlashCommandCard(
      command: ParsedSlashCommand(
        name: "/commit",
        message: "commit",
        args: "",
        stdout: "Created commit abc123"
      ),
      timestamp: Date()
    )

    UserSlashCommandCard(
      command: ParsedSlashCommand(
        name: "",
        message: "",
        args: "",
        stdout: "Session renamed to: Design system and colors"
      ),
      timestamp: Date()
    )
  }
  .padding(Spacing.xxl)
  .frame(width: 600)
  .background(Color.backgroundPrimary)
}
