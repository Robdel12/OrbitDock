//
//  TranscriptParser.swift
//  OrbitDock
//

import Foundation

// MARK: - Usage Stats

struct TranscriptUsageStats: Equatable {
  var inputTokens: Int = 0
  var outputTokens: Int = 0
  var cacheReadTokens: Int = 0
  var cacheCreationTokens: Int = 0
  var model: String?
  var contextUsed: Int = 0 // Latest context window usage

  var totalTokens: Int {
    inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
  }

  /// Context window size based on model (200k for most)
  var contextLimit: Int {
    200_000
  }

  var contextPercentage: Double {
    guard contextLimit > 0, contextUsed > 0 else { return 0 }
    return min(Double(contextUsed) / Double(contextLimit), 1.0)
  }

  var formattedContext: String {
    if contextUsed == 0 { return "--" }
    let k = Double(contextUsed) / 1_000.0
    return String(format: "%.0fk", k)
  }

  /// Estimated cost using ModelPricingService (fetches from LiteLLM)
  var estimatedCostUSD: Double {
    ModelPricingService.shared.calculateCost(
      model: model,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadTokens: cacheReadTokens,
      cacheCreationTokens: cacheCreationTokens
    )
  }

  var formattedCost: String {
    if estimatedCostUSD > 0 {
      return String(format: "$%.2f", estimatedCostUSD)
    }
    return "--"
  }
}
