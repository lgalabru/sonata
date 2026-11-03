import Foundation
import Testing
@testable import SonataCore

@Suite struct JSONRPCTests {
    @Test func paramsEncodeAsJSON() throws {
        let params: [JSONValue] = [.int(UInt64(464_738_138)), ["encoding": "base64", "filters": [["memcmp": ["offset": 8, "bytes": .string("abc")]]]], nil, true]
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [Any]
        #expect(json?[0] as? Int == 464_738_138)
        let options = json?[1] as? [String: Any]
        #expect(options?["encoding"] as? String == "base64")
        #expect(((options?["filters"] as? [[String: Any]])?.first?["memcmp"] as? [String: Any])?["offset"] as? Int == 8)
        #expect(json?[2] is NSNull)
        #expect(json?[3] as? Bool == true)
    }

    @Test func nullResultDecodesAsNil() throws {
        let envelope = try JSONDecoder().decode(JSONRPC.Envelope<[String: [UInt64]]?>.self, from: Data(#"{"jsonrpc":"2.0","result":null,"id":1}"#.utf8))
        #expect(envelope.result == .some(nil))
        let missing = try JSONDecoder().decode(JSONRPC.Envelope<UInt64>.self, from: Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
        #expect(missing.result == nil)
    }

    @Test func nodeErrorsAreKept() throws {
        let envelope = try JSONDecoder().decode(JSONRPC.Envelope<UInt64>.self,
            from: Data(#"{"jsonrpc":"2.0","error":{"code":-32007,"message":"Slot 1 was skipped"},"id":1}"#.utf8))
        #expect(envelope.error?.code == RPCError.slotSkipped)
        #expect(RPCError.http(status: 429, retryAfter: 10).isRateLimited)
        #expect(!RPCError.rpc(code: -32004, message: "").isRateLimited)
    }
}
