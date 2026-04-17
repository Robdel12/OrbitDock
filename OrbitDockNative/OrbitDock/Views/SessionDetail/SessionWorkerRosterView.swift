import SwiftUI

struct SessionWorkerRosterView: View {
  let presentation: SessionWorkerRosterPresentation
  let selectedWorkerID: String?
  let onSelectWorker: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      workerHeader

      VStack(spacing: Spacing.sm) {
        ForEach(presentation.workers) { worker in
          workerRow(worker)
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.md)
    .padding(.bottom, Spacing.sm)
  }

  private var workerHeader: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .center, spacing: Spacing.sm) {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(0.92))

          Image(systemName: "person.3.sequence.fill")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.accent)
        }
        .frame(width: 34, height: 34)

        VStack(alignment: .leading, spacing: 2) {
          Text(presentation.title)
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(presentation.summary)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textSecondary)
        }

        Spacer(minLength: 0)
      }

      Text(presentation.detailPrompt)
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textQuaternary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func workerRow(_ worker: SessionWorkerRosterPresentation.Worker) -> some View {
    let isSelected = worker.id == selectedWorkerID

    return Button {
      onSelectWorker(worker.id)
    } label: {
      HStack(alignment: .top, spacing: Spacing.sm) {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(isSelected ? Color.surfaceSelected.opacity(0.8) : Color.backgroundTertiary.opacity(0.92))

          Image(systemName: worker.iconName)
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(isSelected ? Color.accent : worker.statusColor)
        }
        .frame(width: 28, height: 28)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(worker.title)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
              .lineLimit(1)

            Spacer(minLength: 0)

            statusCapsule(label: worker.statusLabel, color: worker.statusColor)
          }

          if let subtitle = worker.subtitle {
            Text(subtitle)
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(2)
          } else {
            Text(worker.isActive ? "Watching for the next update." : "No additional worker note captured.")
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textQuaternary)
              .lineLimit(2)
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm_)
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .fill(isSelected ? Color.surfaceSelected.opacity(0.9) : Color.backgroundSecondary.opacity(0.72))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .stroke(isSelected ? Color.accent.opacity(0.35) : Color.panelBorder.opacity(0.45), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  private func statusCapsule(label: String, color: Color) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)

      Text(label)
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .foregroundStyle(color)
    }
    .padding(.horizontal, Spacing.xs)
    .padding(.vertical, 5)
    .background(color.opacity(0.12), in: Capsule())
  }
}
