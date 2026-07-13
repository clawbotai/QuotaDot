import Foundation

struct WeatherClient: Sendable {
    func fetch(
        latitude: Double,
        longitude: Double,
        locationName: String,
        englishLocationName: String
    ) async throws -> WeatherSnapshot {
        if let key = ProcessInfo.processInfo.environment["AMAP_WEBSERVICE_KEY"], !key.isEmpty,
           let weather = try? await fetchAMap(
                key: key,
                latitude: latitude,
                longitude: longitude,
                fallbackLocationName: locationName,
                englishLocationName: englishLocationName
           ) {
            return weather
        }
        return try await fetchOpenMeteo(
            latitude: latitude,
            longitude: longitude,
            locationName: locationName,
            englishLocationName: englishLocationName
        )
    }

    private func fetchAMap(
        key: String,
        latitude: Double,
        longitude: Double,
        fallbackLocationName: String,
        englishLocationName: String
    ) async throws -> WeatherSnapshot {
        let location = try await reverseAMap(key: key, latitude: latitude, longitude: longitude)
        var components = URLComponents(string: "https://restapi.amap.com/v3/weather/weatherInfo")!
        components.queryItems = [
            URLQueryItem(name: "city", value: location.adcode),
            URLQueryItem(name: "extensions", value: "base"),
            URLQueryItem(name: "output", value: "JSON"),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "appname", value: "amap-lbs-skill")
        ]
        let data = try await request(components.url!)
        let payload = try JSONDecoder().decode(AMapWeatherResponse.self, from: data)
        guard payload.status == "1", let live = payload.lives.first, let temperature = Double(live.temperature) else {
            throw URLError(.cannotParseResponse)
        }
        return WeatherSnapshot(
            locationName: location.name ?? fallbackLocationName,
            temperature: Int(temperature.rounded()),
            code: weatherCode(for: live.weather),
            isDay: Calendar.current.component(.hour, from: .now) >= 6 && Calendar.current.component(.hour, from: .now) < 19,
            liveCondition: live.weather,
            fetchedAt: .now,
            localizedLocationNames: [
                AppLanguage.simplifiedChinese.rawValue: location.name ?? fallbackLocationName,
                AppLanguage.english.rawValue: englishLocationName
            ]
        )
    }

    private func fetchOpenMeteo(
        latitude: Double,
        longitude: Double,
        locationName: String,
        englishLocationName: String
    ) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.5f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.5f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        let data = try await request(components.url!)
        let payload = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        return WeatherSnapshot(
            locationName: locationName,
            temperature: Int(payload.current.temperature.rounded()),
            code: payload.current.weatherCode,
            isDay: payload.current.isDay == 1,
            liveCondition: nil,
            fetchedAt: .now,
            localizedLocationNames: [
                AppLanguage.simplifiedChinese.rawValue: locationName,
                AppLanguage.english.rawValue: englishLocationName
            ]
        )
    }

    private func reverseAMap(key: String, latitude: Double, longitude: Double) async throws -> (adcode: String, name: String?) {
        var components = URLComponents(string: "https://restapi.amap.com/v3/geocode/regeo")!
        components.queryItems = [
            URLQueryItem(name: "location", value: "\(longitude),\(latitude)"),
            URLQueryItem(name: "extensions", value: "base"),
            URLQueryItem(name: "output", value: "JSON"),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "appname", value: "amap-lbs-skill")
        ]
        let data = try await request(components.url!)
        let payload = try JSONDecoder().decode(AMapReverseGeocodeResponse.self, from: data)
        guard payload.status == "1",
              let address = payload.regeocode?.addressComponent,
              let adcode = address.adcode,
              !adcode.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        let name = LocationNamePolicy.displayName(
            district: address.district,
            city: address.city?.value,
            province: address.province,
            fallback: "当前位置"
        )
        return (adcode, name)
    }

    private func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func weatherCode(for text: String) -> Int {
        if text.contains("雷") { return 95 }
        if text.contains("雨") { return 61 }
        if text.contains("雪") { return 71 }
        if text.contains("雾") || text.contains("霾") { return 45 }
        if text.contains("阴") { return 3 }
        if text.contains("云") { return 2 }
        return 0
    }

}
