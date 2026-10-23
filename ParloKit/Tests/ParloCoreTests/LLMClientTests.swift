import Foundation
import Testing
@testable import ParloCore

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let (status, data) = Self.handler!(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct LLMClientTests {
    func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }
    let settings = LLMSettings(enabled: true, baseURL: "https://api.example.com/v1/", model: "m1")

    @Test func sendsRequestAndParses() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"choices":[{"message":{"content":"  Ciao.  "}}]}"#.utf8)) }
        let client = LLMClient(settings: settings, apiKey: "sk-1", session: session())
        let out = try await client.complete(system: "S", user: "U", timeout: 5)
        #expect(out == "Ciao.")
        let req = try #require(StubProtocol.lastRequest)
        #expect(req.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody!) as! [String: Any]
        #expect(body["model"] as? String == "m1")
        #expect(body["temperature"] as? Double == 0)
        let msgs = body["messages"] as! [[String: String]]
        #expect(msgs == [["role": "system", "content": "S"], ["role": "user", "content": "U"]])
    }

    @Test func noKeyNoAuthHeader() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"choices":[{"message":{"content":"x"}}]}"#.utf8)) }
        _ = try await LLMClient(settings: settings, apiKey: nil, session: session()).complete(system: "S", user: "U", timeout: 5)
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func httpError() async throws {
        StubProtocol.handler = { _ in (401, Data("bad key".utf8)) }
        await #expect(throws: LLMError.http(401, "bad key")) {
            try await LLMClient(settings: settings, apiKey: "k", session: session()).complete(system: "S", user: "U", timeout: 5)
        }
    }

    @Test func emptyContent() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8)) }
        await #expect(throws: LLMError.emptyResponse) {
            try await LLMClient(settings: settings, apiKey: nil, session: session()).complete(system: "S", user: "U", timeout: 5)
        }
    }
}
