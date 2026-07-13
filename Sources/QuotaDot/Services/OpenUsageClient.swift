import Foundation

struct OpenUsageClient: Sendable {
    var endpoint = URL(string: "http://127.0.0.1:6736/v1/usage")!

    func fetch() async throws -> [ProviderUsage] {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return try decoder.decode([ProviderUsage].self, from: data)
            .filter { ["codex", "claude"].contains($0.providerId.lowercased()) }
            .sorted { $0.providerId.lowercased() == "codex" && $1.providerId.lowercased() != "codex" }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = custom { decoder in
        let value = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let basic = ISO8601DateFormatter()
        if let date = basic.date(from: value) { return date }
        throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO-8601 date")
    }
}
