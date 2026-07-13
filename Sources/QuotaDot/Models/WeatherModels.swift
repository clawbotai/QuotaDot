import Foundation

struct WeatherSnapshot: Sendable {
    let locationName: String
    let temperature: Int
    let code: Int
    let isDay: Bool
    let liveCondition: String?
    let fetchedAt: Date
    var localizedLocationNames: [String: String] = [:]

    func displayLocation(language: AppLanguage) -> String {
        localizedLocationNames[language.rawValue] ?? locationName
    }

    @MainActor func condition(language: LanguageSettings) -> String {
        if language.language == .simplifiedChinese, let liveCondition, !liveCondition.isEmpty { return liveCondition }
        let key = switch code {
        case 0: "weather.clear"
        case 1, 2: "weather.partlyCloudy"
        case 3: "weather.cloudy"
        case 45, 48: "weather.fog"
        case 51...67, 80...82: "weather.rain"
        case 71...77, 85, 86: "weather.snow"
        case 95...99: "weather.storm"
        default: "weather.changing"
        }
        return language.text(key)
    }

    var symbolName: String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    var mood: WeatherMood {
        switch code {
        case 0: .clear
        case 1, 2: .partlyCloudy
        case 45, 48: .fog
        case 51...67, 80...82: .rain
        case 71...77, 85, 86: .snow
        case 95...99: .storm
        default: .cloudy
        }
    }
}

enum WeatherMood: Sendable, Equatable { case clear, partlyCloudy, cloudy, fog, rain, storm, snow }

struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature: Double
        let weatherCode: Int
        let isDay: Int

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }
    let current: Current
}

struct AMapWeatherResponse: Decodable {
    struct Live: Decodable {
        let weather: String
        let temperature: String
        let reporttime: String
    }
    let status: String
    let lives: [Live]
}

struct AMapReverseGeocodeResponse: Decodable {
    struct Regeocode: Decodable {
        struct AddressComponent: Decodable {
            let province: String?
            let city: FlexibleString?
            let district: String?
            let adcode: String?
        }
        let addressComponent: AddressComponent
    }
    let status: String
    let regeocode: Regeocode?
}

enum FlexibleString: Decodable {
    case string(String)
    case array([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value); return }
        self = .array((try? container.decode([String].self)) ?? [])
    }

    var value: String? {
        switch self {
        case let .string(value): value.isEmpty ? nil : value
        case let .array(values): values.first(where: { !$0.isEmpty })
        }
    }
}

struct WttrWeatherResponse: Decodable {
    struct Description: Decodable { let value: String }
    struct Current: Decodable {
        let tempC: String
        let weatherCode: String
        let weatherDesc: [Description]
        enum CodingKeys: String, CodingKey {
            case tempC = "temp_C"
            case weatherCode
            case weatherDesc
        }
    }
    let currentCondition: [Current]
    enum CodingKeys: String, CodingKey { case currentCondition = "current_condition" }
}
