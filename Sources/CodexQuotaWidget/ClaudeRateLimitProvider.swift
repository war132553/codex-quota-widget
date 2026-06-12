import Foundation
import Security

final class ClaudeRateLimitProvider {
    private struct FilePayload: Decodable {
        struct RateLimits: Decodable {
            let fiveHour: Window?
            let sevenDay: Window?

            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
            }
        }

        struct Window: Decodable {
            let usedPercentage: Double?
            let resetsAt: Int?

            enum CodingKeys: String, CodingKey {
                case usedPercentage = "used_percentage"
                case resetsAt = "resets_at"
            }
        }

        let updatedAt: Int?
        let source: String?
        let version: String?
        let model: String?
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at"
            case source
            case version
            case model
            case rateLimits = "rate_limits"
        }
    }

    private let fileURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/codex-quota-widget/rate-limits.json")) {
        self.fileURL = fileURL
    }

    func latestSnapshot() -> ClaudeRateLimitSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        guard let payload = try? decoder.decode(FilePayload.self, from: data) else {
            return nil
        }

        let updatedAt = payload.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        let limits = payload.rateLimits

        return ClaudeRateLimitSnapshot(
            sourceFileName: payload.source ?? fileURL.lastPathComponent,
            updatedAt: updatedAt,
            version: payload.version,
            model: payload.model,
            fiveHour: window(label: "5h", payload: limits?.fiveHour),
            sevenDay: window(label: "7d", payload: limits?.sevenDay)
        )
    }

    func refreshFromOAuthUsage(timeout: TimeInterval = 15) -> Result<ClaudeRateLimitSnapshot, ClaudeRateLimitError> {
        let userAgent = "claude-code/\(claudeCodeVersion())"

        switch readClaudeOAuthAccessToken() {
        case .failure(let error):
            return .failure(error)
        case .success(let accessToken):
            var request = URLRequest(url: usageURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = timeout

            let semaphore = DispatchSemaphore(value: 0)
            var responseData: Data?
            var httpStatus: Int?
            var requestError: Error?

            URLSession.shared.dataTask(with: request) { data, response, error in
                responseData = data
                httpStatus = (response as? HTTPURLResponse)?.statusCode
                requestError = error
                semaphore.signal()
            }.resume()

            guard semaphore.wait(timeout: .now() + timeout + 2) == .success else {
                return .failure(.network("request timed out"))
            }

            if let requestError {
                return .failure(.network(requestError.localizedDescription))
            }

            guard let httpStatus else {
                return .failure(.network("missing HTTP response"))
            }

            guard httpStatus == 200 else {
                switch httpStatus {
                case 401, 403:
                    return .failure(.unauthorized(httpStatus))
                case 429:
                    return .failure(.rateLimited)
                default:
                    return .failure(.http(httpStatus))
                }
            }

            guard let responseData else {
                return .failure(.invalidResponse("empty response"))
            }

            do {
                let usage = try decoder.decode(OAuthUsageResponse.self, from: responseData)
                let snapshot = try snapshot(from: usage, source: "claude-oauth-usage", version: claudeCodeVersion())
                try writeSnapshot(snapshot)
                return .success(snapshot)
            } catch {
                return .failure(.invalidResponse(error.localizedDescription))
            }
        }
    }

    private func window(label: String, payload: FilePayload.Window?) -> ClaudeRateLimitWindow {
        ClaudeRateLimitWindow(
            label: label,
            usedPercent: payload?.usedPercentage.map(clampPercent(_:)),
            resetsAt: payload?.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private func readClaudeOAuthAccessToken() -> Result<String, ClaudeRateLimitError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return .failure(.missingCredentials)
        }

        do {
            let credentials = try decoder.decode(KeychainCredentials.self, from: data)
            guard !credentials.claudeAiOauth.accessToken.isEmpty else {
                return .failure(.missingCredentials)
            }
            return .success(credentials.claudeAiOauth.accessToken)
        } catch {
            return .failure(.invalidCredentials)
        }
    }

    private func snapshot(from response: OAuthUsageResponse, source: String, version: String?) throws -> ClaudeRateLimitSnapshot {
        guard let fiveHour = response.fiveHour, let sevenDay = response.sevenDay else {
            throw ClaudeRateLimitError.invalidResponse("missing five_hour or seven_day")
        }

        return ClaudeRateLimitSnapshot(
            sourceFileName: source,
            updatedAt: Date(),
            version: version,
            model: nil,
            fiveHour: try oauthWindow(label: "5h", payload: fiveHour),
            sevenDay: try oauthWindow(label: "7d", payload: sevenDay)
        )
    }

    private func oauthWindow(label: String, payload: OAuthUsageResponse.Window) throws -> ClaudeRateLimitWindow {
        guard let resetsAt = parseISO8601(payload.resetsAt) else {
            throw ClaudeRateLimitError.invalidResponse("invalid reset time for \(label)")
        }

        return ClaudeRateLimitWindow(
            label: label,
            usedPercent: clampPercent(payload.utilization),
            resetsAt: resetsAt
        )
    }

    private func writeSnapshot(_ snapshot: ClaudeRateLimitSnapshot) throws {
        let payload = WritablePayload(
            updatedAt: Int(snapshot.updatedAt.timeIntervalSince1970),
            source: snapshot.sourceFileName,
            version: snapshot.version,
            model: snapshot.model,
            rateLimits: WritablePayload.RateLimits(
                fiveHour: writableWindow(snapshot.fiveHour),
                sevenDay: writableWindow(snapshot.sevenDay)
            )
        )

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(payload)
        let tempURL = fileURL.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
    }

    private func writableWindow(_ window: ClaudeRateLimitWindow) -> WritablePayload.Window {
        WritablePayload.Window(
            usedPercentage: window.usedPercent,
            resetsAt: window.resetsAt.map { Int($0.timeIntervalSince1970) }
        )
    }

    private func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private func claudeCodeVersion() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let localClaude = home.appendingPathComponent(".local/bin/claude").resolvingSymlinksInPath()
        let localVersion = localClaude.lastPathComponent
        if localVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
            return localVersion
        }

        let versionsDirectory = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = (try? FileManager.default.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return versions
            .map(\.lastPathComponent)
            .filter { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
            .sorted()
            .last ?? "2.1.175"
    }
}

enum ClaudeRateLimitError: Error, CustomStringConvertible {
    case missingCredentials
    case invalidCredentials
    case unauthorized(Int)
    case rateLimited
    case http(Int)
    case network(String)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .missingCredentials:
            return "missing Claude Code credentials"
        case .invalidCredentials:
            return "invalid Claude Code credentials"
        case .unauthorized(let status):
            return "Claude auth failed (\(status))"
        case .rateLimited:
            return "Claude usage endpoint rate limited"
        case .http(let status):
            return "Claude usage endpoint HTTP \(status)"
        case .network(let message):
            return "Claude usage network error: \(message)"
        case .invalidResponse(let message):
            return "Claude usage response error: \(message)"
        }
    }
}

private struct KeychainCredentials: Decodable {
    struct OAuth: Decodable {
        let accessToken: String
    }

    let claudeAiOauth: OAuth
}

private struct OAuthUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double
        let resetsAt: String

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct WritablePayload: Encodable {
    struct RateLimits: Encodable {
        let fiveHour: Window
        let sevenDay: Window

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    struct Window: Encodable {
        let usedPercentage: Double?
        let resetsAt: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    let updatedAt: Int
    let source: String
    let version: String?
    let model: String?
    let rateLimits: RateLimits

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case source
        case version
        case model
        case rateLimits = "rate_limits"
    }
}
