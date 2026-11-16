import Foundation

/// The local transcription API: other apps on this Mac (Exo in Obsidian) send audio and get Parlo's
/// text back, with the same model, dictionary and cleanup as a dictation. It speaks the OpenAI
/// `POST /v1/audio/transcriptions` shape (multipart `file`, optional `language`, JSON `{"text": ...}`),
/// so any client written for that format works by changing only the URL.
///
/// This file is the pure part: HTTP framing, multipart, routing. The listener lives in the app,
/// bound to 127.0.0.1 only, and is off until the user turns it on in Settings → General.
public enum LocalAPI {
    public static let port: UInt16 = 47821
    public static let transcriptionsPath = "/v1/audio/transcriptions"
    /// Ten minutes of 16 kHz 16-bit mono is ~19 MB; this leaves room for 48 kHz WAV.
    public static let maxBodyBytes = 64 * 1024 * 1024

    public struct Request: Equatable, Sendable {
        public let method: String
        public let path: String
        /// Lower-cased names.
        public let headers: [String: String]
        public let body: Data
    }

    public enum Framing: Equatable, Sendable {
        /// Keep reading.
        case incomplete
        case request(Request)
        case invalid(status: Int, message: String)
    }

    /// Frames one HTTP/1.1 request out of the bytes received so far (Content-Length bodies only).
    public static func frame(_ data: Data) -> Framing {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = data.range(of: separator) else {
            return data.count > 64 * 1024 ? .invalid(status: 431, message: "Headers too large") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, message: "Bad request")
        }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard start.count >= 2 else { return .invalid(status: 400, message: "Bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(status: 411, message: "Send a Content-Length body")
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        guard length >= 0, length <= maxBodyBytes else { return .invalid(status: 413, message: "Audio too large") }
        let bodyStart = headEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        let path = String(start[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return .request(Request(method: String(start[0]).uppercased(), path: path, headers: headers, body: Data(body)))
    }

    public struct Part: Equatable, Sendable {
        public let name: String
        public let filename: String?
        public let data: Data
    }

    /// Splits a multipart/form-data body. Returns nil when the boundary is missing or the body is malformed.
    public static func parts(_ body: Data, contentType: String) -> [Part]? {
        guard let boundary = boundary(contentType) else { return nil }
        let delimiter = Data("--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8), blank = Data("\r\n\r\n".utf8)
        var result: [Part] = []
        guard var cursor = body.range(of: delimiter)?.upperBound else { return nil }
        while cursor < body.endIndex {
            // "--" after a delimiter ends the body.
            if body[cursor...].starts(with: Data("--".utf8)) { return result }
            guard body[cursor...].starts(with: crlf) else { return nil }
            let headerStart = cursor + crlf.count
            guard let headerEnd = body.range(of: blank, in: headerStart..<body.endIndex),
                  let next = body.range(of: delimiter, in: headerEnd.upperBound..<body.endIndex)
            else { return nil }
            let header = String(decoding: body[headerStart..<headerEnd.lowerBound], as: UTF8.self)
            var contentEnd = next.lowerBound
            if contentEnd - headerEnd.upperBound >= 2, body[(contentEnd - 2)..<contentEnd] == crlf { contentEnd -= 2 }
            if let name = dispositionValue("name", in: header) {
                result.append(Part(
                    name: name, filename: dispositionValue("filename", in: header),
                    data: Data(body[headerEnd.upperBound..<contentEnd])
                ))
            }
            cursor = next.upperBound
        }
        return nil
    }

    static func boundary(_ contentType: String) -> String? {
        for piece in contentType.split(separator: ";") {
            let kv = piece.trimmingCharacters(in: .whitespaces)
            guard kv.lowercased().hasPrefix("boundary=") else { continue }
            let value = kv.dropFirst("boundary=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func dispositionValue(_ key: String, in header: String) -> String? {
        for line in header.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-disposition:") {
            for piece in line.split(separator: ";") {
                let kv = piece.trimmingCharacters(in: .whitespaces)
                guard kv.lowercased().hasPrefix("\(key)=") else { continue }
                return String(kv.dropFirst(key.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    public enum Route: Equatable, Sendable {
        case health
        /// `language`: nil keeps the language set in Parlo. `filename` gives the decoder the extension.
        case transcribe(audio: Data, filename: String, language: String?)
        case reject(status: Int, message: String)
    }

    /// Only Obsidian and clients without an Origin (curl, Node) may call it: a web page open in a
    /// browser must not be able to make this Mac transcribe for it.
    public static let allowedOrigins: Set<String> = ["app://obsidian.md"]

    public static func route(_ request: Request) -> Route {
        if let origin = request.headers["origin"], !allowedOrigins.contains(origin) {
            return .reject(status: 403, message: "Origin not allowed")
        }
        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/v1/health"):
            return .health
        case ("POST", transcriptionsPath):
            guard let parts = parts(request.body, contentType: request.headers["content-type"] ?? "") else {
                return .reject(status: 400, message: "Expected multipart/form-data")
            }
            guard let file = parts.first(where: { $0.name == "file" }), !file.data.isEmpty else {
                return .reject(status: 400, message: "Missing audio in the \"file\" field")
            }
            let language = parts.first(where: { $0.name == "language" })
                .map { String(decoding: $0.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .flatMap { $0.isEmpty ? nil : $0 }
            return .transcribe(audio: file.data, filename: file.filename ?? "audio.wav", language: language)
        case (_, transcriptionsPath), (_, "/health"):
            return .reject(status: 405, message: "Method not allowed")
        default:
            return .reject(status: 404, message: "Not found")
        }
    }

    /// A complete HTTP/1.1 response with a JSON body; the connection closes after it.
    public static func response(status: Int, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                      411: "Length Required", 413: "Payload Too Large", 422: "Unprocessable Content",
                      431: "Request Header Fields Too Large", 500: "Internal Server Error",
                      503: "Service Unavailable"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    public static func error(status: Int, _ message: String) -> Data {
        response(status: status, json: ["error": ["message": message]])
    }
}
