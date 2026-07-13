@preconcurrency import CoreLocation
import Foundation

@MainActor
final class LocationClient: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum LocationError: Error {
        case servicesDisabled
        case permissionDenied
        case unavailable
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var bestLocation: CLLocation?
    private var timeoutTask: Task<Void, Never>?
    private var isUpdating = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func currentLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else { throw LocationError.servicesDisabled }
        guard continuation == nil else { throw LocationError.unavailable }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            bestLocation = nil
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorized, .authorizedAlways:
                beginUpdatingLocation()
            case .denied, .restricted:
                finish(.failure(LocationError.permissionDenied))
            @unknown default:
                finish(.failure(LocationError.unavailable))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            beginUpdatingLocation()
        case .denied, .restricted:
            finish(.failure(LocationError.permissionDenied))
        case .notDetermined:
            break
        @unknown default:
            finish(.failure(LocationError.unavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard continuation != nil,
              let candidate = LocationSelectionPolicy.bestLocation(in: locations) else { return }

        if let currentBest = bestLocation {
            if candidate.horizontalAccuracy < currentBest.horizontalAccuracy { bestLocation = candidate }
        } else {
            bestLocation = candidate
        }
        if LocationSelectionPolicy.isPreciseEnough(candidate) {
            finish(.success(candidate))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let bestLocation {
            finish(.success(bestLocation))
        } else {
            finish(.failure(error))
        }
    }

    func displayName(for location: CLLocation, language: AppLanguage) async -> String {
        let fallback = language == .simplifiedChinese ? "当前位置" : "Current location"
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(
            location,
            preferredLocale: language.locale
        ).first else { return fallback }

        return LocationNamePolicy.displayName(
            district: placemark.subLocality,
            city: placemark.locality ?? placemark.subAdministrativeArea,
            province: placemark.administrativeArea,
            fallback: fallback
        )
    }

    private func beginUpdatingLocation() {
        guard !isUpdating else { return }
        isUpdating = true
        manager.startUpdatingLocation()
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self else { return }
            if let bestLocation = self.bestLocation {
                self.finish(.success(bestLocation))
            } else {
                self.finish(.failure(LocationError.unavailable))
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        manager.stopUpdatingLocation()
        timeoutTask?.cancel()
        timeoutTask = nil
        bestLocation = nil
        isUpdating = false
        self.continuation = nil
        continuation.resume(with: result)
    }
}

enum LocationSelectionPolicy {
    static let maximumAge: TimeInterval = 30
    static let targetAccuracy: CLLocationAccuracy = 250

    static func bestLocation(in locations: [CLLocation], now: Date = .now) -> CLLocation? {
        locations
            .filter { location in
                let age = now.timeIntervalSince(location.timestamp)
                return age >= -5
                    && age <= maximumAge
                    && location.horizontalAccuracy >= 0
                    && location.horizontalAccuracy <= 10_000
            }
            .min { $0.horizontalAccuracy < $1.horizontalAccuracy }
    }

    static func isPreciseEnough(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy <= targetAccuracy
    }
}

enum LocationNamePolicy {
    static func displayName(district: String?, city: String?, province: String?, fallback: String) -> String {
        let value = [district, city, province]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? fallback
        return removeAdministrativeSuffix(from: value)
    }

    private static func removeAdministrativeSuffix(from value: String) -> String {
        for suffix in ["自治县", "自治州", "新区", "城区", "市", "区", "县"] where value.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count))
        }
        return value
    }
}
