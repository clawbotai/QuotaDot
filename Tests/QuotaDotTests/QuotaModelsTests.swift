import Foundation
import CoreLocation
import Testing
@testable import QuotaDot

struct QuotaModelsTests {
    @Test func decodesUsageAndComputesRemaining() throws {
        let json = #"[{"providerId":"codex","displayName":"Codex","plan":"Pro","lines":[{"type":"progress","label":"Session","used":17,"limit":100,"resetsAt":"2026-07-12T18:17:13.000Z","periodDurationMs":18000000}],"fetchedAt":"2026-07-12T15:44:43.909678Z"}]"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let result = try decoder.decode([ProviderUsage].self, from: json)
        #expect(result[0].session?.remainingPercent == 0.83)
        #expect(result[0].session?.resetsAt != nil)
    }

    @Test func healthThresholds() {
        #expect(QuotaHealth(remaining: 0.8) == .healthy)
        #expect(QuotaHealth(remaining: 0.51) == .healthy)
        #expect(QuotaHealth(remaining: 0.50) == .warning)
        #expect(QuotaHealth(remaining: 0.11) == .warning)
        #expect(QuotaHealth(remaining: 0.10) == .critical)
    }

    @Test func creditsRemainCreditsAndAreNotResetOpportunities() throws {
        let json = #"[{"providerId":"codex","displayName":"Codex","lines":[{"type":"progress","label":"Credits","used":1000,"limit":1000}]}]"#.data(using: .utf8)!
        let result = try JSONDecoder().decode([ProviderUsage].self, from: json)
        #expect(result[0].credits?.used == 1000)
    }

    @Test func hidesSuspendedCodexSessionAndKeepsSparkWeekly() throws {
        let json = #"[{"providerId":"codex","displayName":"Codex","lines":[{"type":"progress","label":"Session","used":12,"limit":100,"resetsAt":"2026-07-19T23:30:08.000Z","periodDurationMs":18000000},{"type":"progress","label":"Spark","used":20,"limit":100,"resetsAt":"2026-07-20T23:30:08.000Z","periodDurationMs":604800000}],"fetchedAt":"2026-07-12T23:30:09.000Z"}]"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let provider = try decoder.decode([ProviderUsage].self, from: json)[0]
        #expect(provider.session == nil)
        #expect(provider.weekly?.remainingPercent == 0.88)
        #expect(provider.effectiveResetAt(for: provider.weekly!) == provider.weekly?.resetsAt)
    }

    @Test func restoresCodexSessionWhenShortWindowIsValid() throws {
        let json = #"[{"providerId":"codex","displayName":"Codex","lines":[{"type":"progress","label":"Session","used":12,"limit":100,"resetsAt":"2026-07-13T04:30:08.000Z","periodDurationMs":18000000}],"fetchedAt":"2026-07-13T01:30:09.000Z"}]"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let provider = try decoder.decode([ProviderUsage].self, from: json)[0]
        #expect(provider.session?.remainingPercent == 0.88)
    }

    @Test func mapsLiveWeatherIntoDistinctAnimationMoods() {
        let now = Date.now
        let fog = WeatherSnapshot(locationName: "测试城市", temperature: 25, code: 45, isDay: true, liveCondition: nil, fetchedAt: now)
        let rain = WeatherSnapshot(locationName: "测试城市", temperature: 24, code: 61, isDay: true, liveCondition: nil, fetchedAt: now)
        let storm = WeatherSnapshot(locationName: "测试城市", temperature: 23, code: 95, isDay: false, liveCondition: nil, fetchedAt: now)
        let snow = WeatherSnapshot(locationName: "测试城市", temperature: 0, code: 71, isDay: true, liveCondition: nil, fetchedAt: now)

        #expect(fog.mood == .fog)
        #expect(rain.mood == .rain)
        #expect(storm.mood == .storm)
        #expect(snow.mood == .snow)
    }

    @Test func activityHighlightExpiresQuicklyAfterStreamingStops() {
        let now = Date.now
        #expect(ActivityDetectionPolicy.isActive(modifiedAt: now.addingTimeInterval(-3), now: now))
        #expect(!ActivityDetectionPolicy.isActive(modifiedAt: now.addingTimeInterval(-5), now: now))
        #expect(!ActivityDetectionPolicy.isActive(modifiedAt: now.addingTimeInterval(5), now: now))
    }

    @Test func refreshesClaudeCredentialBeforeItActuallyExpires() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let insideLeeway = Int64(now.addingTimeInterval(4 * 60).timeIntervalSince1970 * 1_000)
        let safelyValid = Int64(now.addingTimeInterval(6 * 60).timeIntervalSince1970 * 1_000)

        #expect(ClaudeCredentialPolicy.shouldRefresh(expiresAtMilliseconds: insideLeeway, now: now))
        #expect(!ClaudeCredentialPolicy.shouldRefresh(expiresAtMilliseconds: safelyValid, now: now))
        #expect(!ClaudeCredentialPolicy.shouldRefresh(expiresAtMilliseconds: nil, now: now))
    }

    @Test func rejectsStaleLocationsAndSelectsTheMostAccurateFreshFix() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 29.2, longitude: 120.2),
            altitude: 0,
            horizontalAccuracy: 20,
            verticalAccuracy: -1,
            timestamp: now.addingTimeInterval(-120)
        )
        let coarse = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 29.3, longitude: 120.3),
            altitude: 0,
            horizontalAccuracy: 900,
            verticalAccuracy: -1,
            timestamp: now.addingTimeInterval(-2)
        )
        let precise = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 29.4, longitude: 120.4),
            altitude: 0,
            horizontalAccuracy: 80,
            verticalAccuracy: -1,
            timestamp: now.addingTimeInterval(-3)
        )

        let selected = LocationSelectionPolicy.bestLocation(in: [stale, coarse, precise], now: now)
        #expect(selected?.coordinate.latitude == precise.coordinate.latitude)
        #expect(LocationSelectionPolicy.isPreciseEnough(precise))
        #expect(!LocationSelectionPolicy.isPreciseEnough(coarse))
    }

    @Test func prefersDistrictLevelWeatherLocationOverItsParentCity() {
        #expect(
            LocationNamePolicy.displayName(
                district: "示例新区",
                city: "示例市",
                province: "示例省",
                fallback: "当前位置"
            ) == "示例"
        )
    }
}
