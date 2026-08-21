import XCTest
@testable import VoxboardCaptureCore

final class CaptureLocationMetadataTests: XCTestCase {
    func testPolicyDefaultsAndLegacyMetadataOutputMigration() throws {
        let newPolicy = CapturePresetLocationPolicy()
        XCTAssertFalse(newPolicy.isEnabled)
        XCTAssertFalse(newPolicy.metadataOutputEnabled)

        let explicitlyEnabled = CapturePresetLocationPolicy(isEnabled: true)
        XCTAssertTrue(explicitlyEnabled.metadataOutputEnabled)

        let legacyDisabled = try JSONDecoder().decode(
            CapturePresetLocationPolicy.self,
            from: Data("{\"isEnabled\":false}".utf8)
        )
        XCTAssertFalse(legacyDisabled.isEnabled)
        XCTAssertFalse(legacyDisabled.metadataOutputEnabled)
        let legacyEnabled = try JSONDecoder().decode(
            CapturePresetLocationPolicy.self,
            from: Data("{\"isEnabled\":true}".utf8)
        )
        XCTAssertTrue(legacyEnabled.isEnabled)
        XCTAssertTrue(legacyEnabled.metadataOutputEnabled)

        let tokenOnly = CapturePresetLocationPolicy(
            isEnabled: true,
            metadataOutputEnabled: false
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                CapturePresetLocationPolicy.self,
                from: JSONEncoder().encode(tokenOnly)
            ),
            tokenOnly
        )
    }

    func testPolicyRequiresLabelsOnlyForConfiguredMetadataLabelFields() {
        var policy = CapturePresetLocationPolicy(
            isEnabled: true,
            structuredFields: [.coordinates, .timestamp]
        )
        XCTAssertFalse(policy.requiresLabels)

        policy.structuredFields.append(.city)
        XCTAssertTrue(policy.requiresLabels)

        policy.metadataOutputEnabled = false
        XCTAssertFalse(policy.requiresLabels)
        policy.metadataOutputEnabled = true

        policy.outputMode = .advancedTemplate
        policy.advancedTemplate = "position: {{coordinates}}"
        XCTAssertFalse(policy.requiresLabels)
        policy.advancedTemplate = "locality: {{ city }}"
        XCTAssertTrue(policy.requiresLabels)

        policy.isEnabled = false
        XCTAssertFalse(policy.requiresLabels)
    }

    func test_watchRecordingOnlySnapshotSkipsLocationAcquisition() throws {
        let profile = CapturePresetProfile(
            id: "watch",
            name: "Watch",
            symbolName: "applewatch",
            locationPolicy: CapturePresetLocationPolicy(isEnabled: true)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        )

        object["watchOutputMode"] = "transcript"
        XCTAssertTrue(CaptureWatchLocationAcquisitionPolicy.shouldAcquire(
            presetSnapshot: try JSONSerialization.data(withJSONObject: object)
        ))

        object["watchOutputMode"] = "recordingOnly"
        XCTAssertFalse(CaptureWatchLocationAcquisitionPolicy.shouldAcquire(
            presetSnapshot: try JSONSerialization.data(withJSONObject: object)
        ))
        XCTAssertFalse(CaptureWatchLocationAcquisitionPolicy.shouldAcquire(presetSnapshot: nil))
    }

    private let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    func test_exactFormatterProducesEveryFieldAndProviderFormatDeterministically() throws {
        let values = try CaptureLocationFormatter().format(
            snapshot: snapshot(),
            requestID: requestID
        )

        XCTAssertEqual(values[.coordinates], "45.501235, -73.567890")
        XCTAssertEqual(values[.latitude], "45.501235")
        XCTAssertEqual(values[.longitude], "-73.567890")
        XCTAssertEqual(values[.place], "Café & Main")
        XCTAssertEqual(values[.city], "Montréal")
        XCTAssertEqual(values[.region], "Québec")
        XCTAssertEqual(values[.country], "Canada")
        XCTAssertEqual(values[.accuracy], "12.3 m")
        XCTAssertEqual(values[.timestamp], "2023-11-14T22:13:20.000Z")
        XCTAssertEqual(values[.source], "shareExtension")
        XCTAssertEqual(values[.id], requestID.uuidString.lowercased())
        XCTAssertEqual(
            values[.appleMapsURL],
            "https://maps.apple.com/?ll=45.501235%2C-73.567890&q=Caf%C3%A9%20%26%20Main"
        )
        XCTAssertEqual(
            values[.googleMapsURL],
            "https://www.google.com/maps/search/?api=1&query=45.501235%2C-73.567890"
        )
        XCTAssertEqual(
            values[.openStreetMapURL],
            "https://www.openstreetmap.org/?mlat=45.501235&mlon=-73.567890#map=16/45.501235/-73.567890"
        )
        XCTAssertEqual(values[.geoURI], "geo:45.501235,-73.567890;u=12.3")
    }

    func test_cityPrecisionUsesSameTwoDecimalCoordinatesInEveryDerivedValue() throws {
        let citySnapshot = CaptureLocationSnapshot(
            latitude: 45.50123456,
            longitude: -73.56789,
            timestamp: timestamp,
            source: .app,
            precision: .city
        )
        XCTAssertEqual(citySnapshot.latitude, 45.50)
        XCTAssertEqual(citySnapshot.longitude, -73.57)

        let values = try CaptureLocationFormatter().format(
            snapshot: snapshot(),
            requestID: requestID,
            precision: .city
        )

        XCTAssertEqual(values[.coordinates], "45.50, -73.57")
        XCTAssertEqual(values[.place], "Montréal")
        XCTAssertEqual(values[.appleMapsURL], "https://maps.apple.com/?ll=45.50%2C-73.57&q=Montr%C3%A9al")
        XCTAssertEqual(values[.googleMapsURL], "https://www.google.com/maps/search/?api=1&query=45.50%2C-73.57")
        XCTAssertEqual(values[.openStreetMapURL], "https://www.openstreetmap.org/?mlat=45.50&mlon=-73.57#map=10/45.50/-73.57")
        XCTAssertEqual(values[.geoURI], "geo:45.50,-73.57;u=12.3")
    }

    func test_citySnapshotDropsPOIBeforeRequestPersistence() throws {
        let city = CaptureLocationSnapshot(
            latitude: 45.50123456,
            longitude: -73.56789,
            timestamp: timestamp,
            source: .app,
            precision: .city,
            label: CaptureLocationLabel(
                place: "SECRET EXACT POI",
                city: "Montréal",
                region: "Québec",
                country: "Canada"
            )
        )
        XCTAssertNil(city.label?.place)
        var mutatedCity = city
        mutatedCity.label?.place = "MUTATED SECRET POI"
        let request = makeRequest(
            policy: CapturePresetLocationPolicy(isEnabled: true, precision: .city),
            snapshot: mutatedCity
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("SECRET EXACT POI"))
        XCTAssertFalse(json.contains("MUTATED SECRET POI"))
        let decoded = try JSONDecoder().decode(CaptureRequest.self, from: data)
        guard case .available(let decodedCity)? = decoded.locationOutcome else {
            return XCTFail("Expected available city snapshot")
        }
        XCTAssertNil(decodedCity.label?.place)
        XCTAssertEqual(decodedCity.latitude, 45.50)
        XCTAssertEqual(decodedCity.longitude, -73.57)
    }

    func test_formatterIsPOSIXRangeCheckedAndLabelEncodingIsInjectionSafe() throws {
        let encoded = try CaptureLocationFormatter().format(
            snapshot: CaptureLocationSnapshot(
                latitude: -0.0,
                longitude: 7.25,
                timestamp: timestamp,
                source: .app,
                precision: .exact,
                label: CaptureLocationLabel(place: "Line 1\n東京 / ?")
            ),
            requestID: requestID
        )
        XCTAssertEqual(encoded[.coordinates], "0.000000, 7.250000")
        XCTAssertFalse(try XCTUnwrap(encoded[.coordinates]).contains(",000"))
        XCTAssertTrue(try XCTUnwrap(encoded[.appleMapsURL]).contains("Line%201%20%E6%9D%B1%E4%BA%AC%20%2F%20%3F"))
        XCTAssertFalse(try XCTUnwrap(encoded[.appleMapsURL]).contains("\n"))
        XCTAssertEqual(encoded[.geoURI], "geo:0.000000,7.250000")

        for (latitude, longitude) in [(91.0, 0.0), (0.0, -181.0), (.infinity, 0.0), (.nan, 0.0)] {
            XCTAssertThrowsError(
                try CaptureLocationFormatter().format(
                    snapshot: CaptureLocationSnapshot(
                        latitude: latitude,
                        longitude: longitude,
                        timestamp: timestamp,
                        source: .app,
                        precision: .exact
                    ),
                    requestID: requestID
                )
            ) { XCTAssertEqual($0 as? CaptureLocationMetadataError, .invalidCoordinate) }
        }
    }

    func test_structuredRendererDeduplicatesFieldsAndOmitsMissingOptionalLabels() throws {
        let request = makeRequest(
            policy: CapturePresetLocationPolicy(
                isEnabled: true,
                structuredFields: [.city, .city, .region, .id, .coordinates]
            ),
            snapshot: CaptureLocationSnapshot(
                latitude: 1,
                longitude: 2,
                timestamp: timestamp,
                source: .watch,
                precision: .exact,
                label: CaptureLocationLabel(city: "Accra")
            )
        )

        let rendered = try XCTUnwrap(CaptureLocationMetadataRenderer().render(request: request))

        XCTAssertEqual(rendered.itemLines.filter { $0.hasPrefix("city:") }.count, 1)
        XCTAssertFalse(rendered.itemLines.contains { $0.hasPrefix("region:") })
        XCTAssertEqual(rendered.itemLines.filter { $0.hasPrefix("id:") }.count, 1)
        XCTAssertTrue(rendered.itemLines.contains("coordinates: [1.000000, 2.000000]"))
        XCTAssertTrue(rendered.inlineLines.contains("location.city:: \"Accra\""))
    }

    func test_structuredRendererSupportsRenamedKeysTypedScalarsAndCollisions() throws {
        let policy = CapturePresetLocationPolicy(
            isEnabled: true,
            structuredFields: [
                CaptureLocationStructuredField(field: .coordinates, outputKey: "lat_lon"),
                CaptureLocationStructuredField(field: .latitude, outputKey: "lat"),
                CaptureLocationStructuredField(field: .longitude, outputKey: "lon"),
                CaptureLocationStructuredField(field: .accuracy, outputKey: "uncertainty"),
            ]
        )
        let rendered = try XCTUnwrap(
            CaptureLocationMetadataRenderer().render(request: makeRequest(policy: policy))
        )
        XCTAssertTrue(rendered.itemLines.contains("lat_lon: [45.501235, -73.567890]"))
        XCTAssertTrue(rendered.itemLines.contains("lat: 45.501235"))
        XCTAssertTrue(rendered.itemLines.contains("lon: -73.567890"))
        XCTAssertTrue(rendered.itemLines.contains("uncertainty: 12.3"))
        XCTAssertFalse(rendered.itemLines.joined().contains("\"45.501235\""))

        var parser = try CaptureLocationConstrainedYAMLParser(
            source: rendered.itemLines.joined(separator: "\n"),
            maximumDepth: CaptureLocationMetadataRenderer.maximumNestingDepth
        )
        guard case .mapping(let pairs) = try parser.parse(),
              case .flowSequence(let coordinates)? = pairs.first(where: { $0.key == "lat_lon" })?.value,
              coordinates.count == 2,
              case .number = coordinates[0],
              case .number = coordinates[1] else {
            return XCTFail("Expected typed coordinate sequence")
        }

        let collision = CapturePresetLocationPolicy(
            isEnabled: true,
            structuredFields: [
                CaptureLocationStructuredField(field: .city, outputKey: "where"),
                CaptureLocationStructuredField(field: .country, outputKey: "where"),
            ]
        )
        XCTAssertThrowsError(
            try CaptureLocationMetadataRenderer().render(request: makeRequest(policy: collision))
        ) { XCTAssertEqual($0 as? CaptureLocationMetadataError, .duplicateOutputKey("where")) }

        let invalid = CapturePresetLocationPolicy(
            isEnabled: true,
            structuredFields: [CaptureLocationStructuredField(field: .city, outputKey: "bad: key")]
        )
        XCTAssertThrowsError(
            try CaptureLocationMetadataRenderer().render(request: makeRequest(policy: invalid))
        ) { XCTAssertEqual($0 as? CaptureLocationMetadataError, .invalidOutputKey("bad: key")) }
    }

    func test_advancedTemplateRendersBoundedNestedMappingAndListItem() throws {
        let policy = CapturePresetLocationPolicy(
            isEnabled: true,
            outputMode: .advancedTemplate,
            collectionKey: "capture_locations",
            advancedTemplate: """
            - place: {{place}}
              address:
                city: {{city}}
                region: {{region}}
              providers:
                - apple: {{appleMapsURL}}
                - osm: {{openStreetMapURL}}
            """
        )
        let rendered = try XCTUnwrap(
            CaptureLocationMetadataRenderer().render(request: makeRequest(policy: policy))
        )

        XCTAssertEqual(rendered.collectionKey, "capture_locations")
        XCTAssertEqual(rendered.itemLines[1], "place: \"Café & Main\"")
        XCTAssertTrue(rendered.itemLines.contains("address:"))
        XCTAssertTrue(rendered.itemLines.contains("  city: \"Montréal\""))
        XCTAssertTrue(rendered.itemLines.contains("  region: \"Québec\""))
        XCTAssertTrue(rendered.itemLines.contains("  -"))
        XCTAssertTrue(rendered.itemLines.contains { $0.contains("apple: \"https://maps.apple.com/") })
        var parser = try CaptureLocationConstrainedYAMLParser(
            source: rendered.itemLines.joined(separator: "\n"),
            maximumDepth: CaptureLocationMetadataRenderer.maximumNestingDepth
        )
        guard case .mapping = try parser.parse() else { return XCTFail("Expected mapping YAML") }
        XCTAssertLessThan(rendered.itemLines.joined().utf8.count, CaptureLocationMetadataRenderer.maximumOutputUTF8Bytes)
    }

    func test_advancedTemplateRejectsCollisionsUnsafeYAMLUnknownFieldsAndBounds() throws {
        let templates: [(String, CaptureLocationMetadataError)] = [
            ("id: {{id}}", .reservedFieldCollision("id")),
            ("place: &anchor unsafe", .unsafeTemplate(1)),
            ("place: {{unknown}}", .unknownTemplateField("unknown", line: 1)),
            ("city: {{city}}\ncity: {{city}}", .duplicateTemplateKey("city", 2)),
            ("place: {{place}} suffix", .invalidTemplateLine(1)),
            ("parent:\ncity: {{city}}", .invalidTemplateLine(1)),
            ("parent:\n    city: {{city}}", .invalidTemplateLine(1)),
        ]
        for (template, expected) in templates {
            let request = makeRequest(policy: CapturePresetLocationPolicy(
                isEnabled: true,
                outputMode: .advancedTemplate,
                advancedTemplate: template
            ))
            XCTAssertThrowsError(try CaptureLocationMetadataRenderer().render(request: request)) {
                XCTAssertEqual($0 as? CaptureLocationMetadataError, expected)
            }
        }

        let oversized = String(repeating: "x", count: CaptureLocationMetadataRenderer.maximumTemplateUTF8Bytes + 1)
        XCTAssertThrowsError(try CaptureLocationMetadataRenderer().render(request: makeRequest(
            policy: CapturePresetLocationPolicy(
                isEnabled: true,
                outputMode: .advancedTemplate,
                advancedTemplate: oversized
            )
        ))) { XCTAssertEqual($0 as? CaptureLocationMetadataError, .templateTooLarge) }
        XCTAssertThrowsError(try CaptureLocationMetadataRenderer().render(request: makeRequest(
            policy: CapturePresetLocationPolicy(isEnabled: true, collectionKey: "bad: key")
        ))) { XCTAssertEqual($0 as? CaptureLocationMetadataError, .invalidCollectionKey("bad: key")) }

        let oversizedLabel = CaptureLocationSnapshot(
            latitude: 1,
            longitude: 2,
            timestamp: timestamp,
            source: .app,
            precision: .exact,
            label: CaptureLocationLabel(place: String(repeating: "p", count: 17_000))
        )
        XCTAssertThrowsError(try CaptureLocationMetadataRenderer().render(request: makeRequest(
            policy: CapturePresetLocationPolicy(isEnabled: true, structuredFields: [.place]),
            snapshot: oversizedLabel
        ))) { XCTAssertEqual($0 as? CaptureLocationMetadataError, .outputTooLarge) }
    }

    func test_advancedOptionalLabelsAndListPlaceholdersOmitEmptyContainersSafely() throws {
        let policy = CapturePresetLocationPolicy(
            isEnabled: true,
            outputMode: .advancedTemplate,
            advancedTemplate: """
            labels:
              - {{place}}
              - {{city}}
            address:
              region: {{region}}
              country: {{country}}
            coordinates: {{coordinates}}
            """
        )
        let noLabels = CaptureLocationSnapshot(
            latitude: 1,
            longitude: 2,
            timestamp: timestamp,
            source: .app,
            precision: .exact
        )
        let rendered = try XCTUnwrap(CaptureLocationMetadataRenderer().render(
            request: makeRequest(policy: policy, snapshot: noLabels)
        ))
        XCTAssertFalse(rendered.itemLines.contains { $0.contains("labels") || $0.contains("address") })
        XCTAssertTrue(rendered.itemLines.contains("coordinates: [1.000000, 2.000000]"))
        var parser = try CaptureLocationConstrainedYAMLParser(
            source: rendered.itemLines.joined(separator: "\n"),
            maximumDepth: CaptureLocationMetadataRenderer.maximumNestingDepth
        )
        guard case .mapping = try parser.parse() else { return XCTFail("Expected mapping YAML") }
    }

    func test_advancedTemplateEntryScopeIsRejectedWithoutFlattening() throws {
        var request = makeRequest(policy: CapturePresetLocationPolicy(
            isEnabled: true,
            outputMode: .advancedTemplate,
            advancedTemplate: "nested:\n  city: {{city}}"
        ))
        request.voxProfile?.metadataScope = .entry
        XCTAssertThrowsError(try CaptureLocationMetadataRenderer().render(request: request)) {
            XCTAssertEqual($0 as? CaptureLocationMetadataError, .advancedTemplateRequiresDocumentScope)
        }
        let destination = CaptureDestination(
            name: "Rolling",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Daily.md")
        )
        XCTAssertThrowsError(try CaptureMarkdownRenderer().render(request, for: destination)) {
            XCTAssertEqual($0 as? CaptureLocationMetadataError, .advancedTemplateRequiresDocumentScope)
        }
    }

    func test_unavailableDisabledAndTokenOnlyPoliciesDoNotRenderMetadata() throws {
        var disabled = makeRequest(policy: CapturePresetLocationPolicy(isEnabled: false))
        XCTAssertNil(try CaptureLocationMetadataRenderer().render(request: disabled))
        disabled.voxProfile?.locationPolicy.isEnabled = true
        disabled.locationOutcome = .unavailable(.permissionDenied, attemptedAt: timestamp)
        XCTAssertNil(try CaptureLocationMetadataRenderer().render(request: disabled))

        let tokenOnly = makeRequest(policy: CapturePresetLocationPolicy(
            isEnabled: true,
            metadataOutputEnabled: false
        ))
        XCTAssertNil(try CaptureLocationMetadataRenderer().render(request: tokenOnly))
        XCTAssertTrue(
            CaptureEntryTemplateRenderer().render("{location}", for: tokenOnly)
                .contains("https://www.google.com/maps/search/")
        )
    }

    func test_locationPolicyOutcomeAndSnapshotRoundTripWhileLegacyDefaultsDisabled() throws {
        let request = makeRequest(policy: CapturePresetLocationPolicy(
            isEnabled: true,
            precision: .city,
            unavailableBehavior: .sendWithoutLocation,
            outputMode: .advancedTemplate,
            structuredFields: [
                CaptureLocationStructuredField(field: .city, outputKey: "locality"),
                CaptureLocationStructuredField(field: .geoURI, outputKey: "geo_link"),
            ],
            collectionKey: "visits",
            advancedTemplate: "city: {{city}}"
        ))
        let decoded = try JSONDecoder().decode(CaptureRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
        var unavailableRequest = request
        unavailableRequest.locationOutcome = .unavailable(.timeout, attemptedAt: timestamp)
        let unavailableData = try JSONEncoder().encode(unavailableRequest)
        XCTAssertTrue(try XCTUnwrap(String(data: unavailableData, encoding: .utf8)).contains("attemptedAt"))
        XCTAssertEqual(
            try JSONDecoder().decode(CaptureRequest.self, from: unavailableData).locationOutcome,
            .unavailable(.timeout, attemptedAt: timestamp)
        )

        let legacyOutcome = try JSONDecoder().decode(
            CaptureLocationOutcome.self,
            from: Data("{\"kind\":\"unavailable\",\"reason\":\"timeout\"}".utf8)
        )
        XCTAssertEqual(
            legacyOutcome,
            .unavailable(.timeout, attemptedAt: CaptureLocationOutcome.legacyUnknownAttemptedAt)
        )

        let legacyPolicy = try JSONDecoder().decode(
            CapturePresetLocationPolicy.self,
            from: Data("{\"structuredFields\":[\"city\",\"geoURI\"]}".utf8)
        )
        XCTAssertEqual(legacyPolicy.structuredFields, [.city, .geoURI])
        XCTAssertFalse(legacyPolicy.metadataOutputEnabled)

        let legacyProfile = try JSONDecoder().decode(
            CapturePresetProfile.self,
            from: Data("{\"id\":\"legacy\",\"name\":\"Legacy\"}".utf8)
        )
        XCTAssertFalse(legacyProfile.locationPolicy.isEnabled)
        XCTAssertFalse(legacyProfile.locationPolicy.metadataOutputEnabled)
        XCTAssertEqual(legacyProfile.locationPolicy.precision, .exact)

        let encoded = try JSONEncoder().encode(request)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "locationOutcome")
        let legacyRequest = try JSONDecoder().decode(
            CaptureRequest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacyRequest.locationOutcome)
    }

    func test_frontmatterCollectionAppendPreservesContentAndIsIdempotentByRequestID() throws {
        let metadata = try XCTUnwrap(CaptureLocationMetadataRenderer().render(request: makeRequest()))
        let mutation = MarkdownCaptureMutation(
            requestID: requestID,
            entry: "New entry",
            placement: .append,
            locationMetadata: metadata
        )
        let document = """
        ---
        title: User owned
        # retain this comment
        locations:
          - id: "11111111-2222-3333-4444-555555555555"
            city: "Old city"
        aliases: [inbox]
        ---

        Existing
        """

        let once = try MarkdownDocumentEditor().applying(mutation, to: document)
        let twice = try MarkdownDocumentEditor().applying(mutation, to: once)

        XCTAssertEqual(twice, once)
        XCTAssertTrue(once.contains("# retain this comment"))
        XCTAssertTrue(once.contains("aliases: [inbox]"))
        XCTAssertTrue(once.contains("  - id: \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\""))
        XCTAssertEqual(once.components(separatedBy: "New entry").count - 1, 1)
    }

    func test_frontmatterCollectionRecognizesQuotedIDsAndRejectsMappingsOrMalformedLists() throws {
        let metadata = try XCTUnwrap(CaptureLocationMetadataRenderer().render(request: makeRequest()))
        let mutation = MarkdownCaptureMutation(
            requestID: requestID,
            entry: "Must not duplicate",
            placement: .append,
            locationMetadata: metadata
        )
        for quotedID in [
            "'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'",
            "\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\"",
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        ] {
            let document = "---\nlocations:\n  - id: \(quotedID)\n    city: Old\n---\n\nExisting"
            XCTAssertEqual(try MarkdownDocumentEditor().applying(mutation, to: document), document)
        }

        let collisions = [
            "---\nlocations:\n  home: Montréal\n---\n\nExisting",
            "---\nlocations:\n - id: \"11111111-2222-3333-4444-555555555555\"\n---\n\nExisting",
            "---\nlocations:\n  - city: Montréal\n---\n\nExisting",
            "---\nlocations: []\n  - id: \"11111111-2222-3333-4444-555555555555\"\n---\n\nExisting",
        ]
        for document in collisions {
            XCTAssertThrowsError(try MarkdownDocumentEditor().applying(mutation, to: document)) {
                XCTAssertEqual($0 as? CaptureLocationMetadataError, .frontmatterCollision("locations"))
            }
        }
    }

    func test_frontmatterCollectionRejectsScalarCollisionWithoutMutatingInput() throws {
        let metadata = try XCTUnwrap(CaptureLocationMetadataRenderer().render(request: makeRequest()))
        let document = "---\nlocations: user-authored\ntitle: Keep\n---\n\nExisting"
        XCTAssertThrowsError(try MarkdownDocumentEditor().applying(
            MarkdownCaptureMutation(
                requestID: requestID,
                entry: "New",
                placement: .append,
                locationMetadata: metadata
            ),
            to: document
        )) { XCTAssertEqual($0 as? CaptureLocationMetadataError, .frontmatterCollision("locations")) }
        XCTAssertEqual(document, "---\nlocations: user-authored\ntitle: Keep\n---\n\nExisting")
    }

    func test_staticFrontmatterCollectionCollisionFailsDuringPreviewEquivalentMerge() throws {
        let metadata = try XCTUnwrap(CaptureLocationMetadataRenderer().render(request: makeRequest()))
        XCTAssertThrowsError(try MarkdownDocumentEditor().applying(
            MarkdownCaptureMutation(
                requestID: metadata.requestID,
                entry: "Preview",
                placement: .append,
                frontmatter: ["locations": "not-a-list"],
                locationMetadata: metadata
            ),
            to: ""
        )) {
            XCTAssertEqual($0 as? CaptureLocationMetadataError, .frontmatterCollision("locations"))
        }
    }

    func test_entryScopeRendersInlineLocationAdjacentToEntryWithoutFrontmatter() throws {
        var request = makeRequest()
        request.voxProfile?.metadataScope = .entry
        let destination = CaptureDestination(
            name: "Rolling",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Daily.md")
        )

        let markdown = try CaptureMarkdownRenderer().render(request, for: destination)

        XCTAssertTrue(markdown.hasPrefix("location.id:: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n"))
        XCTAssertTrue(markdown.contains("location.coordinates:: [45.501235, -73.567890]"))
        XCTAssertTrue(markdown.hasSuffix("Captured text"))
        XCTAssertFalse(markdown.contains("locations:"))
    }

    private func snapshot() -> CaptureLocationSnapshot {
        CaptureLocationSnapshot(
            latitude: 45.50123456,
            longitude: -73.56789,
            horizontalAccuracy: 12.34,
            timestamp: timestamp,
            source: .shareExtension,
            precision: .exact,
            label: CaptureLocationLabel(
                place: "Café & Main",
                city: "Montréal",
                region: "Québec",
                country: "Canada"
            )
        )
    }

    private func makeRequest(
        policy: CapturePresetLocationPolicy = CapturePresetLocationPolicy(isEnabled: true),
        snapshot: CaptureLocationSnapshot? = nil
    ) -> CaptureRequest {
        CaptureRequest(
            id: requestID,
            createdAt: timestamp,
            source: .shareExtension,
            destinationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            payloads: [.text("Captured text")],
            voxProfile: CapturePresetProfile(
                id: "travel",
                name: "Travel",
                symbolName: "location",
                locationPolicy: policy
            ),
            locationOutcome: .available(snapshot ?? self.snapshot())
        )
    }
}
