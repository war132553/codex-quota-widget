import AppKit
import Foundation

let snapshotService = QuotaSnapshotService()

if CommandLine.arguments.contains("--claude-oauth-once") {
    let provider = ClaudeRateLimitProvider()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    switch provider.refreshFromOAuthUsage() {
    case .success(let snapshot):
        if let data = try? encoder.encode(snapshot) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
            exit(EXIT_SUCCESS)
        }
        FileHandle.standardError.write("Failed to encode Claude usage snapshot\n".data(using: .utf8)!)
        exit(EXIT_FAILURE)
    case .failure(let error):
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--once") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    if let snapshot = snapshotService.latestSnapshot(), let data = try? encoder.encode(snapshot) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        exit(EXIT_SUCCESS)
    } else {
        FileHandle.standardError.write("No quota snapshot found in ~/.codex/sessions\n".data(using: .utf8)!)
        exit(EXIT_FAILURE)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
