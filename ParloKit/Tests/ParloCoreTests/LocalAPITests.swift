import Foundation
import Testing
@testable import ParloCore

@Suite struct LocalAPITests {
    func multipart(_ fields: [(String, String)], file: Data?, boundary: String = "XyZ") -> Data {
        var body = Data()
        for (name, value) in fields {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        if let file {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            body += file + Data("\r\n".utf8)
        }
        return body + Data("--\(boundary)--\r\n".utf8)
    }

    func http(_ method: String, _ path: String, headers: [String: String] = [:], body: Data = Data()) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:47821\r\nContent-Length: \(body.count)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    func framed(_ data: Data) throws -> LocalAPI.Request {
        guard case let .request(r) = LocalAPI.frame(data) else { throw CancellationError() }
        return r
    }

    @Test func framesOnlyWhenTheWholeBodyArrived() throws {
        let raw = http("POST", "/v1/audio/transcriptions", body: Data(repeating: 7, count: 10))
        #expect(LocalAPI.frame(raw.prefix(20)) == .incomplete)
        #expect(LocalAPI.frame(raw.dropLast(1)) == .incomplete)
        let r = try framed(raw)
        #expect(r.method == "POST")
        #expect(r.path == "/v1/audio/transcriptions")
        #expect(r.body == Data(repeating: 7, count: 10))
        #expect(r.headers["host"] == "127.0.0.1:47821")
    }

    @Test func rejectsChunkedAndHugeBodies() {
        let chunked = Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        #expect(LocalAPI.frame(chunked) == .invalid(status: 411, message: "Send a Content-Length body"))
        let huge = Data("POST /x HTTP/1.1\r\nContent-Length: \(LocalAPI.maxBodyBytes + 1)\r\n\r\n".utf8)
        #expect(LocalAPI.frame(huge) == .invalid(status: 413, message: "Audio too large"))
    }

    @Test func routesATranscriptionWithBinaryAudioAndLanguage() throws {
        let audio = Data([0, 255, 13, 10, 45, 45, 1])
        let body = multipart([("response_format", "json"), ("language", " IT ")], file: audio)
        let r = try framed(http("POST", "/v1/audio/transcriptions?x=1",
                                headers: ["Content-Type": "multipart/form-data; boundary=XyZ"], body: body))
        #expect(LocalAPI.route(r) == .transcribe(audio: audio, filename: "dictation.wav", language: "it"))
    }

    @Test func languageIsOptional() throws {
        let body = multipart([], file: Data([1, 2]))
        let r = try framed(http("POST", "/v1/audio/transcriptions",
                                headers: ["Content-Type": "multipart/form-data; boundary=\"XyZ\""], body: body))
        #expect(LocalAPI.route(r) == .transcribe(audio: Data([1, 2]), filename: "dictation.wav", language: nil))
    }

    @Test func missingFileIsABadRequest() throws {
        let r = try framed(http("POST", "/v1/audio/transcriptions",
                                headers: ["Content-Type": "multipart/form-data; boundary=XyZ"],
                                body: multipart([("language", "it")], file: nil)))
        #expect(LocalAPI.route(r) == .reject(status: 400, message: "Missing audio in the \"file\" field"))
    }

    @Test func browserPagesAreRefusedButObsidianIsAllowed() throws {
        let body = multipart([], file: Data([1]))
        let ct = ["Content-Type": "multipart/form-data; boundary=XyZ"]
        let web = try framed(http("POST", "/v1/audio/transcriptions", headers: ct.merging(["Origin": "https://evil.example"]) { $1 }, body: body))
        #expect(LocalAPI.route(web) == .reject(status: 403, message: "Origin not allowed"))
        let obsidian = try framed(http("POST", "/v1/audio/transcriptions", headers: ct.merging(["Origin": "app://obsidian.md"]) { $1 }, body: body))
        #expect(LocalAPI.route(obsidian) == .transcribe(audio: Data([1]), filename: "dictation.wav", language: nil))
    }

    @Test func healthAndUnknownPaths() throws {
        #expect(LocalAPI.route(try framed(http("GET", "/health"))) == .health)
        #expect(LocalAPI.route(try framed(http("GET", "/nope"))) == .reject(status: 404, message: "Not found"))
        #expect(LocalAPI.route(try framed(http("GET", "/v1/audio/transcriptions"))) == .reject(status: 405, message: "Method not allowed"))
    }

    @Test func responseIsCompleteHTTP() {
        let text = String(decoding: LocalAPI.response(status: 200, json: ["text": "ciao"]), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 15\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{\"text\":\"ciao\"}"))
    }
}
