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
            reverseGeocodeLabel: { _ in "Test Place" }
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
    var onAuthorizationChange: ((CaptureLocationAuthorization) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onFailure: ((Error) -> Void)?

    private(set) var authorizationRequestCount = 0
    private(set) var locationRequestCount = 0
    private(set) var stopCount = 0

    init(status: CaptureLocationAuthorization) {
        authorizationStatus = status
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
