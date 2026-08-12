import CoreLocation
import Foundation
import VoxboardCaptureCore

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
    case notDetermined
    case reducedAccuracy
    case unavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Location access is off. Enable it in Settings to add location metadata.")
        case .restricted:
            return String(localized: "Location access is restricted on this device.")
        case .requestInProgress:
            return String(localized: "A location request is already in progress.")
        case .notDetermined:
            return String(localized: "Open Vox.md to choose whether location access is allowed.")
        case .reducedAccuracy:
            return String(localized: "Precise Location is off, so this preset’s exact location could not be captured.")
        case .unavailable:
            return String(localized: "Your current location is unavailable. Try again outside or after location services reconnect.")
        case .timedOut:
            return String(localized: "Finding your location took too long. Try again.")
        }
    }
}

public enum CaptureLocationAccuracyAuthorization: Equatable, Sendable {
    case full
    case reduced
}

public enum CaptureLocationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

@MainActor
public protocol CaptureLocationManaging: AnyObject {
    var authorizationStatus: CaptureLocationAuthorization { get }
    var locationServicesEnabled: Bool { get }
    var accuracyAuthorization: CaptureLocationAccuracyAuthorization { get }
    var onAuthorizationChange: ((CaptureLocationAuthorization) -> Void)? { get set }
    var onLocations: (([CLLocation]) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }

    func requestWhenInUseAuthorization()
    func requestLocation()
    func stopUpdatingLocation()
}

/// Injectable origin-time boundary used by foreground and unattended capture
/// sources. Implementations return a final outcome; delivery must never call it.
@MainActor
public protocol CaptureLocationOutcomeProviding: AnyObject {
    func resolveLocation(
        policy: CapturePresetLocationPolicy,
        source: CaptureSource
    ) async -> CaptureLocationOutcome
}

/// Explicit one-shot provider. It never starts monitoring and retains no fix
/// after the current request finishes.
@MainActor
public final class CaptureLocationService: CaptureLocationOutcomeProviding {
    public typealias ReverseGeocodeLabel = (CLLocation) async throws -> CaptureLocationLabel?

    private let manager: any CaptureLocationManaging
    private let locationTimeout: Duration
    private let authorizationTimeout: Duration
    private let reverseGeocodeLabel: ReverseGeocodeLabel
    private let reverseGeocodeTimeout: Duration
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
        reverseGeocodeTimeout: Duration = .seconds(5),
        reverseGeocodeLabel: @escaping ReverseGeocodeLabel = CaptureLocationService.systemReverseGeocodeLabel
    ) {
        self.manager = manager
        self.locationTimeout = timeout
        self.authorizationTimeout = authorizationTimeout ?? timeout
        self.reverseGeocodeLabel = reverseGeocodeLabel
        self.reverseGeocodeTimeout = reverseGeocodeTimeout

        manager.onAuthorizationChange = { [weak self] status in self?.authorizationChanged(to: status) }
        manager.onLocations = { [weak self] locations in self?.received(locations: locations) }
        manager.onFailure = { [weak self] error in self?.received(error: error) }
    }

    /// Preserves the explicit Capture Bar insertion behavior. Unlike preset
    /// metadata this always asks for a label because the inserted link uses it.
    public func requestCurrentLocation() async throws -> CaptureLocationValue {
        let location = try await requestRawLocation()
        let label: CaptureLocationLabel?
        do {
            label = try await boundedReverseGeocode(location)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            label = nil
        }
        try Task.checkCancellation()
        return CaptureLocationValue(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            label: label?.place ?? label?.city ?? label?.region ?? String(localized: "Location")
        )
    }

    public func resolveLocation(
        policy: CapturePresetLocationPolicy,
        source: CaptureSource
    ) async -> CaptureLocationOutcome {
        await resolveLocation(policy: policy, source: source, allowsAuthorizationRequest: true)
    }

    /// Automation must not unexpectedly initiate a long permission prompt.
    /// Not-determined authorization becomes a durable unavailable outcome.
    public func resolveLocationIfAuthorized(
        policy: CapturePresetLocationPolicy,
        source: CaptureSource
    ) async -> CaptureLocationOutcome {
        await resolveLocation(policy: policy, source: source, allowsAuthorizationRequest: false)
    }

    private func resolveLocation(
        policy: CapturePresetLocationPolicy,
        source: CaptureSource,
        allowsAuthorizationRequest: Bool
    ) async -> CaptureLocationOutcome {
        let attemptedAt = Date()
        manager.desiredAccuracy = policy.precision == .exact
            ? kCLLocationAccuracyBest
            : kCLLocationAccuracyKilometer
        do {
            let location = try await requestRawLocation(
                allowsAuthorizationRequest: allowsAuthorizationRequest
            )
            // Construct the privacy-adjusted coordinates before geocoding.
            // City policies must never disclose the raw fix to CLGeocoder.
            let adjusted = CaptureLocationSnapshot(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                timestamp: location.timestamp,
                source: source,
                precision: policy.precision,
                label: nil
            )
            let label: CaptureLocationLabel?
            if policy.requiresLabels {
                let geocodeLocation = CLLocation(
                    coordinate: CLLocationCoordinate2D(
                        latitude: adjusted.latitude,
                        longitude: adjusted.longitude
                    ),
                    altitude: 0,
                    horizontalAccuracy: adjusted.horizontalAccuracy ?? -1,
                    verticalAccuracy: -1,
                    timestamp: adjusted.timestamp
                )
                do {
                    label = try await boundedReverseGeocode(geocodeLocation)
                } catch is CancellationError {
                    return .unavailable(.cancelled, attemptedAt: attemptedAt)
                } catch {
                    // Apple geocoding is best-effort and bounded. Coordinates
                    // remain useful offline; delivery never geocodes again.
                    label = nil
                }
            } else {
                label = nil
            }
            return .available(CaptureLocationSnapshot(
                latitude: adjusted.latitude,
                longitude: adjusted.longitude,
                horizontalAccuracy: adjusted.horizontalAccuracy,
                timestamp: adjusted.timestamp,
                source: adjusted.source,
                precision: adjusted.precision,
                label: label
            ))
        } catch is CancellationError {
            return .unavailable(.cancelled, attemptedAt: attemptedAt)
        } catch let error as CaptureLocationError {
            return .unavailable(Self.unavailableReason(for: error), attemptedAt: attemptedAt)
        } catch {
            return .unavailable(.unavailable, attemptedAt: attemptedAt)
        }
    }

    public static func requiresLabels(_ policy: CapturePresetLocationPolicy) -> Bool {
        policy.requiresLabels
    }

    private static func unavailableReason(for error: CaptureLocationError) -> CaptureLocationUnavailableReason {
        switch error {
        case .permissionDenied: return .permissionDenied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .reducedAccuracy: return .reducedAccuracy
        case .timedOut: return .timeout
        case .requestInProgress, .unavailable: return .unavailable
        }
    }

    private func boundedReverseGeocode(_ location: CLLocation) async throws -> CaptureLocationLabel? {
        try await withThrowingTaskGroup(of: CaptureLocationLabel?.self) { group in
            group.addTask { [reverseGeocodeLabel] in
                try await reverseGeocodeLabel(location)
            }
            group.addTask { [reverseGeocodeTimeout] in
                try await Task.sleep(for: reverseGeocodeTimeout)
                throw CaptureLocationError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private func requestRawLocation(allowsAuthorizationRequest: Bool = true) async throws -> CLLocation {
        guard continuation == nil else { throw CaptureLocationError.requestInProgress }
        guard manager.locationServicesEnabled else { throw CaptureLocationError.unavailable }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                switch manager.authorizationStatus {
                case .notDetermined:
                    guard allowsAuthorizationRequest else {
                        finish(.failure(CaptureLocationError.notDetermined))
                        return
                    }
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
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func authorizationChanged(to status: CaptureLocationAuthorization) {
        guard continuation != nil else { return }
        switch status {
        case .authorized:
            startTimeout(locationTimeout)
            beginRequest()
        case .denied: finish(.failure(CaptureLocationError.permissionDenied))
        case .restricted: finish(.failure(CaptureLocationError.restricted))
        case .notDetermined: break
        case .unavailable: finish(.failure(CaptureLocationError.unavailable))
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
        if manager.desiredAccuracy == kCLLocationAccuracyBest,
           manager.accuracyAuthorization == .reduced {
            finish(.failure(CaptureLocationError.reducedAccuracy))
            return
        }
        manager.requestLocation()
    }

    private func startTimeout(_ duration: Duration) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, duration] in
            do { try await Task.sleep(for: duration) } catch { return }
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
        location.horizontalAccuracy >= 0 && abs(location.timestamp.timeIntervalSinceNow) < 30
    }

    public static func systemReverseGeocodeLabel(_ location: CLLocation) async throws -> CaptureLocationLabel? {
        guard let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        return CaptureLocationLabel(
            place: placemark.name,
            city: placemark.locality ?? placemark.subLocality,
            region: placemark.administrativeArea,
            country: placemark.country
        )
    }
}

@MainActor
private final class SystemCaptureLocationManager: NSObject, CaptureLocationManaging, @preconcurrency CLLocationManagerDelegate {
    private let manager: CLLocationManager
    var onAuthorizationChange: ((CaptureLocationAuthorization) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onFailure: ((Error) -> Void)?
    var desiredAccuracy: CLLocationAccuracy {
        get { manager.desiredAccuracy }
        set { manager.desiredAccuracy = newValue }
    }

    override init() {
        manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        super.init()
        manager.delegate = self
    }

    var authorizationStatus: CaptureLocationAuthorization { Self.map(manager.authorizationStatus) }
    var locationServicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }
    var accuracyAuthorization: CaptureLocationAccuracyAuthorization {
        manager.accuracyAuthorization == .fullAccuracy ? .full : .reduced
    }
    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestLocation() { manager.requestLocation() }
    func stopUpdatingLocation() { manager.stopUpdatingLocation() }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(Self.map(manager.authorizationStatus))
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        onLocations?(locations)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { onFailure?(error) }

    private static func map(_ status: CLAuthorizationStatus) -> CaptureLocationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways: return .authorized
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        case .authorizedWhenInUse: return .authorized
#endif
        @unknown default: return .unavailable
        }
    }
}
