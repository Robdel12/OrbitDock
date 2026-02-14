//
//  ModelBadge.swift
//  OrbitDock
//
//  Unified model badge with size variants. Single source of truth for
//  model display names and colors across all views.
//

import SwiftUI

// MARK: - Model Helpers

/// Normalize a model string to a short display name
func displayNameForModel(_ model: String?, provider: Provider) -> String {
  guard let model = model?.lowercased(), !model.isEmpty else { return provider.displayName }
  if model.contains("opus") { return "Opus" }
  if model.contains("sonnet") { return "Sonnet" }
  if model.contains("haiku") { return "Haiku" }
  if model.hasPrefix("gpt-") {
    let version = model.dropFirst(4).split(separator: "-").first ?? ""
    return "GPT-\(version)"
  }
  if model == "openai" { return "OpenAI" }
  return String(model.prefix(8))
}

/// Get theme color for a model
func colorForModel(_ model: String?, provider: Provider) -> Color {
  guard let model = model?.lowercased() else { return provider.accentColor }
  if model.contains("opus") { return .modelOpus }
  if model.contains("sonnet") { return .modelSonnet }
  if model.contains("haiku") { return .modelHaiku }
  return provider.accentColor
}

// MARK: - Model Badge Size

enum ModelBadgeSize {
  case mini
  case compact
  case regular
}

// MARK: - Unified Model Badge

struct UnifiedModelBadge: View {
  let model: String?
  var provider: Provider = .claude
  var size: ModelBadgeSize = .regular

  var body: some View {
    HStack(spacing: spacing) {
      Image(systemName: provider.icon)
        .font(.system(size: iconSize, weight: .bold))
      Text(displayNameForModel(model, provider: provider))
        .font(.system(size: textSize, weight: textWeight, design: .rounded))
    }
    .foregroundStyle(colorForModel(model, provider: provider))
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .background(
      colorForModel(model, provider: provider).opacity(0.12),
      in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    )
  }

  // MARK: - Size-dependent properties

  private var spacing: CGFloat {
    switch size {
      case .mini: 3
      case .compact: 4
      case .regular: 5
    }
  }

  private var iconSize: CGFloat {
    switch size {
      case .mini: 8
      case .compact: 8
      case .regular: 9
    }
  }

  private var textSize: CGFloat {
    switch size {
      case .mini: 9
      case .compact: 9
      case .regular: 10
    }
  }

  private var textWeight: Font.Weight {
    switch size {
      case .mini: .semibold
      case .compact: .medium
      case .regular: .semibold
    }
  }

  private var horizontalPadding: CGFloat {
    switch size {
      case .mini: 6
      case .compact: 6
      case .regular: 8
    }
  }

  private var verticalPadding: CGFloat {
    switch size {
      case .mini: 3
      case .compact: 3
      case .regular: 4
    }
  }

  private var cornerRadius: CGFloat {
    switch size {
      case .mini: 4
      case .compact: 4
      case .regular: 6
    }
  }
}
