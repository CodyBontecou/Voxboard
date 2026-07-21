import Foundation

struct InspirationQuote: Codable, Equatable, Sendable {
    let text: String
    let author: String

    nonisolated static let fallback = InspirationQuote(
        text: "Do what you can, with what you have, where you are.",
        author: "Theodore Roosevelt"
    )
}

actor InspirationQuoteService {
    static let shared = InspirationQuoteService()

    private struct ZenQuote: Decodable {
        let q: String
        let a: String
    }

    private struct QuoteCache: Codable {
        var quotes: [InspirationQuote]
        var fetchedAt: Date
        var nextIndex: Int
    }

    private enum ServiceError: Error {
        case invalidResponse
        case noUsableQuotes
    }

    private static let cacheKey = "inspiration-quotes.zenquotes.v1"
    private static let refreshInterval: TimeInterval = 2 * 60 * 60
    private static let endpoint = URL(string: "https://zenquotes.io/api/quotes")!

    private let session: URLSession
    private let defaults: UserDefaults
    private var memoryCache: QuoteCache?

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.defaults = defaults
    }

    /// Returns the next locally cached quote. ZenQuotes recommends fetching a
    /// batch and rotating through it for a few hours rather than requesting a
    /// new quote on every appearance.
    func nextQuote() async -> InspirationQuote {
        let now = Date()
        var cache = loadCache()

        if shouldRefresh(cache, now: now) {
            do {
                cache = QuoteCache(
                    quotes: try await fetchQuotes(),
                    fetchedAt: now,
                    nextIndex: 0
                )
            } catch {
                // Keep serving an older cached batch when the device is offline
                // or the free API is temporarily unavailable.
            }
        }

        guard var cache, !cache.quotes.isEmpty else {
            return .fallback
        }

        let index = max(0, cache.nextIndex) % cache.quotes.count
        let quote = cache.quotes[index]
        cache.nextIndex = (index + 1) % cache.quotes.count
        saveCache(cache)
        return quote
    }

    private func shouldRefresh(_ cache: QuoteCache?, now: Date) -> Bool {
        guard let cache else { return true }
        let age = now.timeIntervalSince(cache.fetchedAt)
        return age < 0 || age >= Self.refreshInterval
    }

    private func loadCache() -> QuoteCache? {
        if let memoryCache { return memoryCache }
        guard let data = defaults.data(forKey: Self.cacheKey),
              let cache = try? JSONDecoder().decode(QuoteCache.self, from: data),
              !cache.quotes.isEmpty else { return nil }
        memoryCache = cache
        return cache
    }

    private func saveCache(_ cache: QuoteCache) {
        memoryCache = cache
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }

    private func fetchQuotes() async throws -> [InspirationQuote] {
        var request = URLRequest(
            url: Self.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw ServiceError.invalidResponse
        }

        let responses = try JSONDecoder().decode([ZenQuote].self, from: data)
        let quotes: [InspirationQuote] = responses.compactMap { response -> InspirationQuote? in
            let text = response.q.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = response.a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 280, !author.isEmpty else { return nil }
            return InspirationQuote(text: text, author: author)
        }

        guard !quotes.isEmpty else { throw ServiceError.noUsableQuotes }
        return quotes
    }
}
