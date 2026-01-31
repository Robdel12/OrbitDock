//
//  SubscriptionUsageService.swift
//  OrbitDock
//
//  Fetches Claude subscription usage from Anthropic's OAuth API.
//  Caches credentials in app's keychain to avoid repeated password prompts.
//

import Foundation
import Security

// MARK: - Models

struct SubscriptionUsage: Sendable {
    struct Window: Sendable {
        let utilization: Double  // 0-100
        let resetsAt: Date?
        let windowDuration: TimeInterval  // 5 hours or 7 days in seconds

        var remaining: Double { max(0, 100 - utilization) }

        var resetsInDescription: String? {
            guard let resetsAt else { return nil }
            let interval = resetsAt.timeIntervalSinceNow
            if interval <= 0 { return "now" }

            let hours = Int(interval / 3600)
            let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

            if hours > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(minutes)m"
        }

        /// Time remaining until reset
        var timeRemaining: TimeInterval {
            guard let resetsAt else { return 0 }
            return max(0, resetsAt.timeIntervalSinceNow)
        }

        /// Time elapsed since window started
        var timeElapsed: TimeInterval {
            return windowDuration - timeRemaining
        }

        /// Current burn rate (% per hour)
        var burnRatePerHour: Double {
            guard timeElapsed > 0 else { return 0 }
            return utilization / (timeElapsed / 3600)
        }

        /// Projected usage at reset if current pace continues
        var projectedAtReset: Double {
            guard timeElapsed > 60 else { return utilization }  // Need at least 1 min of data
            let rate = utilization / timeElapsed
            return min(100, rate * windowDuration)
        }

        /// Whether on track to exceed the limit
        var willExceed: Bool {
            projectedAtReset > 95  // Give 5% buffer
        }

        /// Pace status
        var paceStatus: PaceStatus {
            // If very early in window, not enough data
            if timeElapsed < 300 { return .unknown }  // 5 min minimum

            let sustainableRate = 100.0 / (windowDuration / 3600)  // % per hour to use exactly 100%
            let ratio = burnRatePerHour / sustainableRate

            if ratio < 0.5 { return .relaxed }
            if ratio < 0.9 { return .onTrack }
            if ratio < 1.1 { return .borderline }
            if ratio < 1.5 { return .exceeding }
            return .critical
        }

        enum PaceStatus: String {
            case unknown = "—"
            case relaxed = "Relaxed"
            case onTrack = "On Track"
            case borderline = "Borderline"
            case exceeding = "Exceeding"
            case critical = "Critical"

            var color: String {
                switch self {
                case .unknown: return "secondary"
                case .relaxed: return "accent"
                case .onTrack: return "statusSuccess"
                case .borderline: return "statusWaiting"
                case .exceeding, .critical: return "statusError"
                }
            }

            var icon: String {
                switch self {
                case .unknown: return "minus"
                case .relaxed: return "tortoise.fill"
                case .onTrack: return "checkmark.circle.fill"
                case .borderline: return "exclamationmark.circle.fill"
                case .exceeding: return "flame.fill"
                case .critical: return "bolt.fill"
                }
            }
        }
    }

    let fiveHour: Window
    let sevenDay: Window?
    let sevenDaySonnet: Window?
    let sevenDayOpus: Window?
    let fetchedAt: Date
    let rateLimitTier: String?

    var planName: String? {
        guard let tier = rateLimitTier?.lowercased() else { return nil }
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        if tier.contains("max") { return "Max" }
        if tier.contains("pro") { return "Pro" }
        if tier.contains("team") { return "Team" }
        if tier.contains("enterprise") { return "Enterprise" }
        return nil
    }
}

enum SubscriptionUsageError: LocalizedError {
    case noCredentials
    case tokenExpired
    case unauthorized
    case networkError(Error)
    case invalidResponse
    case missingScope

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "No Claude credentials found"
        case .tokenExpired: return "Claude token expired - restart Claude CLI to refresh"
        case .unauthorized: return "Unauthorized - check Claude CLI login"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .invalidResponse: return "Invalid API response"
        case .missingScope: return "Token missing user:profile scope"
        }
    }
}

// MARK: - Service

@Observable
final class SubscriptionUsageService {
    static let shared = SubscriptionUsageService()

    private(set) var usage: SubscriptionUsage?
    private(set) var error: SubscriptionUsageError?
    private(set) var isLoading = false
    private(set) var lastFetchAttempt: Date?

    // Cache token in our app's keychain
    private let appKeychainService = "com.orbitdock.claude-token"
    private let appKeychainAccount = "oauth"

    // Claude's keychain
    private let claudeKeychainService = "Claude Code-credentials"

    // Refresh interval
    private let refreshInterval: TimeInterval = 60  // 1 minute
    private let staleThreshold: TimeInterval = 300  // 5 minutes before showing stale

    private var refreshTask: Task<Void, Never>?

    private init() {
        // Start background refresh
        startAutoRefresh()
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Public API

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        lastFetchAttempt = Date()

        do {
            let token = try getAccessToken()
            let response = try await fetchUsage(token: token)
            let tier = try? getCachedRateLimitTier()

            usage = parseResponse(response, rateLimitTier: tier)
            error = nil
        } catch let e as SubscriptionUsageError {
            error = e
        } catch {
            self.error = .networkError(error)
        }

        isLoading = false
    }

    var isStale: Bool {
        guard let fetched = usage?.fetchedAt else { return true }
        return Date().timeIntervalSince(fetched) > staleThreshold
    }

    // MARK: - Auto Refresh

    private func startAutoRefresh() {
        refreshTask = Task { [weak self] in
            // Initial fetch
            await self?.refresh()

            // Periodic refresh
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.refreshInterval ?? 60))
                await self?.refresh()
            }
        }
    }

    // MARK: - Token Management

    private func getAccessToken() throws -> String {
        // First, try our cached token
        if let cached = try? loadFromAppKeychain() {
            return cached.token
        }

        // Fall back to Claude's keychain (may prompt once)
        let credentials = try loadFromClaudeKeychain()

        // Cache it in our keychain for future use
        try? saveToAppKeychain(credentials)

        return credentials.token
    }

    private struct CachedCredentials {
        let token: String
        let expiresAt: Date?
        let rateLimitTier: String?
        let scopes: [String]
    }

    private func loadFromAppKeychain() throws -> CachedCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appKeychainService,
            kSecAttrAccount as String: appKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw SubscriptionUsageError.noCredentials
        }

        // Check expiration
        if let expiresAtMs = json["expiresAt"] as? Double {
            let expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000)
            if Date() >= expiresAt {
                // Token expired, clear cache and throw
                clearAppKeychain()
                throw SubscriptionUsageError.tokenExpired
            }
        }

        // Check scope
        let scopes = json["scopes"] as? [String] ?? []
        if !scopes.contains("user:profile") {
            throw SubscriptionUsageError.missingScope
        }

        let expiresAt = (json["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        let tier = json["rateLimitTier"] as? String

        return CachedCredentials(token: token, expiresAt: expiresAt, rateLimitTier: tier, scopes: scopes)
    }

    private func saveToAppKeychain(_ credentials: CachedCredentials) throws {
        let json: [String: Any] = [
            "token": credentials.token,
            "expiresAt": credentials.expiresAt.map { $0.timeIntervalSince1970 * 1000 } as Any,
            "rateLimitTier": credentials.rateLimitTier as Any,
            "scopes": credentials.scopes
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }

        // Delete existing
        clearAppKeychain()

        // Add new with unrestricted access for our app
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appKeychainService,
            kSecAttrAccount as String: appKeychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func clearAppKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appKeychainService,
            kSecAttrAccount as String: appKeychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func loadFromClaudeKeychain() throws -> CachedCredentials {
        // Use security CLI to bypass partition_id restrictions
        // (SecItemCopyMatching gets blocked by Anthropic's teamid partition)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", claudeKeychainService, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SubscriptionUsageError.noCredentials
        }

        guard process.terminationStatus == 0 else {
            throw SubscriptionUsageError.noCredentials
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw SubscriptionUsageError.noCredentials
        }

        // Check expiration
        let expiresAt: Date?
        if let expiresAtMs = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000)
            if Date() >= expiresAt! {
                throw SubscriptionUsageError.tokenExpired
            }
        } else {
            expiresAt = nil
        }

        // Check scope
        let scopes = oauth["scopes"] as? [String] ?? []
        if !scopes.contains("user:profile") {
            throw SubscriptionUsageError.missingScope
        }

        let tier = oauth["rateLimitTier"] as? String

        return CachedCredentials(token: token, expiresAt: expiresAt, rateLimitTier: tier, scopes: scopes)
    }

    private func getCachedRateLimitTier() throws -> String? {
        if let cached = try? loadFromAppKeychain() {
            return cached.rateLimitTier
        }
        return nil
    }

    // MARK: - API

    private func fetchUsage(token: String) async throws -> [String: Any] {
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("OrbitDock/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SubscriptionUsageError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SubscriptionUsageError.invalidResponse
            }
            return json
        case 401:
            // Clear cached token and retry from Claude keychain next time
            clearAppKeychain()
            throw SubscriptionUsageError.unauthorized
        default:
            throw SubscriptionUsageError.invalidResponse
        }
    }

    private func parseResponse(_ json: [String: Any], rateLimitTier: String?) -> SubscriptionUsage {
        let fiveHourDuration: TimeInterval = 5 * 3600  // 5 hours
        let sevenDayDuration: TimeInterval = 7 * 24 * 3600  // 7 days

        func parseWindow(_ dict: [String: Any]?, duration: TimeInterval) -> SubscriptionUsage.Window? {
            guard let dict,
                  let utilization = dict["utilization"] as? Double else { return nil }

            let resetsAt: Date?
            if let resetsAtStr = dict["resets_at"] as? String {
                resetsAt = ISO8601DateFormatter().date(from: resetsAtStr)
            } else {
                resetsAt = nil
            }

            return SubscriptionUsage.Window(utilization: utilization, resetsAt: resetsAt, windowDuration: duration)
        }

        let fiveHour = parseWindow(json["five_hour"] as? [String: Any], duration: fiveHourDuration)
            ?? SubscriptionUsage.Window(utilization: 0, resetsAt: nil, windowDuration: fiveHourDuration)

        return SubscriptionUsage(
            fiveHour: fiveHour,
            sevenDay: parseWindow(json["seven_day"] as? [String: Any], duration: sevenDayDuration),
            sevenDaySonnet: parseWindow(json["seven_day_sonnet"] as? [String: Any], duration: sevenDayDuration),
            sevenDayOpus: parseWindow(json["seven_day_opus"] as? [String: Any], duration: sevenDayDuration),
            fetchedAt: Date(),
            rateLimitTier: rateLimitTier
        )
    }
}
