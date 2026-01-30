//
//  TranscriptParser.swift
//  CommandCenter
//

import Foundation

// MARK: - Usage Stats

struct TranscriptUsageStats: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var model: String?
    var contextUsed: Int = 0  // Latest context window usage

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    // Context window size based on model (200k for most)
    var contextLimit: Int {
        200_000
    }

    var contextPercentage: Double {
        guard contextLimit > 0, contextUsed > 0 else { return 0 }
        return min(Double(contextUsed) / Double(contextLimit), 1.0)
    }

    var formattedContext: String {
        if contextUsed == 0 { return "--" }
        let k = Double(contextUsed) / 1000.0
        return String(format: "%.0fk", k)
    }

    // Pricing per million tokens (approximate, as of Jan 2025)
    var estimatedCostUSD: Double {
        let isOpus = model?.contains("opus") ?? false

        if isOpus {
            let inputCost = Double(inputTokens) / 1_000_000 * 15.0
            let outputCost = Double(outputTokens) / 1_000_000 * 75.0
            let cacheReadCost = Double(cacheReadTokens) / 1_000_000 * 1.875
            let cacheWriteCost = Double(cacheCreationTokens) / 1_000_000 * 18.75
            return inputCost + outputCost + cacheReadCost + cacheWriteCost
        } else {
            let inputCost = Double(inputTokens) / 1_000_000 * 3.0
            let outputCost = Double(outputTokens) / 1_000_000 * 15.0
            let cacheReadCost = Double(cacheReadTokens) / 1_000_000 * 0.30
            let cacheWriteCost = Double(cacheCreationTokens) / 1_000_000 * 3.75
            return inputCost + outputCost + cacheReadCost + cacheWriteCost
        }
    }

    var formattedCost: String {
        if estimatedCostUSD > 0 {
            return String(format: "$%.2f", estimatedCostUSD)
        }
        return "--"
    }

    static func == (lhs: TranscriptUsageStats, rhs: TranscriptUsageStats) -> Bool {
        lhs.inputTokens == rhs.inputTokens &&
        lhs.outputTokens == rhs.outputTokens &&
        lhs.cacheReadTokens == rhs.cacheReadTokens &&
        lhs.cacheCreationTokens == rhs.cacheCreationTokens &&
        lhs.contextUsed == rhs.contextUsed &&
        lhs.model == rhs.model
    }
}

// MARK: - Transcript Parser

struct TranscriptParser {

    static func parse(transcriptPath: String) -> [TranscriptMessage] {
        guard FileManager.default.fileExists(atPath: transcriptPath) else {
            return []
        }

        guard let content = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        var messages: [TranscriptMessage] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard let type = json["type"] as? String,
                  let uuid = json["uuid"] as? String else {
                continue
            }

            let timestamp = parseTimestamp(json["timestamp"] as? String)

            switch type {
            case "user":
                if let message = json["message"] as? [String: Any],
                   let content = extractUserContent(from: message) {
                    messages.append(TranscriptMessage(
                        id: uuid,
                        type: .user,
                        content: content,
                        timestamp: timestamp,
                        toolName: nil,
                        toolInput: nil,
                        inputTokens: nil,
                        outputTokens: nil
                    ))
                }

            case "assistant":
                if let message = json["message"] as? [String: Any] {
                    // Extract usage data
                    let usage = message["usage"] as? [String: Any]
                    let inputTokens = usage?["input_tokens"] as? Int
                    let outputTokens = usage?["output_tokens"] as? Int

                    // Extract text content
                    if let content = extractAssistantContent(from: message), !content.isEmpty {
                        messages.append(TranscriptMessage(
                            id: uuid + "-text",
                            type: .assistant,
                            content: content,
                            timestamp: timestamp,
                            toolName: nil,
                            toolInput: nil,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens
                        ))
                    }

                    // Extract tool calls
                    if let contentArray = message["content"] as? [[String: Any]] {
                        for (index, item) in contentArray.enumerated() {
                            if item["type"] as? String == "tool_use",
                               let toolName = item["name"] as? String,
                               item["id"] as? String != nil {
                                let input = item["input"] as? [String: Any]

                                // Create a summary for the tool call
                                let summary = createToolSummary(toolName: toolName, input: input)

                                messages.append(TranscriptMessage(
                                    id: "\(uuid)-tool-\(index)",
                                    type: .tool,
                                    content: summary,
                                    timestamp: timestamp,
                                    toolName: toolName,
                                    toolInput: input,
                                    inputTokens: nil,
                                    outputTokens: nil
                                ))
                            }
                        }
                    }
                }

            default:
                break
            }
        }

        return messages
    }

    // MARK: - Tool Summary

    private static func createToolSummary(toolName: String, input: [String: Any]?) -> String {
        guard let input = input else { return toolName }

        switch toolName.lowercased() {
        case "read":
            if let path = input["file_path"] as? String {
                return shortenPath(path)
            }
        case "edit":
            if let path = input["file_path"] as? String {
                return shortenPath(path)
            }
        case "write":
            if let path = input["file_path"] as? String {
                return shortenPath(path)
            }
        case "bash":
            if let command = input["command"] as? String {
                let truncated = command.count > 60 ? String(command.prefix(60)) + "..." : command
                return truncated.replacingOccurrences(of: "\n", with: " ")
            }
        case "glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "grep":
            if let pattern = input["pattern"] as? String {
                return "Pattern: \(pattern)"
            }
        case "task":
            if let prompt = input["prompt"] as? String {
                let truncated = prompt.count > 50 ? String(prompt.prefix(50)) + "..." : prompt
                return truncated
            }
        default:
            break
        }

        return toolName
    }

    private static func shortenPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count > 3 {
            return ".../" + components.suffix(2).joined(separator: "/")
        }
        return path
    }

    // MARK: - Usage Stats Parsing

    static func parseUsageStats(transcriptPath: String) -> TranscriptUsageStats {
        guard FileManager.default.fileExists(atPath: transcriptPath) else {
            return TranscriptUsageStats()
        }

        guard let content = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return TranscriptUsageStats()
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        var stats = TranscriptUsageStats()
        var latestContextUsed = 0

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let model = json["model"] as? String, stats.model == nil {
                stats.model = model
            }

            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                stats.inputTokens += (usage["input_tokens"] as? Int) ?? 0
                stats.outputTokens += (usage["output_tokens"] as? Int) ?? 0
                stats.cacheReadTokens += (usage["cache_read_input_tokens"] as? Int) ?? 0
                stats.cacheCreationTokens += (usage["cache_creation_input_tokens"] as? Int) ?? 0

                // Track the latest context usage (input + cache_read gives approximate context size)
                let inputT = (usage["input_tokens"] as? Int) ?? 0
                let cacheReadT = (usage["cache_read_input_tokens"] as? Int) ?? 0
                let cacheCreateT = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let contextForThisCall = inputT + cacheReadT + cacheCreateT
                if contextForThisCall > 0 {
                    latestContextUsed = contextForThisCall
                }
            }
        }

        stats.contextUsed = latestContextUsed
        return stats
    }

    // MARK: - Last Tool Detection

    static func parseLastTool(transcriptPath: String) -> String? {
        guard FileManager.default.fileExists(atPath: transcriptPath) else {
            return nil
        }

        guard let content = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let recentLines = lines.suffix(50)

        var lastTool: String?

        for line in recentLines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for item in content {
                    if item["type"] as? String == "tool_use",
                       let name = item["name"] as? String {
                        lastTool = name
                    }
                }
            }
        }

        return lastTool
    }

    // MARK: - Private Helpers

    private static func extractUserContent(from message: [String: Any]) -> String? {
        if let content = message["content"] as? String {
            return content
        }

        if let content = message["content"] as? [[String: Any]] {
            if content.first?["type"] as? String == "tool_result" {
                return nil
            }
            let texts = content.compactMap { item -> String? in
                if item["type"] as? String == "text" {
                    return item["text"] as? String
                }
                return nil
            }
            return texts.joined(separator: "\n")
        }

        return nil
    }

    private static func extractAssistantContent(from message: [String: Any]) -> String? {
        guard let content = message["content"] as? [[String: Any]] else {
            return nil
        }

        let texts = content.compactMap { item -> String? in
            if item["type"] as? String == "text" {
                return item["text"] as? String
            }
            return nil
        }

        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func parseTimestamp(_ timestamp: String?) -> Date {
        guard let ts = timestamp else { return Date() }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: ts) ?? Date()
    }
}
