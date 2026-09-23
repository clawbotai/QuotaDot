import Foundation

struct AntigravityBuildConfig: Sendable {
    static var clientID: String { values.clientID }
    static var clientSecret: String { values.clientSecret }
    static var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    private struct Values: Sendable {
        let clientID: String
        let clientSecret: String
    }

    private static let values: Values = load()

    private static func load() -> Values {
        let (idFromBundle, secretFromBundle) = loadFromBundle()
        let (idFromEnv, secretFromEnv) = loadFromEnvironment()
        let (idFromConfig, secretFromConfig) = loadFromXCConfigFile()

        let clientID = idFromBundle ?? idFromEnv ?? idFromConfig ?? defaultFallbackID
        let clientSecret = secretFromBundle ?? secretFromEnv ?? secretFromConfig ?? defaultFallbackSecret

        return Values(clientID: clientID, clientSecret: clientSecret)
    }

    private static var defaultFallbackID: String {
        #if DEBUG
        return "mock-antigravity-client-id"
        #else
        return ""
        #endif
    }

    private static var defaultFallbackSecret: String {
        #if DEBUG
        return "mock-antigravity-client-secret"
        #else
        return ""
        #endif
    }

    private static func loadFromBundle() -> (clientID: String?, clientSecret: String?) {
        let clientID = sanitized(Bundle.main.object(forInfoDictionaryKey: "AntigravityClientID") as? String)
        let clientSecret = sanitized(Bundle.main.object(forInfoDictionaryKey: "AntigravityClientSecret") as? String)
        return (clientID, clientSecret)
    }

    private static func loadFromEnvironment() -> (clientID: String?, clientSecret: String?) {
        let env = ProcessInfo.processInfo.environment
        let clientID = sanitized(env["ANTIGRAVITY_CLIENT_ID"])
        let clientSecret = sanitized(env["ANTIGRAVITY_CLIENT_SECRET"])
        return (clientID, clientSecret)
    }

    private static func loadFromXCConfigFile() -> (clientID: String?, clientSecret: String?) {
        let configNames = [
            "Antigravity.xcconfig",
            "AntigravityConfig.xcconfig",
            "Config/Antigravity.xcconfig",
            "Config/AntigravityConfig.xcconfig"
        ]

        let fileManager = FileManager.default
        var searchRoots: [URL] = []

        // Search from current directory
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        searchRoots.append(cwd)

        // Search upwards from source file location if available
        var sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            searchRoots.append(sourceDir)
            sourceDir = sourceDir.deletingLastPathComponent()
        }

        for root in searchRoots {
            for name in configNames {
                let candidate = root.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: candidate.path),
                      let content = try? String(contentsOf: candidate, encoding: .utf8) else {
                    continue
                }
                let parsed = parseXCConfig(content)
                let clientID = sanitized(parsed["ANTIGRAVITY_CLIENT_ID"])
                let clientSecret = sanitized(parsed["ANTIGRAVITY_CLIENT_SECRET"])
                if clientID != nil || clientSecret != nil {
                    return (clientID, clientSecret)
                }
            }
        }

        return (nil, nil)
    }

    private static func parseXCConfig(_ content: String) -> [String: String] {
        var map: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            map[parts[0]] = parts[1]
        }
        return map
    }

    private static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        } else if trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("$(") { return nil }
        return trimmed
    }
}
