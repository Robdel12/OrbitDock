//
//  TranscriptParser.swift
//  CommandCenter
//

import Foundation

// MARK: - Unified Parse Result (single pass)

struct TranscriptParseResult {
    let messages: [TranscriptMessage]
    let stats: TranscriptUsageStats
    let lastUserPrompt: String?
    let lastTool: String?
}

// MARK: - Parse Cache (avoid redundant parses within same update cycle)

private class ParseCache {
    static let shared = ParseCache()

    private var cache: [String: (timestamp: CFAbsoluteTime, result: TranscriptParseResult)] = [:]
    private var pathLocks: [String: NSLock] = [:]
    private let metaLock = NSLock()
    private let cacheValidityMs: Double = 100 // Cache valid for 100ms (just to catch simultaneous calls)

    /// Get or create a lock for a specific path
    private func lockForPath(_ path: String) -> NSLock {
        metaLock.lock()
        defer { metaLock.unlock() }

        if let existing = pathLocks[path] {
            return existing
        }
        let newLock = NSLock()
        pathLocks[path] = newLock
        return newLock
    }

    /// Check cache (call BEFORE acquiring path lock)
    func getCached(path: String) -> TranscriptParseResult? {
        metaLock.lock()
        defer { metaLock.unlock() }

        guard let entry = cache[path] else { return nil }

        let ageMs = (CFAbsoluteTimeGetCurrent() - entry.timestamp) * 1000
        if ageMs < cacheValidityMs {
            return entry.result
        }
        return nil
    }

    /// Acquire lock for parsing (blocks if another parse in progress)
    func acquireParseLock(path: String) -> NSLock {
        let lock = lockForPath(path)
        lock.lock()
        return lock
    }

    func set(path: String, result: TranscriptParseResult) {
        metaLock.lock()
        defer { metaLock.unlock() }
        cache[path] = (timestamp: CFAbsoluteTimeGetCurrent(), result: result)
    }

    /// Invalidate cache for a path (call when file changes)
    func invalidate(path: String) {
        metaLock.lock()
        defer { metaLock.unlock() }
        cache.removeValue(forKey: path)
    }
}

// MARK: - Cache Invalidation (public API)

extension TranscriptParser {
    /// Call this when file changes are detected to ensure fresh data
    static func invalidateCache(for path: String) {
        ParseCache.shared.invalidate(path: path)
    }
}

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
        let start = CFAbsoluteTimeGetCurrent()

        guard FileManager.default.fileExists(atPath: transcriptPath) else {
            return []
        }

        let readStart = CFAbsoluteTimeGetCurrent()
        guard let content = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return []
        }
        let readTime = (CFAbsoluteTimeGetCurrent() - readStart) * 1000

        let splitStart = CFAbsoluteTimeGetCurrent()
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let splitTime = (CFAbsoluteTimeGetCurrent() - splitStart) * 1000
        var messages: [TranscriptMessage] = []
        var toolResults: [String: (output: String, timestamp: Date)] = [:]
        var toolUseTimestamps: [String: Date] = [:]
        var pendingToolIds: Set<String> = [] // Track tools without results yet

        // First pass: collect tool results and tool_use timestamps
        let pass1Start = CFAbsoluteTimeGetCurrent()
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let entryTimestamp = parseTimestamp(json["timestamp"] as? String)

            // Collect tool_use timestamps
            if json["type"] as? String == "assistant",
               let message = json["message"] as? [String: Any],
               let contentArray = message["content"] as? [[String: Any]] {
                for item in contentArray {
                    if item["type"] as? String == "tool_use",
                       let toolId = item["id"] as? String {
                        toolUseTimestamps[toolId] = entryTimestamp
                    }
                }
            }

            // Collect tool_result outputs and timestamps
            if json["type"] as? String == "user",
               let message = json["message"] as? [String: Any],
               let contentArray = message["content"] as? [[String: Any]] {
                for item in contentArray {
                    if item["type"] as? String == "tool_result",
                       let toolUseId = item["tool_use_id"] as? String {
                        let resultContent = extractToolResultContent(from: item)
                        toolResults[toolUseId] = (output: resultContent, timestamp: entryTimestamp)
                    }
                }
            }
        }

        let pass1Time = (CFAbsoluteTimeGetCurrent() - pass1Start) * 1000

        // Second pass: build messages with results
        let pass2Start = CFAbsoluteTimeGetCurrent()
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
                if let message = json["message"] as? [String: Any] {
                    let content = extractUserContent(from: message) ?? ""
                    let images = extractImagesFromMessage(message)

                    // Only add if there's content or images
                    if !content.isEmpty || !images.isEmpty {
                        messages.append(TranscriptMessage(
                            id: uuid,
                            type: .user,
                            content: content,
                            timestamp: timestamp,
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            toolDuration: nil,
                            inputTokens: nil,
                            outputTokens: nil,
                            images: images
                        ))
                    }
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
                            toolOutput: nil,
                            toolDuration: nil,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens
                        ))
                    }

                    // Extract tool calls
                    if let contentArray = message["content"] as? [[String: Any]] {
                        for (index, item) in contentArray.enumerated() {
                            if item["type"] as? String == "tool_use",
                               let toolName = item["name"] as? String,
                               let toolId = item["id"] as? String {
                                let input = item["input"] as? [String: Any]

                                // Create a summary for the tool call
                                let summary = createToolSummary(toolName: toolName, input: input)

                                // Check if we have a result for this tool
                                let result = toolResults[toolId]
                                let hasResult = result != nil
                                pendingToolIds.insert(toolId)
                                if hasResult {
                                    pendingToolIds.remove(toolId)
                                }

                                // Calculate duration if we have both timestamps
                                let duration: TimeInterval? = {
                                    guard let toolUseTime = toolUseTimestamps[toolId],
                                          let resultTime = result?.timestamp else { return nil }
                                    let diff = resultTime.timeIntervalSince(toolUseTime)
                                    return diff > 0 ? diff : nil
                                }()

                                var msg = TranscriptMessage(
                                    id: "\(uuid)-tool-\(index)",
                                    type: .tool,
                                    content: summary,
                                    timestamp: timestamp,
                                    toolName: toolName,
                                    toolInput: input,
                                    toolOutput: result?.output,
                                    toolDuration: duration,
                                    inputTokens: nil,
                                    outputTokens: nil
                                )
                                msg.isInProgress = !hasResult
                                messages.append(msg)
                            }
                        }
                    }
                }

            default:
                break
            }
        }
        let pass2Time = (CFAbsoluteTimeGetCurrent() - pass2Start) * 1000
        let totalTime = (CFAbsoluteTimeGetCurrent() - start) * 1000

        if totalTime > 500 {  // Only log slow parses
            print("📊 Parse: \(String(format: "%.1f", totalTime))ms | \(lines.count) lines → \(messages.count) msgs")
        }

        return messages
    }

    // Extract the last user prompt (for showing what Claude is working on)
    static func parseCurrentPrompt(transcriptPath: String) -> String? {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if elapsed > 5 { // Only log if > 5ms
                print("📝 parseCurrentPrompt: \(String(format: "%.1f", elapsed))ms")
            }
        }

        guard FileManager.default.fileExists(atPath: transcriptPath) else {
            return nil
        }

        guard let content = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        var lastUserPrompt: String?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if json["type"] as? String == "user",
               let message = json["message"] as? [String: Any],
               let content = extractUserContent(from: message) {
                lastUserPrompt = content
            }
        }

        return lastUserPrompt
    }

    private static func extractToolResultContent(from item: [String: Any]) -> String {
        if let content = item["content"] as? String {
            return content
        }
        if let contentArray = item["content"] as? [[String: Any]] {
            let texts = contentArray.compactMap { block -> String? in
                if block["type"] as? String == "text" {
                    return block["text"] as? String
                }
                return nil
            }
            return texts.joined(separator: "\n")
        }
        return ""
    }

    // Extract ALL base64 images from user message
    private static func extractImagesFromMessage(_ message: [String: Any]) -> [MessageImage] {
        guard let contentArray = message["content"] as? [[String: Any]] else {
            return []
        }

        var images: [MessageImage] = []
        for item in contentArray {
            if item["type"] as? String == "image",
               let source = item["source"] as? [String: Any],
               source["type"] as? String == "base64",
               let mediaType = source["media_type"] as? String,
               let base64String = source["data"] as? String,
               let data = Data(base64Encoded: base64String) {
                images.append(MessageImage(data: data, mimeType: mediaType))
            }
        }

        return images
    }

    // Legacy single image extraction (for backwards compatibility)
    private static func extractImageFromMessage(_ message: [String: Any]) -> (data: Data, mimeType: String)? {
        let images = extractImagesFromMessage(message)
        guard let first = images.first else { return nil }
        return (data: first.data, mimeType: first.mimeType)
    }

    static func shortenPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count > 3 {
            return ".../" + components.suffix(2).joined(separator: "/")
        }
        return path
    }

    // MARK: - Usage Stats Parsing

    static func parseUsageStats(transcriptPath: String) -> TranscriptUsageStats {
        let start = CFAbsoluteTimeGetCurrent()

        guard FileManager.default.fileExists(atPath: transcriptPath) else {
            return TranscriptUsageStats()
        }

        guard let content = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return TranscriptUsageStats()
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print("📈 parseUsageStats: \(String(format: "%.1f", elapsed))ms | \(lines.count) lines | \(transcriptPath.suffix(45))")
        }
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
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if elapsed > 5 { // Only log if > 5ms
                print("🔧 parseLastTool: \(String(format: "%.1f", elapsed))ms")
            }
        }

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
        // Handle simple string content (e.g., text-only continuation messages)
        if let content = message["content"] as? String {
            return content
        }

        // Handle array of content blocks (e.g., mixed tool_use and text)
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

    /// Extract thinking blocks from assistant message
    private static func extractThinkingContent(from message: [String: Any]) -> String? {
        guard let content = message["content"] as? [[String: Any]] else {
            return nil
        }

        let thinkingBlocks = content.compactMap { item -> String? in
            if item["type"] as? String == "thinking" {
                return item["thinking"] as? String
            }
            return nil
        }

        return thinkingBlocks.isEmpty ? nil : thinkingBlocks.joined(separator: "\n\n")
    }

    // Cached formatter - creating these is expensive
    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parseTimestamp(_ timestamp: String?) -> Date {
        guard let ts = timestamp else { return Date() }
        return timestampFormatter.date(from: ts) ?? Date()
    }

    static func createToolSummary(toolName: String, input: [String: Any]?) -> String {
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

    // MARK: - Unified Single-Pass Parser

    /// Parse everything in ONE pass - messages, stats, prompt, last tool
    /// Uses cache to avoid redundant parses of unchanged files
    static func parseAll(transcriptPath: String) -> TranscriptParseResult {
        // Quick cache check (no lock)
        if let cached = ParseCache.shared.getCached(path: transcriptPath) {
            return cached
        }

        // Acquire parse lock (blocks if another parse in progress)
        let pathLock = ParseCache.shared.acquireParseLock(path: transcriptPath)
        defer { pathLock.unlock() }

        // Check cache again (another thread may have finished while we waited)
        if let cached = ParseCache.shared.getCached(path: transcriptPath) {
            return cached
        }

        let start = CFAbsoluteTimeGetCurrent()

        guard FileManager.default.fileExists(atPath: transcriptPath) else {
            return TranscriptParseResult(messages: [], stats: TranscriptUsageStats(), lastUserPrompt: nil, lastTool: nil)
        }

        guard let content = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return TranscriptParseResult(messages: [], stats: TranscriptUsageStats(), lastUserPrompt: nil, lastTool: nil)
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        var messages: [TranscriptMessage] = []
        var toolResults: [String: (output: String, timestamp: Date)] = [:]
        var toolUseTimestamps: [String: Date] = [:] // Track when each tool_use started
        var stats = TranscriptUsageStats()
        var lastUserPrompt: String?
        var lastTool: String?
        var latestContextUsed = 0

        // First pass: collect tool results with timestamps, and tool_use timestamps
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let entryTimestamp = parseTimestamp(json["timestamp"] as? String)

            // Collect tool_use timestamps from assistant messages
            if json["type"] as? String == "assistant",
               let message = json["message"] as? [String: Any],
               let contentArray = message["content"] as? [[String: Any]] {
                for item in contentArray {
                    if item["type"] as? String == "tool_use",
                       let toolId = item["id"] as? String {
                        toolUseTimestamps[toolId] = entryTimestamp
                    }
                }
            }

            // Collect tool_result outputs and timestamps from user messages
            if json["type"] as? String == "user",
               let message = json["message"] as? [String: Any],
               let contentArray = message["content"] as? [[String: Any]] {
                for item in contentArray {
                    if item["type"] as? String == "tool_result",
                       let toolUseId = item["tool_use_id"] as? String {
                        let resultContent = extractToolResultContent(from: item)
                        toolResults[toolUseId] = (output: resultContent, timestamp: entryTimestamp)
                    }
                }
            }
        }

        // Second pass: build messages AND collect stats/prompt/lastTool
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Collect model for stats
            if let model = json["model"] as? String, stats.model == nil {
                stats.model = model
            }

            guard let type = json["type"] as? String,
                  let uuid = json["uuid"] as? String else {
                continue
            }

            let timestamp = parseTimestamp(json["timestamp"] as? String)

            switch type {
            case "user":
                if let message = json["message"] as? [String: Any] {
                    let userContent = extractUserContent(from: message) ?? ""
                    let images = extractImagesFromMessage(message)

                    // Track last user prompt
                    if !userContent.isEmpty {
                        lastUserPrompt = userContent
                    }

                    if !userContent.isEmpty || !images.isEmpty {
                        messages.append(TranscriptMessage(
                            id: uuid,
                            type: .user,
                            content: userContent,
                            timestamp: timestamp,
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            toolDuration: nil,
                            inputTokens: nil,
                            outputTokens: nil,
                            images: images
                        ))
                    }
                }

            case "assistant":
                if let message = json["message"] as? [String: Any] {
                    // Extract usage data for stats
                    if let usage = message["usage"] as? [String: Any] {
                        let inputT = (usage["input_tokens"] as? Int) ?? 0
                        let outputT = (usage["output_tokens"] as? Int) ?? 0
                        let cacheReadT = (usage["cache_read_input_tokens"] as? Int) ?? 0
                        let cacheCreateT = (usage["cache_creation_input_tokens"] as? Int) ?? 0

                        stats.inputTokens += inputT
                        stats.outputTokens += outputT
                        stats.cacheReadTokens += cacheReadT
                        stats.cacheCreationTokens += cacheCreateT

                        let contextForThisCall = inputT + cacheReadT + cacheCreateT
                        if contextForThisCall > 0 {
                            latestContextUsed = contextForThisCall
                        }
                    }

                    let usage = message["usage"] as? [String: Any]
                    let inputTokens = usage?["input_tokens"] as? Int
                    let outputTokens = usage?["output_tokens"] as? Int

                    // Extract thinking content
                    let thinkingContent = extractThinkingContent(from: message)

                    // Extract text content
                    if let textContent = extractAssistantContent(from: message), !textContent.isEmpty {
                        var msg = TranscriptMessage(
                            id: uuid + "-text",
                            type: .assistant,
                            content: textContent,
                            timestamp: timestamp,
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            toolDuration: nil,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens
                        )
                        msg.thinking = thinkingContent
                        messages.append(msg)
                    } else if let thinking = thinkingContent, !thinking.isEmpty {
                        // Create a thinking-only message if no text content
                        messages.append(TranscriptMessage(
                            id: uuid + "-thinking",
                            type: .thinking,
                            content: thinking,
                            timestamp: timestamp,
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            toolDuration: nil,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens
                        ))
                    }

                    // Extract tool calls
                    if let contentArray = message["content"] as? [[String: Any]] {
                        for (index, item) in contentArray.enumerated() {
                            if item["type"] as? String == "tool_use",
                               let toolName = item["name"] as? String,
                               let toolId = item["id"] as? String {
                                let input = item["input"] as? [String: Any]
                                let summary = createToolSummary(toolName: toolName, input: input)
                                let result = toolResults[toolId]
                                let hasResult = result != nil

                                // Calculate duration if we have both timestamps
                                let duration: TimeInterval? = {
                                    guard let toolUseTime = toolUseTimestamps[toolId],
                                          let resultTime = result?.timestamp else { return nil }
                                    let diff = resultTime.timeIntervalSince(toolUseTime)
                                    return diff > 0 ? diff : nil
                                }()

                                // Track last tool
                                lastTool = toolName

                                var msg = TranscriptMessage(
                                    id: "\(uuid)-tool-\(index)",
                                    type: .tool,
                                    content: summary,
                                    timestamp: timestamp,
                                    toolName: toolName,
                                    toolInput: input,
                                    toolOutput: result?.output,
                                    toolDuration: duration,
                                    inputTokens: nil,
                                    outputTokens: nil
                                )
                                msg.isInProgress = !hasResult
                                messages.append(msg)
                            }
                        }
                    }
                }

            default:
                break
            }
        }

        stats.contextUsed = latestContextUsed

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if elapsed > 500 {  // Only log slow parses
            print("⚡ parseAll: \(String(format: "%.1f", elapsed))ms | \(lines.count) lines → \(messages.count) msgs")
        }

        let result = TranscriptParseResult(messages: messages, stats: stats, lastUserPrompt: lastUserPrompt, lastTool: lastTool)
        ParseCache.shared.set(path: transcriptPath, result: result)
        return result
    }

    // MARK: - Subagent Transcript Parsing

    /// Find subagent transcript that matches a given Task
    /// Uses robust matching: full prompt match + timestamp proximity + session validation
    /// Returns the path to the subagent's JSONL file if found
    static func findSubagentTranscript(
        sessionPath: String,
        taskPrompt: String,
        taskTimestamp: Date? = nil
    ) -> String? {
        // Session path: ~/.claude/projects/<project>/<session-id>.jsonl
        // Subagent path: ~/.claude/projects/<project>/<session-id>/subagents/agent-<id>.jsonl

        let sessionId = (sessionPath as NSString).deletingPathExtension
        let subagentsDir = sessionId + "/subagents"

        // Extract parent session ID from path for validation
        let parentSessionId = (sessionPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".jsonl", with: "")

        let fm = FileManager.default
        guard fm.fileExists(atPath: subagentsDir),
              let files = try? fm.contentsOfDirectory(atPath: subagentsDir) else {
            return nil
        }

        // Candidate matches: (path, prompt match score, timestamp delta)
        var candidates: [(path: String, exactMatch: Bool, timeDelta: TimeInterval)] = []

        for file in files where file.hasPrefix("agent-") && file.hasSuffix(".jsonl") {
            // Skip prompt_suggestion agents (these are for UI suggestions, not real subagents)
            if file.contains("prompt_suggestion") { continue }

            let subagentPath = (subagentsDir as NSString).appendingPathComponent(file)

            guard let handle = FileHandle(forReadingAtPath: subagentPath),
                  let firstLine = readFirstLine(handle: handle),
                  let data = firstLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Validate session ID matches parent
            guard let subagentSessionId = json["sessionId"] as? String,
                  subagentSessionId == parentSessionId else {
                continue
            }

            // Extract prompt from subagent's first message
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                continue
            }

            // Check prompt match (exact or prefix for very long prompts)
            let exactMatch = content == taskPrompt
            let prefixMatch = content.hasPrefix(String(taskPrompt.prefix(500))) ||
                              taskPrompt.hasPrefix(String(content.prefix(500)))

            guard exactMatch || prefixMatch else { continue }

            // Calculate timestamp delta if available
            var timeDelta: TimeInterval = .infinity
            if let taskTs = taskTimestamp,
               let subagentTs = json["timestamp"] as? String {
                let subagentDate = parseTimestamp(subagentTs)
                timeDelta = abs(subagentDate.timeIntervalSince(taskTs))
            }

            candidates.append((path: subagentPath, exactMatch: exactMatch, timeDelta: timeDelta))
        }

        // Return best match: prefer exact match, then closest timestamp
        if let best = candidates.sorted(by: { lhs, rhs in
            if lhs.exactMatch != rhs.exactMatch {
                return lhs.exactMatch  // Exact match wins
            }
            return lhs.timeDelta < rhs.timeDelta  // Closer timestamp wins
        }).first {
            // Sanity check: if timestamp delta is > 5 seconds, probably wrong match
            if !best.exactMatch && best.timeDelta > 5.0 {
                return nil
            }
            return best.path
        }

        return nil
    }

    /// Read first line from file handle efficiently
    private static func readFirstLine(handle: FileHandle) -> String? {
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 16384)  // Read enough for first JSONL entry (prompts can be long)
        guard let str = String(data: data, encoding: .utf8) else { return nil }

        if let newlineIndex = str.firstIndex(of: "\n") {
            return String(str[..<newlineIndex])
        }
        return str
    }

    /// Parse tool calls from a subagent transcript (lightweight - just tools)
    static func parseSubagentTools(subagentPath: String) -> [TranscriptMessage] {
        guard FileManager.default.fileExists(atPath: subagentPath),
              let content = try? String(contentsOfFile: subagentPath, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        var messages: [TranscriptMessage] = []
        var toolResults: [String: String] = [:]

        // First pass: collect tool results
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if json["type"] as? String == "user",
               let message = json["message"] as? [String: Any],
               let contentArray = message["content"] as? [[String: Any]] {
                for item in contentArray {
                    if item["type"] as? String == "tool_result",
                       let toolUseId = item["tool_use_id"] as? String {
                        toolResults[toolUseId] = extractToolResultContent(from: item)
                    }
                }
            }
        }

        // Second pass: build tool messages
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard json["type"] as? String == "assistant",
                  let uuid = json["uuid"] as? String,
                  let message = json["message"] as? [String: Any],
                  let contentArray = message["content"] as? [[String: Any]] else {
                continue
            }

            let timestamp = parseTimestamp(json["timestamp"] as? String)

            for (index, item) in contentArray.enumerated() {
                if item["type"] as? String == "tool_use",
                   let toolName = item["name"] as? String,
                   let toolId = item["id"] as? String {
                    let input = item["input"] as? [String: Any]
                    let summary = createToolSummary(toolName: toolName, input: input)
                    let result = toolResults[toolId]

                    var msg = TranscriptMessage(
                        id: "\(uuid)-tool-\(index)",
                        type: .tool,
                        content: summary,
                        timestamp: timestamp,
                        toolName: toolName,
                        toolInput: input,
                        toolOutput: result,
                        toolDuration: nil,
                        inputTokens: nil,
                        outputTokens: nil
                    )
                    msg.isInProgress = result == nil
                    messages.append(msg)
                }
            }
        }

        return messages
    }

    /// Get all subagent transcripts for a session
    static func listSubagentTranscripts(sessionPath: String) -> [(agentId: String, path: String)] {
        let sessionId = (sessionPath as NSString).deletingPathExtension
        let subagentsDir = sessionId + "/subagents"

        let fm = FileManager.default
        guard fm.fileExists(atPath: subagentsDir),
              let files = try? fm.contentsOfDirectory(atPath: subagentsDir) else {
            return []
        }

        return files.compactMap { file -> (String, String)? in
            guard file.hasPrefix("agent-") && file.hasSuffix(".jsonl") else { return nil }

            // Extract agent ID: agent-abc123.jsonl -> abc123
            let start = file.index(file.startIndex, offsetBy: 6)
            let end = file.index(file.endIndex, offsetBy: -6)
            guard start < end else { return nil }

            let agentId = String(file[start..<end])
            let path = (subagentsDir as NSString).appendingPathComponent(file)
            return (agentId, path)
        }
    }
}
