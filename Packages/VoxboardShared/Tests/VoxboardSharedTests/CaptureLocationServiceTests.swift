import CoreLocation
import XCTest
@testable import VoxboardShared

@MainActor
final class CaptureLocationServiceTests: XCTestCase {
    func test_authorizationRequestStartsExactlyOneOneShotLookup() async throws {
        let manager = FakeCaptureLocationManager(status: .notDetermined)
        let service = CaptureLocationService(
            manager: manager,
            timeout: .seconds(1),
            reverseGeocodeLabel: { _ in CaptureLocationLabel(place: "Test Place") }
        )

        let task = Task { try await service.requestCurrentLocation() }
        await Task.yield()
        XCTAssertEqual(manager.authorizationRequestCount, 1)
        XCTAssertEqual(manager.locationRequestCount, 0)

        manager.sendAuthorization(.authorized)
        XCTAssertEqual(manager.locationRequestCount, 1)
        manager.sendLocations([freshLocation(latitude: 1.25, longitude: -2.5)])

        let value = try await task.value
        XCTAssertEqual(value, CaptureLocationValue(latitude: 1.25, longitude: -2.5, label: "Test Place"))
        XCTAssertEqual(manager.stopCount, 1)
    }

    func test_deniedPermissionFailsWithoutStartingLocation() async {
        let manager = FakeCaptureLocationManager(status: .denied)
        let service = CaptureLocationService(manager: manager, timeout: .seconds(1))

        await assertLocationError(.permissionDenied) {
            _ = try await service.requestCurrentLocation()
        }
        XCTAssertEqual(manager.locationRequestCount, 0)
        XCTAssertEqual(manager.stopCount, 1)
    }

    func test_timeoutAlsoCoversUnresolvedAuthorizationPrompt() async {
        let manager = FakeCaptureLocationManager(status: .notDetermined)
        let service = CaptureLocationService(manager: manager, timeout: .milliseconds(10))

        await assertLocationError(.timedOut) {
            _ = try await service.requestCurrentLocation()
        }
        XCTAssertEqual(manager.authorizationRequestCount, 1)
        XCTAssertEqual(manager.locationRequestCount, 0)
        XCTAssertEqual(manager.stopCount, 1)
    }

    func test_timeoutStopsOneShotLookupAndReleasesRequestGate() async throws {
        let manager = FakeCaptureLocationManager(status: .authorized)
        let service = CaptureLocationService(manager: manager, timeout: .milliseconds(10))

        await assertLocationError(.timedOut) {
            _ = try await service.requestCurrentLocation()
        }
        XCTAssertEqual(manager.locationRequestCount, 1)
        XCTAssertEqual(manager.stopCount, 1)

        let retry = Task { try await service.requestCurrentLocation() }
        await Task.yield()
        XCTAssertEqual(manager.locationRequestCount, 2)
        manager.sendLocations([freshLocation(latitude: 3, longitude: 4)])
        _ = try await retry.value
    }

    func test_cancellationStopsLookupAndDoesNotLeaveRequestInProgress() async throws {
        let manager = FakeCaptureLocationManager(status: .authorized)
        let service = CaptureLocationService(manager: manager, timeout: .seconds(1))

        let cancelled = Task { try await service.requestCurrentLocation() }
        await Task.yield()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(manager.stopCount, 1)

        let retry = Task { try await service.requestCurrentLocation() }
        await Task.yield()
        manager.sendLocations([freshLocation(latitude: 5, longitude: 6)])
        _ = try await retry.value
    }

    func test_secondConcurrentRequestIsRejected() async throws {
        let manager = FakeCaptureLocationManager(status: .authorized)
        let service = CaptureLocationService(manager: manager, timeout: .seconds(1))

        let first = Task { try await service.requestCurrentLocation() }
        await Task.yield()
        await assertLocationError(.requestInProgress) {
            _ = try await service.requestCurrentLocation()
        }
        manager.sendLocations([freshLocation(latitude: 7, longitude: 8)])
        _ = try await first.value
    }

    func test_staleAndInvalidLocationsAreIgnoredUntilFreshFixArrives() async throws {
        let manager = FakeCaptureLocationManager(status: .authorized)
        let service = CaptureLocationService(manager: manager, timeout: .seconds(1))
        let task = Task { try await service.requestCurrentLocation() }
        await Task.yield()

        manager.sendLocations([
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 40, longitude: 41),
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10,
                timestamp: Date(timeIntervalSinceNow: -60)
            ),
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 42, longitude: 43),
                altitude: 0,
                horizontalAccuracy: -1,
                verticalAccuracy: 10,
                timestamp: Date()
            ),
        ])
        manager.sendLocations([freshLocation(latitude: 9, longitude: 10)])

        let value = try await task.value
        XCTAssertEqual(value.latitude, 9)
        XCTAssertEqual(value.longitude, 10)
    }

    func test_resolveSkipsGeocoderWhenConfiguredFieldsDoNotNeedLabels() async throws {
        let manager = FakeCaptureLocationManager(status: .authorized)
        var geocodeCount = 0
        let service = CaptureLocationService(
            manager: manager,
            timeout: .seconds(1),
            reverseGeocodeLabel: { _ in
                geocodeCount += 1
                return CaptureLocationLabel(place: "Unused")
            }
        )
        let policy = CapturePresetLocationPolicy(
            isEnabled: true,
            precision: .city,
            structuredFields: [.coordinates, .timestamp]
        )
        let task = Task { await service.resolveLocation(policy: policy, source: .shareExtension) }
        await Task.yield()
        manager.sendLocations([freshLocation(latitude: 45.5012, longitude: -73.5678)])

        guard case .available(let snapshot) = await task.value else {
            return XCTFail("Expected snapshot")
        }
        XCTAssertEqual(snapshot.latitude, 45.50)
        XCTAssertEqual(snapshot.longitude, -73.57)
        XCTAssertEqual(snapshot.horizontalAccuracy, 10)
        XCTAssertEqual(snapshot.source, .shareExtension)
        XCTAssertNil(snapshot.label)
        XCTAssertEqual(geocodeCount, 0)
    }

    func test_tokenOnlyLocationSkipsReverseGeocoder() async throws {
        let manager = FakeCaptureLocationManager(status: .authorized)
        var geocodeCount = 0
        let service = CaptureLocationService(
            manager: manager,
            timeout: .seconds(1),
            reverseGeocodeLabel: { _ in
                geocodeCount += 1
                return CaptureLocationLabel(place: "Unused")
            }
        )
        let policy = CapturePresetLocationPolicy(
            isEnabled: true,
            metadataOutputEnabled: false,
            structuredFields: [.place, .city]
        )
        let task = Task { await service.resolveLocation(policy: policy, source: .app) }
        await Task.yield()
        manager.sendLocations([freshLocation(latitude: 1, longitude: 2)])

        guard case .available(let snapshot) = await task.value else {
            return XCTFail("Expected snapshot")
        }
        XCTAssertNil(snapshot.label)
        XCTAssertEqual(geocodeCount, 0)
    }

    func test_resolveCollectsAllApplePlacemarkFieldsOnlyWhenRequired() async throws {
        let manager = FakeCaptureLocationManager(status: .authorized)
        let service = CaptureLocationService(
            manager: manager,
            timeout: .seconds(1),
            reverseGeocodeLabel: { _ in
                CaptureLocationLabel(place: "Library", city: "Montréal", region: "QC", country: "Canada")
            }
        )
        let policy = CapturePresetLocationPolicy(isEnabled: true, structuredFields: [.place, .country])
        let task = Task { await service.resolveLocation(policy: policy, source: .app) }
        await Task.yield()
        manager.sendLocations([freshLocation(latitude: 1, longitude: 2)])

        guard case .available(let snapshot) = await task.value else {
            return XCTFail("Expected snapshot")
        }
        XCTAssertEqual(snapshot.label?.place, "Library")
        XCTAssertEqual(snapshot.label?.city, "Montréal")
        XCTAssertEqual(snapshot.label?.region, "QC")
        XCTAssertEqual(snapshot.label?.country, "Canada")
    }

    func test_resolveMapsDeniedAndTimeoutToDurableReasons() async {
        let denied = CaptureLocationService(
            manager: FakeCaptureLocationManager(status: .denied),
            timeout: .seconds(1)
        )
        let policy = CapturePresetLocationPolicy(isEnabled: true)
        guard case .unavailable(let deniedReason, let deniedAt) = await denied.resolveLocation(
            policy: policy,
            source: .shortcut
        ) else { return XCTFail("Expected unavailable") }
        XCTAssertEqual(deniedReason, .permissionDenied)
        XCTAssertGreaterThan(deniedAt.timeIntervalSince1970, 0)

        let timeout = CaptureLocationService(
            manager: FakeCaptureLocationManager(status: .authorized),
            timeout: .milliseconds(10)
        )
        guard case .unavailable(let timeoutReason, _) = await timeout.resolveLocation(
            policy: policy,
            source: .shortcut
        ) else { return XCTFail("Expected unavailable") }
        XCTAssertEqual(timeoutReason, .timeout)
    }

    func test_exactRequestsBestAccuracyAndCityGeocodesOnlyRoundedCoordinates() async throws {
        let exactManager = FakeCaptureLocationManager(status: .authorized)
        let exact = CaptureLocationService(manager: exactManager, timeout: .seconds(1))
        let exactTask = Task {
            await exact.resolveLocation(
                policy: CapturePresetLocationPolicy(isEnabled: true, structuredFields: [.coordinates]),
                source: .app
            )
        }
        await Task.yield()
        XCTAssertEqual(exactManager.desiredAccuracy, kCLLocationAccuracyBest)
        exactManager.sendLocations([freshLocation(latitude: 45.501234, longitude: -73.567891)])
        _ = await exactTask.value

        let cityManager = FakeCaptureLocationManager(status: .authorized)
        var geocodedCoordinate: CLLocationCoordinate2D?
        let city = CaptureLocationService(
            manager: cityManager,
            timeout: .seconds(1),
            reverseGeocodeLabel: { location in
                geocodedCoordinate = location.coordinate
                return CaptureLocationLabel(city: "Montréal")
            }
        )
        let cityTask = Task {
            await city.resolveLocation(
                policy: CapturePresetLocationPolicy(
                    isEnabled: true,
                    precision: .city,
                    structuredFields: [.city]
                ),
                source: .app
            )
        }
        await Task.yield()
        XCTAssertEqual(cityManager.desiredAccuracy, kCLLocationAccuracyKilometer)
        cityManager.sendLocations([freshLocation(latitude: 45.501234, longitude: -73.567891)])
        _ = await cityTask.value
        XCTAssertEqual(geocodedCoordinate?.latitude, 45.50)
        XCTAssertEqual(geocodedCoordinate?.longitude, -73.57)
    }

    func test_reducedAccuracyDoesNotProduceAnExactSnapshot() async {
        let manager = FakeCaptureLocationManager(status: .authorized, accuracy: .reduced)
        let service = CaptureLocationService(manager: manager, timeout: .seconds(1))

        let outcome = await service.resolveLocation(
            policy: CapturePresetLocationPolicy(
                isEnabled: true,
                precision: .exact,
                structuredFields: [.coordinates]
            ),
            source: .mac
        )

        guard case .unavailable(let reason, _) = outcome else {
            return XCTFail("Reduced authorization must not be labeled exact")
        }
        XCTAssertEqual(reason, .reducedAccuracy)
        XCTAssertEqual(manager.locationRequestCount, 0)
    }

    func test_reverseGeocodeTimeoutFailsSoftToCoordinateOnly() async throws {
        let manager = FakeCaptureLocationManager(status: .authorized)
        let service = CaptureLocationService(
            manager: manager,
            timeout: .seconds(1),
            reverseGeocodeTimeout: .milliseconds(10),
            reverseGeocodeLabel: { _ in
                try await Task.sleep(for: .seconds(1))
                return CaptureLocationLabel(place: "Too late")
            }
        )
        let task = Task {
            await service.resolveLocation(
                policy: CapturePresetLocationPolicy(isEnabled: true, structuredFields: [.place]),
                source: .shortcut
            )
        }
        await Task.yield()
        manager.sendLocations([freshLocation(latitude: 1, longitude: 2)])
        guard case .available(let snapshot) = await task.value else {
            return XCTFail("Expected coordinates after geocoder timeout")
        }
        XCTAssertNil(snapshot.label)
        XCTAssertEqual(snapshot.latitude, 1)
    }

    func test_automationNotDeterminedDoesNotPromptAndReturnsDurableUnavailable() async {
        let manager = FakeCaptureLocationManager(status: .notDetermined)
        let service = CaptureLocationService(manager: manager, timeout: .seconds(1))
        let outcome = await service.resolveLocationIfAuthorized(
            policy: CapturePresetLocationPolicy(isEnabled: true),
            source: .shortcut
        )
        guard case .unavailable(let reason, let attemptedAt) = outcome else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .notDetermined)
        XCTAssertGreaterThan(attemptedAt.timeIntervalSince1970, 0)
        XCTAssertEqual(manager.authorizationRequestCount, 0)
        XCTAssertEqual(manager.locationRequestCount, 0)
    }

    func test_reverseGeocodeFailureFallsBackToGenericPrivateLabel() async throws {
        let manager = FakeCaptureLocationManager(status: .authorized)
        let service = CaptureLocationService(
            manager: manager,
            timeout: .seconds(1),
            reverseGeocodeLabel: { _ in throw TestError.geocode }
        )
        let task = Task { try await service.requestCurrentLocation() }
        await Task.yield()
        manager.sendLocations([freshLocation(latitude: 11, longitude: 12)])

        let value = try await task.value
        XCTAssertEqual(value.label, "Location")
    }

    private func freshLocation(latitude: Double, longitude: Double) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            timestamp: Date()
        )
    }

    private func assertLocationError(
        _ expected: CaptureLocationError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as CaptureLocationError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class FakeCaptureLocationManager: CaptureLocationManaging {
    var authorizationStatus: CaptureLocationAuthorization
    var locationServicesEnabled = true
    var accuracyAuthorization: CaptureLocationAccuracyAuthorization
    var onAuthorizationChange: ((CaptureLocationAuthorization) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onFailure: ((Error) -> Void)?
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters

    private(set) var authorizationRequestCount = 0
    private(set) var locationRequestCount = 0
    private(set) var stopCount = 0

    init(
        status: CaptureLocationAuthorization,
        accuracy: CaptureLocationAccuracyAuthorization = .full
    ) {
        authorizationStatus = status
        accuracyAuthorization = accuracy
    }

    func requestWhenInUseAuthorization() {
        authorizationRequestCount += 1
    }

    func requestLocation() {
        locationRequestCount += 1
    }

    func stopUpdatingLocation() {
        stopCount += 1
    }

    func sendAuthorization(_ status: CaptureLocationAuthorization) {
        authorizationStatus = status
        onAuthorizationChange?(status)
    }

    func sendLocations(_ locations: [CLLocation]) {
        onLocations?(locations)
    }
}

private enum TestError: Error {
    case geocode
}
