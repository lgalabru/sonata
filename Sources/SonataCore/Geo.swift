import Foundation

public struct GeoPoint: Codable, Sendable, Equatable {
    public let lat: Double
    public let lon: Double
    public let city: String?
    public let countryCode: String?

    public init(lat: Double, lon: Double, city: String? = nil, countryCode: String? = nil) {
        self.lat = lat
        self.lon = lon
        self.city = city
        self.countryCode = countryCode
    }

    /// Regional-indicator flag emoji for the country code, e.g. "DE" → 🇩🇪.
    public var flag: String {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return "" }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(127_397 + $0.value) }))
    }

    public var place: String {
        [city, countryCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// IP geolocation backed by ip-api.com's batch endpoint, with a persistent cache.
/// Free tier: 15 batch requests/minute, 100 IPs each, HTTP only.
public actor GeoLocator {
    struct Entry: Codable {
        let point: GeoPoint?  // nil = lookup failed (private/reserved address)
        let fetchedAt: Date
    }

    private var entries: [String: Entry]
    private let cache: DiskCache
    private let session: URLSession
    static let fileName = "geo.json"
    static let ttl: TimeInterval = 30 * 86_400
    static let failureTTL: TimeInterval = 86_400

    public init(cache: DiskCache = .shared, session: URLSession = .shared) {
        self.cache = cache
        self.session = session
        self.entries = cache.read(Self.fileName, as: [String: Entry].self) ?? [:]
    }

    /// Cached locations only, without touching the network.
    public func cached(_ ips: some Sequence<String>) -> [String: GeoPoint] {
        var out: [String: GeoPoint] = [:]
        for ip in ips { if let point = entries[ip]?.point { out[ip] = point } }
        return out
    }

    /// Resolves every IP it can, fetching only the ones missing or expired.
    /// `progress` is called with what is known so far after each batch.
    public func locate(_ ips: [String], progress: (@Sendable ([String: GeoPoint]) async -> Void)? = nil) async -> [String: GeoPoint] {
        let now = Date()
        let missing = Array(Set(ips)).filter { ip in
            guard let entry = entries[ip] else { return true }
            return now.timeIntervalSince(entry.fetchedAt) > (entry.point == nil ? Self.failureTTL : Self.ttl)
        }.sorted()
        for start in stride(from: 0, to: missing.count, by: 100) {
            let batch = Array(missing[start..<min(start + 100, missing.count)])
            guard await fetch(batch) else { break }
            cache.write(entries, to: Self.fileName)
            await progress?(cached(ips))
        }
        return cached(ips)
    }

    struct Response: Decodable {
        let status: String
        let query: String
        let lat: Double?
        let lon: Double?
        let city: String?
        let countryCode: String?
    }

    /// Returns false when rate limited or offline, so the caller stops for now.
    private func fetch(_ batch: [String]) async -> Bool {
        guard let url = URL(string: "http://ip-api.com/batch?fields=status,query,lat,lon,city,countryCode"),
              let body = try? JSONEncoder().encode(batch) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 429 { return false }
            let results = try JSONDecoder().decode([Response].self, from: data)
            let now = Date()
            for r in results {
                if r.status == "success", let lat = r.lat, let lon = r.lon {
                    entries[r.query] = Entry(point: GeoPoint(lat: lat, lon: lon, city: r.city, countryCode: r.countryCode), fetchedAt: now)
                } else {
                    entries[r.query] = Entry(point: nil, fetchedAt: now)
                }
            }
            // X-Rl: requests left in the window, X-Ttl: seconds until it resets.
            if let left = http?.value(forHTTPHeaderField: "X-Rl").flatMap(Int.init), left <= 1 {
                let wait = http?.value(forHTTPHeaderField: "X-Ttl").flatMap(Double.init) ?? 60
                try await Task.sleep(for: .seconds(wait + 1))
            }
            return true
        } catch {
            return false
        }
    }

    public func clear() {
        entries = [:]
        cache.remove(Self.fileName)
    }
}
