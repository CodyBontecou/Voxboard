import KeyboardKit

enum CalloutActionsProvider {

    static func actions(
        for action: KeyboardAction,
        languageCode: String
    ) -> [KeyboardAction]? {
        guard case let .character(char) = action else { return nil }
        guard let dict = characterMap(for: languageCode) else { return nil }
        let key = char.lowercased()
        guard let alternates = dict[key] else { return nil }

        let isUppercase = char.first.map { $0.isUppercase && $0.isLetter } ?? false

        let chars = alternates.map(String.init)
        let cased: [String] = isUppercase
            ? chars.compactMap { c in
                let upper = c.uppercased()
                return upper.count == 1 ? upper : nil
            }
            : chars

        guard !cased.isEmpty else { return nil }
        return cased.map { .character($0) }
    }

    private static func characterMap(for code: String) -> [String: String]? {
        switch code {
        case "de": return german
        case "es": return spanish
        case "fr": return french
        case "it": return italian
        case "pt": return portuguese
        case "nl": return dutch
        case "sv": return swedish
        case "da": return danish
        case "no": return norwegian
        case "en": return english
        default:   return nil
        }
    }

    private static let english: [String: String] = [
        "a": "àáâäæãåā",
        "c": "çćč",
        "e": "èéêëēėę",
        "i": "îïíīįì",
        "l": "ł",
        "n": "ñń",
        "o": "ôöòóœøōõ",
        "s": "ßśš",
        "u": "ûüùúū",
        "y": "ÿ",
        "z": "žźż",
    ]

    private static let german: [String: String] = [
        "a": "äàáâæãåā",
        "c": "ç",
        "e": "èéêëēėę",
        "i": "îïíīįì",
        "n": "ñ",
        "o": "öôòóœøõō",
        "s": "ß",
        "u": "üùúûū",
    ]

    private static let spanish: [String: String] = [
        "a": "áàâäãåāæ",
        "e": "éèêëēęė",
        "i": "íîïìīį",
        "n": "ñń",
        "o": "óôöòõōøœ",
        "u": "úûüùū",
        "!": "¡",
        "?": "¿",
    ]

    private static let french: [String: String] = [
        "a": "àáâäæãåā",
        "c": "ç",
        "e": "éèêëēėę",
        "i": "îïìíīį",
        "o": "ôœöòóõøō",
        "u": "ùûüúū",
        "y": "ÿ",
    ]

    private static let italian: [String: String] = [
        "a": "àáâäæãåā",
        "e": "èéêëēėę",
        "i": "ìíîïīį",
        "o": "òóôöõōøœ",
        "u": "ùúûüū",
    ]

    private static let portuguese: [String: String] = [
        "a": "áâãàäåāæ",
        "c": "ç",
        "e": "éêèëēęė",
        "i": "íîìïīį",
        "o": "óôõòöōøœ",
        "u": "úûüùū",
    ]

    private static let dutch: [String: String] = [
        "a": "áàâäãåāæ",
        "e": "éèêëēęė",
        "i": "íîïìīį",
        "o": "óòôöõōøœ",
        "u": "úûüùū",
    ]

    private static let swedish: [String: String] = [
        "a": "åäáàâæãā",
        "e": "éèêëēęė",
        "o": "öóòôõōøœ",
        "u": "üúûùū",
    ]

    private static let danish: [String: String] = [
        "a": "åæáàâäãā",
        "e": "éèêëēęė",
        "o": "øóòôöõōœ",
        "u": "úûüùū",
    ]

    private static let norwegian: [String: String] = [
        "a": "åæáàâäãā",
        "e": "éèêëēęė",
        "o": "øóòôöõōœ",
        "u": "úûüùū",
    ]
}
