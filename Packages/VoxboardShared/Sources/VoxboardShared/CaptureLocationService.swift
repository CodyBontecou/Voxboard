import CoreLocation
import Foundation

public struct CaptureLocationValue: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var label: String

    public init(latitude: Double, longitude: Double, label: String) {
        self.latitude = latitude
        self.longitude = longitude
        self.label = label
    }
}

public enum CaptureLocationError: Error, LocalizedError, Equatable, Sendable {
    case permissionDenied
    case restricted
    case requestInProgress
    case unavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Location access is off. Enable it in Settings to insert a map link.")
        case .restricted:
            return String(localized: "Location access is restricted on this device.")
        case .requestInProgress:
            return String(localized: "A location request is already in progress.")
        case .unavailable:
            return String(localized: "Your current location is unavailable. Try again outside or after location services reconnect.")
        case .timedOut:
            return String(localized: "Finding your location took too long. Try again.")
        }
    }
}

public enum CaptureLocationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

/// Minimal location-manager surface used by the one-shot capture service. The
/// injectable boundary keeps permission, timeout, stale-fix, and cancellation
/// behavior deterministic in tests without ever starting continuous updates.
@MainActor
public protocol CaptureLocationManaging: AnyObject {
    var authorizationStatus: CaptureLocationAuthorization { get }
    var locationServicesEnabled: Bool { get }
    var onAuthorizationChange: ((CaptureLocationAuthorization) -> Void)? { get set }
    var onLocations: (([CLLocation]) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }

    func requestWhenInUseAuthorization()
    func requestLocation()
    func stopUpdatingLocation()
}

/// Explicit, one-shot location lookup for inserting a map link. It never starts
/// monitoring and retains no location after the caller receives the result.
@MainActor
public final class CaptureLocationService {
    public typealias ReverseGeocodeLabel = (CLLocation) async throws -> String?

    private let manager: any CaptureLocationManaging
    private let locationTimeout: Duration
    private let authorizationTimeout: Duration
    private let reverseGeocodeLabel: ReverseGeocodeLabel
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?

    public convenience init() {
        self.init(
            manager: SystemCaptureLocationManager(),
            timeout: .seconds(15),
            authorizationTimeout: .seconds(60)
        )
    }

    public init(
        manager: any CaptureLocationManaging,
        timeout: Duration = .seconds(15),
        authorizationTimeout: Duration? = nil,
        reverseGeocodeLabel: @escaping ReverseGeocodeLabel = CaptureLocationService.systemReverseGeocodeLabel
    ) {
        self.manager = manager
        self.locationTimeout = timeout
        self.authorizationTimeout = authorizationTimeout ?? timeout
        self.reverseGeocodeLabel = reverseGeocodeLabel

        manager.onAuthorizationChange = { [weak self] status in
            self?.authorizationChanged(to: status)
        }
        manager.onLocations = { [weak self] locations in
            self?.received(locations: locations)
        }
        manager.onFailure = { [weak self] error in
            self?.received(error: error)
        }
    }

    public func requestCurrentLocation() async throws -> CaptureLocationValue {
        guard continuation == nil else { throw CaptureLocationError.requestInProgress }
        guard manager.locationServicesEnabled else { throw CaptureLocationError.unavailable }

        let location = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                switch manager.authorizationStatus {
                case .notDetermined:
                    startTimeout(authorizationTimeout)
                    manager.requestWhenInUseAuthorization()
                case .authorized:
                    startTimeout(locationTimeout)
                    beginRequest()
                case .denied:
                    finish(.failure(CaptureLocationError.permissionDenied))
                case .restricted:
                    finish(.failure(CaptureLocationError.restricted))
                case .unavailable:
                    finish(.failure(CaptureLocationError.unavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }

        try Task.checkCancellation()
        let label: String
        do {
            label = try await reverseGeocodeLabel(location) ?? String(localized: "Location")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            label = String(localized: "Location")
        }
        try Task.checkCancellation()
        return CaptureLocationValue(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            label: label
        )
    }

    private func authorizationChanged(to status: CaptureLocationAuthorization) {
        guard continuation != nil else { return }
        switch status {
        case .authorized:
            startTimeout(locationTimeout)
            beginRequest()
        case .denied:
            finish(.failure(CaptureLocationError.permissionDenied))
        case .restricted:
            finish(.failure(CaptureLocationError.restricted))
        case .notDetermined:
            break
        case .unavailable:
            finish(.failure(CaptureLocationError.unavailable))
        }
    }

    private func received(locations: [CLLocation]) {
        guard let location = locations.last(where: Self.isFreshUsableLocation) else { return }
        finish(.success(location))
    }

    private func received(error: Error) {
        if let locationError = error as? CLError, locationError.code == .denied {
            finish(.failure(CaptureLocationError.permissionDenied))
        } else {
            finish(.failure(CaptureLocationError.unavailable))
        }
    }

    private func beginRequest() {
        guard continuation != nil else { return }
        manager.requestLocation()
    }

    private func startTimeout(_ duration: Duration) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, duration] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.finish(.failure(CaptureLocationError.timedOut))
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        continuation.resume(with: result)
    }

    private static func isFreshUsableLocation(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0
            && abs(location.timestamp.timeIntervalSinceNow) < 30
    }

    public static func systemReverseGeocodeLabel(_ location: CLLocation) async throws -> String? {
        let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.name
            ?? placemark?.locality
            ?? placemark?.subLocality
            ?? placemark?.administrativeArea
    }
}

@MainActor
private final class SystemCaptureLocationManager: NSObject, CaptureLocationManaging, @preconcurrency CLLocationManagerDelegate {
    private let manager: CLLocationManager

    var onAuthorizationChange: ((CaptureLocationAuthorization) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onFailure: ((Error) -> Void)?

    override init() {
        manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        super.init()
        manager.delegate = self
    }

    var authorizationStatus: CaptureLocationAuthorization {
        Self.map(manager.authorizationStatus)
    }

    var locationServicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestLocation() {
        manager.requestLocation()
    }

    func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(Self.map(manager.authorizationStatus))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        onLocations?(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onFailure?(error)
    }

    private static func map(_ status: CLAuthorizationStatus) -> CaptureLocationAuthorization {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorizedAlways:
            return .authorized
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        case .authorizedWhenInUse:
            return .authorized
#endif
        @unknown default:
            return .unavailable
        }
    }
}
