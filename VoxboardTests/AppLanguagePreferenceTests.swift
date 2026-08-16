import XCTest
@testable import VoxboardShared

final class AppLanguagePreferenceTests: XCTestCase {
    private var sharedSuiteName: String!
    private var standardSuiteName: String!
    private var sharedDefaults: UserDefaults!
    private var standardDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        sharedSuiteName = "app-language-tests-shared-\(UUID().uuidString)"
        standardSuiteName = "app-language-tests-standard-\(UUID().uuidString)"
        sharedDefaults = UserDefaults(suiteName: sharedSuiteName)
        standardDefaults = UserDefaults(suiteName: standardSuiteName)
    }

    override func tearDown() {
        sharedDefaults.removePersistentDomain(forName: sharedSuiteName)
        standardDefaults.removePersistentDomain(forName: standardSuiteName)
        sharedDefaults = nil
        standardDefaults = nil
        super.tearDown()
    }

    /// `AppleLanguages` also resolves from the global domain (the system
    /// language list), so `object(forKey:)` stays non-nil even after the
    /// override is removed — mirrors production. Inspect the suite's own
    /// persistent domain to assert whether an override is actually stored.
    private func storedAppleLanguages(in defaults: UserDefaults, suiteName: String) -> Any? {
        defaults.persistentDomain(forName: suiteName)?["AppleLanguages"]
    }

    // MARK: - Catalog integrity

    func test_everyLanguageHasUniqueCodeAndNativeName() {
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.rawValue)).count, AppLanguage.allCases.count)
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.nativeDisplayName)).count, AppLanguage.allCases.count)
    }

    func test_languageCodeIsNilOnlyForSystem() {
        for language in AppLanguage.allCases {
            XCTAssertEqual(language.languageCode == nil, language == .system)
        }
    }

    func test_supportedLanguagesMatchRuntimeLocalizations() {
        // Every non-system language must be one of the app's localized
        // runtime languages (source language included).
        let expected: Set<String> = [
            "ar", "bn", "de", "en", "es", "fr", "hi", "id", "it", "ja",
            "ko", "nl", "pl", "pt-BR", "ru", "ta", "th", "tr", "uk", "ur",
            "vi", "zh-Hans", "zh-Hant",
        ]
        let codes = Set(AppLanguage.allCases.compactMap(\.languageCode))
        XCTAssertEqual(codes, expected)
    }

    // MARK: - Language identifier matching

    func test_matchingResolvesRegionalVariants() {
        XCTAssertEqual(AppLanguage.matching(languageIdentifier: "de-DE"), .german)
        XCTAssertEqual(AppLanguage.matching(languageIdentifier: "en-US"), .english)
        XCTAssertEqual(AppLanguage.matching(languageIdentifier: "zh-Hans-CN"), .chineseSimplified)
        XCTAssertEqual(AppLanguage.matching(languageIdentifier: "zh-Hant-TW"), .chineseTraditional)
        XCTAssertEqual(AppLanguage.matching(languageIdentifier: "pt-BR"), .portugueseBrazil)
        XCTAssertEqual(AppLanguage.matching(languageIdentifier: "pt-PT"), nil)
        XCTAssertEqual(AppLanguage.matching(languageIdentifier: "sv-SE"), nil)
    }

    // MARK: - Preference persistence

    func test_currentDefaultsToSystemWhenUnset() {
        XCTAssertEqual(AppLanguagePreference.current(defaults: sharedDefaults), .system)
    }

    func test_currentFallsBackToSystemForUnknownCode() {
        sharedDefaults.set("klingon", forKey: AppConstants.appLanguageOverrideKey)

        XCTAssertEqual(AppLanguagePreference.current(defaults: sharedDefaults), .system)
    }

    func test_setPersistsOverrideAndMirrorsAppleLanguages() {
        AppLanguagePreference.set(.english, defaults: sharedDefaults, standardDefaults: standardDefaults)

        XCTAssertEqual(sharedDefaults.string(forKey: AppConstants.appLanguageOverrideKey), "en")
        XCTAssertEqual(standardDefaults.stringArray(forKey: "AppleLanguages"), ["en"])
    }

    func test_selectingSystemStoresExplicitChoiceAndClearsAppleLanguages() {
        AppLanguagePreference.set(.german, defaults: sharedDefaults, standardDefaults: standardDefaults)
        AppLanguagePreference.set(.system, defaults: sharedDefaults, standardDefaults: standardDefaults)

        XCTAssertEqual(sharedDefaults.string(forKey: AppConstants.appLanguageOverrideKey), "system")
        XCTAssertEqual(AppLanguagePreference.current(defaults: sharedDefaults), .system)
        XCTAssertNil(storedAppleLanguages(in: standardDefaults, suiteName: standardSuiteName))
    }

    func test_launchReconcileRepairsDroppedAppleLanguagesMirror() {
        // User picked German earlier; something cleared the mirrored key.
        sharedDefaults.set("de", forKey: AppConstants.appLanguageOverrideKey)

        AppLanguagePreference.applyAtLaunch(defaults: sharedDefaults, standardDefaults: standardDefaults)

        XCTAssertEqual(standardDefaults.stringArray(forKey: "AppleLanguages"), ["de"])
    }

    func test_launchReconcilePreservesAppleLanguagesWhenNoPreferenceExists() {
        // The upgrade scenario: the user never chose an in-app language but
        // already picked a per-app language in iOS Settings. Absence must not
        // delete their OS-level override.
        standardDefaults.set(["en"], forKey: "AppleLanguages")

        AppLanguagePreference.applyAtLaunch(defaults: sharedDefaults, standardDefaults: standardDefaults)

        XCTAssertEqual(standardDefaults.stringArray(forKey: "AppleLanguages"), ["en"])
    }

    func test_launchReconcilePreservesAppleLanguagesForUnreadablePreference() {
        sharedDefaults.set("klingon", forKey: AppConstants.appLanguageOverrideKey)
        standardDefaults.set(["en"], forKey: "AppleLanguages")

        AppLanguagePreference.applyAtLaunch(defaults: sharedDefaults, standardDefaults: standardDefaults)

        XCTAssertEqual(standardDefaults.stringArray(forKey: "AppleLanguages"), ["en"])
    }

    func test_launchReconcileClearsStaleMirrorForExplicitSystemSelection() {
        // The user explicitly chose Use System Language in-app; a leftover
        // mirror from a previous concrete choice must be cleared.
        sharedDefaults.set("system", forKey: AppConstants.appLanguageOverrideKey)
        standardDefaults.set(["fr"], forKey: "AppleLanguages")

        AppLanguagePreference.applyAtLaunch(defaults: sharedDefaults, standardDefaults: standardDefaults)

        XCTAssertNil(storedAppleLanguages(in: standardDefaults, suiteName: standardSuiteName))
    }
}
