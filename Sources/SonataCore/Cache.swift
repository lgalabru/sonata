import Foundation

/// A value plus the time it was fetched, so callers can apply their own TTL.
public struct Stamped<Value: Codable & Sendable>: Codable, Sendable {
    public let fetchedAt: Date
    public let value: Value

    public init(_ value: Value, fetchedAt: Date = Date()) {
        self.value = value
        self.fetchedAt = fetchedAt
    }

    public func isFresh(ttl: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) < ttl
    }
}

/// JSON files under ~/Library/Caches/sonata, one per dataset (and per cluster).
public struct DiskCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The default cache directory, namespaced by RPC host so mainnet and devnet never mix.
    public static func forEndpoint(_ endpoint: URL) -> DiskCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let host = (endpoint.host ?? "rpc").replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "_", options: .regularExpression)
        return DiskCache(directory: base.appendingPathComponent("sonata", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true))
    }

    /// Shared across clusters: an IP's location doesn't depend on the RPC.
    public static var shared: DiskCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return DiskCache(directory: base.appendingPathComponent("sonata", isDirectory: true))
    }

    public func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    public func read<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    public func write<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    public func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }

    public func files(prefix: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }
    }

    public func clear() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            try? FileManager.default.removeItem(at: url(name))
        }
    }

    // MARK: Leader schedules

    static func scheduleName(_ epoch: UInt64) -> String { "schedule-\(epoch).json" }

    public func schedule(epoch: UInt64) -> LeaderSchedule? { read(Self.scheduleName(epoch)) }

    public func store(_ schedule: LeaderSchedule) {
        write(schedule, to: Self.scheduleName(schedule.epoch))
        // Keep only the most recent few epochs.
        let epochs = files(prefix: "schedule-").compactMap {
            UInt64($0.dropFirst("schedule-".count).dropLast(".json".count))
        }.sorted(by: >)
        for old in epochs.dropFirst(3) { remove(Self.scheduleName(old)) }
    }
}
