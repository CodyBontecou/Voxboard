import Foundation

/// The interface language for the main app, selectable in Settings.
///
/// `system` follows the device's preferred-language list. Every other case
/// pins Vox.md to one of its fully localized languages regardless of system
/// settings — for example, an English interface on a German phone.
///
/// Cases are ordered alphabetically by English name so the picker reads
/// predictably; `system` stays first as the default.
public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case system
    case arabic = "ar"
    case bengali = "bn"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case dutch = "nl"
    case english = "en"
    case french = "fr"
    case german = "de"
    case hindi = "hi"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case polish = "pl"
    case portugueseBrazil = "pt-BR"
    case russian = "ru"
    case spanish = "es"
    case tamil = "ta"
    case thai = "th"
    case turkish = "tr"
    case ukrainian = "uk"
    case urdu = "ur"
    case vietnamese = "vi"

    public var id: String { rawValue }

    /// The BCP-47 code written to `AppleLanguages`, or `nil` when following
    /// the system language.
    public var languageCode: String? {
        self == .system ? nil : rawValue
    }

    /// The language's own name for itself, always rendered in its native
    /// script (for example "Deutsch", "日本語"). Never localized so the
    /// picker stays legible regardless of the active interface language.
    public var nativeDisplayName: String {
        switch self {
        case .system: "System"
        case .arabic: "العربية"
        case .bengali: "বাংলা"
        case .chineseSimplified: "简体中文"
        case .chineseTraditional: "繁體中文"
        case .dutch: "Nederlands"
        case .english: "English"
        case .french: "Français"
        case .german: "Deutsch"
        case .hindi: "हिन्दी"
        case .indonesian: "Bahasa Indonesia"
        case .italian: "Italiano"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .polish: "Polski"
        case .portugueseBrazil: "Português (Brasil)"
        case .russian: "Русский"
        case .spanish: "Español"
        case .tamil: "தமிழ்"
        case .thai: "ไทย"
        case .turkish: "Türkçe"
        case .ukrainian: "Українська"
        case .urdu: "اردو"
        case .vietnamese: "Tiếng Việt"
        }
    }
    /// Resolve the app language best matching a language identifier such as
    /// "de-DE" or "zh-Hans-CN". Exact matches win; otherwise the longest
    /// shared prefix wins, so "zh-Hans-SG" resolves to Simplified Chinese.
    public static func matching(languageIdentifier identifier: String) -> AppLanguage? {
        if let exact = AppLanguage(rawValue: identifier) { return exact }
        return AppLanguage.allCases
            .filter { identifier.hasPrefix($0.rawValue) }
            .max { $0.rawValue.count < $1.rawValue.count }
    }
}

/// Reads and persists the in-app language override.
///
/// The override itself lives in the shared App Group defaults so every
/// process can observe it. The app process additionally mirrors the choice
/// into `AppleLanguages` on its standard defaults — the supported mechanism
/// iOS uses to resolve which `.lproj` the main bundle loads at launch.
/// Because `Bundle.main` caches its resolved localization, a language change
/// takes effect the next time the app opens.
public enum AppLanguagePreference {
    /// The `AppleLanguages` key resolved by the system at launch.
    private static let appleLanguagesKey = "AppleLanguages"

    /// The stored override; `.system` when unset or unreadable.
    public static func current(defaults: UserDefaults? = AppConstants.sharedDefaults) -> AppLanguage {
        guard let raw = defaults?.string(forKey: AppConstants.appLanguageOverrideKey),
              let language = AppLanguage(rawValue: raw)
        else { return .system }
        return language
    }

    /// Persist the selection and mirror it into `AppleLanguages` so the next
    /// launch resolves the matching localization.
    public static func set(
        _ language: AppLanguage,
        defaults: UserDefaults? = AppConstants.sharedDefaults,
        standardDefaults: UserDefaults = .standard
    ) {
        if let code = language.languageCode {
            defaults?.set(code, forKey: AppConstants.appLanguageOverrideKey)
        } else {
            defaults?.removeObject(forKey: AppConstants.appLanguageOverrideKey)
        }
        applyAppleLanguages(for: language, to: standardDefaults)
    }

    /// Reconcile `AppleLanguages` with the stored override early at launch,
    /// before any view resolves localized strings. Idempotent; also repairs
    /// drift if the standard defaults lost the override between sessions.
    public static func applyAtLaunch(
        defaults: UserDefaults? = AppConstants.sharedDefaults,
        standardDefaults: UserDefaults = .standard
    ) {
        applyAppleLanguages(for: current(defaults: defaults), to: standardDefaults)
    }

    /// Point `AppleLanguages` at the selected language, or clear the key so
    /// the system preferred-language list wins again.
    private static func applyAppleLanguages(
        for language: AppLanguage,
        to standardDefaults: UserDefaults
    ) {
        if let code = language.languageCode {
            standardDefaults.set([code], forKey: appleLanguagesKey)
        } else {
            standardDefaults.removeObject(forKey: appleLanguagesKey)
        }
    }
}
