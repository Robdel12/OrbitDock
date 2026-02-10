//
//  ModelPricing.swift
//  OrbitDock
//
//  Fetches accurate model pricing from LiteLLM's pricing database.
//  Falls back to hardcoded defaults if offline.
//

import Foundation

/// Model pricing data
struct ModelPrice: Codable {
  let inputCostPerToken: Double?
  let outputCostPerToken: Double?
  let cacheReadInputTokenCost: Double?
  let cacheCreationInputTokenCost: Double?

  enum CodingKeys: String, CodingKey {
    case inputCostPerToken = "input_cost_per_token"
    case outputCostPerToken = "output_cost_per_token"
    case cacheReadInputTokenCost = "cache_read_input_token_cost"
    case cacheCreationInputTokenCost = "cache_creation_input_token_cost"
  }

  /// Cost per million tokens (for display)
  var inputPerMillion: Double {
    (inputCostPerToken ?? 0) * 1_000_000
  }

  var outputPerMillion: Double {
    (outputCostPerToken ?? 0) * 1_000_000
  }

  var cacheReadPerMillion: Double {
    (cacheReadInputTokenCost ?? 0) * 1_000_000
  }

  var cacheWritePerMillion: Double {
    (cacheCreationInputTokenCost ?? 0) * 1_000_000
  }
}

/// Service for fetching and caching model pricing
final class ModelPricingService: @unchecked Sendable {
  static let shared = ModelPricingService()

  private let lock = NSLock()
  private var _prices: [String: ModelPrice] = [:]
  private var _isLoading = false
  private var _lastUpdated: Date?

  var prices: [String: ModelPrice] {
    lock.lock()
    defer { lock.unlock() }
    return _prices
  }

  var isLoading: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _isLoading
  }

  var lastUpdated: Date? {
    lock.lock()
    defer { lock.unlock() }
    return _lastUpdated
  }

  private let cacheURL: URL
  private let liteLLMURL =
    URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

  private init() {
    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    cacheURL = cacheDir.appendingPathComponent("model_pricing.json")
    loadCachedPrices()
  }

  /// Load cached prices from disk
  private func loadCachedPrices() {
    guard FileManager.default.fileExists(atPath: cacheURL.path) else {
      loadDefaultPrices()
      return
    }

    do {
      let data = try Data(contentsOf: cacheURL)
      let decoded = try JSONDecoder().decode([String: ModelPrice].self, from: data)
      lock.lock()
      _prices = decoded
      if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
         let modDate = attrs[.modificationDate] as? Date
      {
        _lastUpdated = modDate
      }
      lock.unlock()
    } catch {
      print("[ModelPricing] Failed to load cache: \(error)")
      loadDefaultPrices()
    }
  }

  /// Load default hardcoded prices
  private func loadDefaultPrices() {
    // Fallback prices (per token, not per million)
    lock.lock()
    _prices = [
      "claude-3-5-haiku": ModelPrice(
        inputCostPerToken: 0.8 / 1_000_000,
        outputCostPerToken: 4.0 / 1_000_000,
        cacheReadInputTokenCost: 0.08 / 1_000_000,
        cacheCreationInputTokenCost: 1.0 / 1_000_000
      ),
      "claude-sonnet-4": ModelPrice(
        inputCostPerToken: 3.0 / 1_000_000,
        outputCostPerToken: 15.0 / 1_000_000,
        cacheReadInputTokenCost: 0.30 / 1_000_000,
        cacheCreationInputTokenCost: 3.75 / 1_000_000
      ),
      "claude-opus-4": ModelPrice(
        inputCostPerToken: 15.0 / 1_000_000,
        outputCostPerToken: 75.0 / 1_000_000,
        cacheReadInputTokenCost: 1.875 / 1_000_000,
        cacheCreationInputTokenCost: 18.75 / 1_000_000
      ),
      "gpt-5": ModelPrice(
        inputCostPerToken: 2.0 / 1_000_000,
        outputCostPerToken: 10.0 / 1_000_000,
        cacheReadInputTokenCost: nil,
        cacheCreationInputTokenCost: nil
      ),
    ]
    lock.unlock()
  }

  /// Fetch latest prices from LiteLLM
  func fetchPrices() {
    // Check loading state synchronously
    lock.lock()
    guard !_isLoading else {
      lock.unlock()
      return
    }
    _isLoading = true
    lock.unlock()

    // Spawn async work on background queue
    DispatchQueue.global(qos: .utility).async { [self] in
      do {
        let data = try Data(contentsOf: liteLLMURL)
        let decoded = try JSONDecoder().decode([String: ModelPrice].self, from: data)

        // Save to cache
        try data.write(to: cacheURL)

        // Update state synchronously
        lock.lock()
        _prices = decoded
        _lastUpdated = Date()
        _isLoading = false
        lock.unlock()

        print("[ModelPricing] Loaded \(decoded.count) models from LiteLLM")
      } catch {
        print("[ModelPricing] Failed to fetch: \(error)")
        lock.lock()
        _isLoading = false
        lock.unlock()
      }
    }
  }

  /// Get pricing for a model (with fuzzy matching)
  func price(for model: String?) -> ModelPrice? {
    guard let model = model?.lowercased() else { return nil }

    // Direct match
    if let price = prices[model] { return price }

    // Try with provider prefix
    for prefix in ["anthropic/", "claude-", "openai/", ""] {
      if let price = prices[prefix + model] { return price }
    }

    // Fuzzy match for Claude models
    if model.contains("opus") {
      return prices["claude-opus-4-5-20250514"]
        ?? prices["claude-opus-4"]
        ?? prices["anthropic/claude-opus-4-5-20250514"]
    }
    if model.contains("sonnet") {
      return prices["claude-sonnet-4-20250514"]
        ?? prices["claude-sonnet-4"]
        ?? prices["anthropic/claude-sonnet-4-20250514"]
    }
    if model.contains("haiku") {
      return prices["claude-3-5-haiku-20241022"]
        ?? prices["claude-3-5-haiku"]
        ?? prices["anthropic/claude-3-5-haiku-20241022"]
    }

    // GPT models
    if model.contains("gpt-5") {
      return prices["gpt-5"] ?? prices["openai/gpt-5"]
    }

    return nil
  }

  /// Calculate cost for tokens
  func calculateCost(
    model: String?,
    inputTokens: Int,
    outputTokens: Int,
    cacheReadTokens: Int = 0,
    cacheCreationTokens: Int = 0
  ) -> Double {
    guard let pricing = price(for: model) else {
      // Fallback to Sonnet pricing
      let input = Double(inputTokens) / 1_000_000 * 3.0
      let output = Double(outputTokens) / 1_000_000 * 15.0
      let cacheRead = Double(cacheReadTokens) / 1_000_000 * 0.30
      let cacheWrite = Double(cacheCreationTokens) / 1_000_000 * 3.75
      return input + output + cacheRead + cacheWrite
    }

    let input = Double(inputTokens) * (pricing.inputCostPerToken ?? 0)
    let output = Double(outputTokens) * (pricing.outputCostPerToken ?? 0)
    let cacheRead = Double(cacheReadTokens) * (pricing.cacheReadInputTokenCost ?? 0)
    let cacheWrite = Double(cacheCreationTokens) * (pricing.cacheCreationInputTokenCost ?? 0)

    return input + output + cacheRead + cacheWrite
  }
}
