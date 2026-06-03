import Foundation
import OpenClawKit
import CoreLocation

final class LocationService: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    enum LocationError: Swift.Error {
        case timeout
        case unavailable
        case disabled
        case permissionDenied
    }

    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation, Swift.Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    var accuracyAuthorization: CLAccuracyAuthorization {
        if #available(iOS 14.0, *) {
            return manager.accuracyAuthorization
        }
        return .fullAccuracy
    }

    func ensureAuthorization(mode: OpenClawLocationMode) async -> CLAuthorizationStatus {
        guard CLLocationManager.locationServicesEnabled() else { return .denied }

        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            let updated = await awaitAuthorizationChange()
            if mode != .always { return updated }
        }

        if mode == .always {
            let current = manager.authorizationStatus
            if current == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
                return await awaitAuthorizationChange()
            }
            return current
        }

        return manager.authorizationStatus
    }

    func currentLocation(
        params: OpenClawLocationGetParams,
        desiredAccuracy: OpenClawLocationAccuracy,
        maxAgeMs: Int?,
        timeoutMs: Int?) async throws -> CLLocation
    {
        // First ensure we have authorization
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            let updated = await awaitAuthorizationChange()
            if updated != .authorizedWhenInUse && updated != .authorizedAlways {
                throw LocationError.permissionDenied
            }
        } else if status == .denied || status == .restricted {
            throw LocationError.permissionDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.locationContinuation = continuation

            manager.desiredAccuracy = accuracyFor(desiredAccuracy)
            manager.requestLocation()

            // Timeout handling
            let timeout = timeoutMs ?? 10000
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
                if self.locationContinuation != nil {
                    self.locationContinuation?.resume(throwing: LocationError.timeout)
                    self.locationContinuation = nil
                }
            }
        }
    }

    private func accuracyFor(_ accuracy: OpenClawLocationAccuracy) -> CLLocationAccuracy {
        switch accuracy {
        case .precise:
            return kCLLocationAccuracyBest
        case .balanced:
            return kCLLocationAccuracyHundredMeters
        case .coarse:
            return kCLLocationAccuracyThreeKilometers
        }
    }

    private func awaitAuthorizationChange() async -> CLAuthorizationStatus {
        await withCheckedContinuation { cont in
            authContinuation = cont
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if let cont = self.authContinuation {
                self.authContinuation = nil
                cont.resume(returning: manager.authorizationStatus)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let cont = self.locationContinuation, let latest = locations.last else { return }
            self.locationContinuation = nil
            cont.resume(returning: latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in
            guard let cont = self.locationContinuation else { return }
            self.locationContinuation = nil
            cont.resume(throwing: error)
        }
    }
}