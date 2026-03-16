//
//  URLBarVisual.swift
//  OrbitDock
//
//  Decorative browser-style URL bar display.
//  Used by WebFetchExpandedView for URL presentation.
//

import SwiftUI

struct URLBarVisual: View {
  let urlString: String
  var statusCode: Int?

  private var parsedURL: URL? { URL(string: urlString) }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "lock.fill")
        .font(.system(size: IconScale.xs))
        .foregroundStyle(Color.feedbackPositive.opacity(0.7))

      if let url = parsedURL {
        HStack(spacing: 0) {
          if let host = url.host {
            Text(host)
              .font(.system(size: TypeScale.code, weight: .semibold, design: .monospaced))
              .foregroundStyle(Color.textPrimary)
              .layoutPriority(1) // preserve domain on narrow screens
          }
          Text(url.path.isEmpty ? "/" : url.path)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      } else {
        Text(urlString)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      if let code = statusCode {
        statusBadge(code)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.ml))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml)
        .stroke(Color.textQuaternary.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func statusBadge(_ code: Int) -> some View {
    let color: Color = switch code {
    case 200..<300: .feedbackPositive
    case 300..<400: .feedbackCaution
    case 400..<500: .feedbackWarning
    default: .feedbackNegative
    }

    Text("\(code)")
      .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xxs)
      .background(color.opacity(OpacityTier.subtle), in: Capsule())
  }
}
