import Foundation

/// A JSON value for RPC parameters, written with literals: `[.int(slot), ["encoding": "base64"]]`.
public indirect enum JSONValue: Encodable, Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func int(_ value: some BinaryInteger) -> JSONValue { .integer(Int64(value)) }

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public init(nilLiteral: ()) { self = .null }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// What a JSON-RPC call can fail with.
public enum RPCError: Error, LocalizedError, Sendable, Equatable {
    /// A non-2xx HTTP status; 429 is the public endpoints' rate limit.
    case http(status: Int, retryAfter: Double?)
    /// An error object from the node.
    case rpc(code: Int, message: String)
    /// A response with neither result nor error.
    case noResult(method: String)

    /// Node error codes Sonata cares about.
    public static let blockNotAvailable = -32004
    public static let slotSkipped = -32007
    public static let longTermStorageSlotSkipped = -32009

    public var errorDescription: String? {
        switch self {
        case .http(429, _): "RPC rate limited"
        case .http(let status, _): "RPC returned HTTP \(status)"
        case .rpc(let code, let message): "RPC error \(code): \(message)"
        case .noResult(let method): "\(method) returned no result"
        }
    }

    public var isRateLimited: Bool {
        if case .http(429, _) = self { return true }
        return false
    }
}

/// A minimal Solana JSON-RPC 2.0 client over URLSession: one request per call.
public struct JSONRPC: Sendable {
    public let endpoint: URL
    let session: URLSession

    public init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    struct Request: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: [JSONValue]
    }

    struct Envelope<T: Decodable>: Decodable {
        struct Failure: Decodable {
            let code: Int
            let message: String
        }
        /// nil when the response has no `result` key; an optional T decodes `null` as its own nil.
        let result: T?
        let error: Failure?

        enum CodingKeys: String, CodingKey { case result, error }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            error = try c.decodeIfPresent(Failure.self, forKey: .error)
            result = c.contains(.result) && error == nil ? try c.decode(T.self, forKey: .result) : nil
        }
    }

    /// Calls `method`. A JSON `null` result decodes into an optional `T` as nil.
    public func call<T: Decodable>(_ method: String, params: [JSONValue] = [], as type: T.Type = T.self,
                                   timeout: TimeInterval = 60) async throws -> T {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Sonata (macOS menu bar)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(Request(id: Int.random(in: 1...Int(Int32.max)), method: method, params: params))

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RPCError.http(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let error = envelope.error { throw RPCError.rpc(code: error.code, message: error.message) }
        guard let result = envelope.result else { throw RPCError.noResult(method: method) }
        return result
    }
}
