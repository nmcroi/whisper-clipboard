import Foundation

/// Pure, synchronous request-building and response-parsing for the PLAUD API.
/// Split out so the entire wire contract is unit-testable with **no network**:
/// tests assert the exact URLs/headers/bodies and parse canned JSON fixtures
/// derived from the reference repos' documented shapes.
///
/// Contract source: `Packaging/PLAUD_API_NOTES.md`.
extension PlaudClient {

    /// Which call an HTTP error came from, so we can map status codes to the most
    /// meaningful Dutch error (e.g. 401 on login vs. on list).
    enum RequestContext {
        case login
        case list
        case download
    }

    // MARK: - Request builders (pure)

    /// `POST {base}/auth/access-token`, form-encoded `username`+`password`.
    /// plaud-toolkit `auth.ts`.
    static func makeLoginRequest(email: String, password: String, region: PlaudRegion) -> URLRequest {
        let url = URL(string: region.baseURL + "/auth/access-token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = formURLEncodedBody(["username": email, "password": password])
        return request
    }

    /// `GET {base}/file/simple/web?skip=&limit=&is_trash=2&sort_by=start_time&is_desc=true`.
    /// applaud `list.ts` query params; plaud-toolkit reads `data_file_list`.
    static func makeListRequest(token: PlaudToken, skip: Int, limit: Int) -> URLRequest {
        var components = URLComponents(string: token.region.baseURL + "/file/simple/web")!
        components.queryItems = [
            URLQueryItem(name: "skip", value: String(skip)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "is_trash", value: "2"),
            URLQueryItem(name: "sort_by", value: "start_time"),
            URLQueryItem(name: "is_desc", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        applyAuthHeaders(&request, token: token, json: true)
        return request
    }

    /// `GET {base}/file/download/{id}` — raw audio bytes (primary path).
    static func makeDownloadRequest(id: String, token: PlaudToken) -> URLRequest {
        let url = URL(string: token.region.baseURL + "/file/download/" + encodePathComponent(id))!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // No JSON content-type — the response is binary.
        applyAuthHeaders(&request, token: token, json: false)
        return request
    }

    /// `GET {base}/file/temp-url/{id}?is_opus=false` — presigned S3 URL (fallback).
    static func makeTempURLRequest(id: String, token: PlaudToken) -> URLRequest {
        var components = URLComponents(string: token.region.baseURL + "/file/temp-url/" + encodePathComponent(id))!
        components.queryItems = [URLQueryItem(name: "is_opus", value: "false")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        applyAuthHeaders(&request, token: token, json: true)
        return request
    }

    // MARK: - Response parsers (pure)

    /// Parses the login response. Success = `status == 0` **and** a non-empty
    /// `access_token`. On failure surfaces PLAUD's `msg`. plaud-toolkit `auth.ts`.
    static func parseLoginResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaudError.unexpectedResponse("kon inlog-antwoord niet lezen")
        }
        // `status` may arrive as a number or a numeric string.
        let status = intValue(json["status"])
        let token = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let status, status != 0 {
            let msg = (json["msg"] as? String) ?? (json["message"] as? String) ?? ""
            throw PlaudError.authFailed(msg)
        }
        guard !token.isEmpty else {
            let msg = (json["msg"] as? String) ?? (json["message"] as? String) ?? ""
            throw PlaudError.authFailed(msg)
        }
        return token
    }

    /// Parses a list page into recordings. Array is under `data_file_list`
    /// (fallback `data`). Trashed items (`is_trash == true`) are dropped, mirroring
    /// plaud-toolkit `client.ts` `list.filter(r => !r.is_trash)` — belt-and-braces
    /// on top of the server-side `is_trash=2` query param.
    static func parseListResponse(_ data: Data) throws -> [PlaudRecording] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaudError.unexpectedResponse("kon opname-lijst niet lezen")
        }
        let rawList = (json["data_file_list"] as? [[String: Any]])
            ?? (json["data"] as? [[String: Any]])
            ?? []
        return rawList
            .filter { ($0["is_trash"] as? Bool) != true }
            .compactMap(recording(from:))
            .filter { !$0.id.isEmpty }
    }

    /// Extracts the presigned URL from a temp-url response. Tries, in order:
    /// `temp_url`, `url`, `data.url`, `data` (string). plaud-toolkit / applaud.
    static func parseTempURLResponse(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let s = json["temp_url"] as? String, !s.isEmpty { return s }
        if let s = json["url"] as? String, !s.isEmpty { return s }
        if let nested = json["data"] as? [String: Any], let s = nested["url"] as? String, !s.isEmpty { return s }
        if let s = json["data"] as? String, !s.isEmpty { return s }
        return nil
    }

    /// If the body is a `status == -302` region redirect carrying `data.domains.api`,
    /// returns the endpoint to retry against, built from the **actual host** in the
    /// body (so a US-variant host isn't collapsed back to the default). Otherwise
    /// `nil`. plaud-toolkit `client.ts`.
    static func redirectRegion(fromBody data: Data) -> PlaudRegion? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard intValue(json["status"]) == -302 else { return nil }
        guard let inner = json["data"] as? [String: Any],
              let domains = inner["domains"] as? [String: Any],
              let api = domains["api"] as? String, !api.isEmpty
        else { return nil }
        return PlaudRegion.from(redirectHost: api)
    }

    // MARK: - Field mapping (pure)

    /// Builds a `PlaudRecording` from one raw list item.
    static func recording(from item: [String: Any]) -> PlaudRecording? {
        let id = stringValue(item["id"]) ?? stringValue(item["file_id"]) ?? ""
        guard !id.isEmpty else { return nil }
        let title = (item["fullname"] as? String)?.nonEmpty
            ?? (item["filename"] as? String)?.nonEmpty
            ?? (item["file_name"] as? String)?.nonEmpty
            ?? id
        let duration = doubleValue(item["duration"]) ?? 0
        let fileSize = Int64(doubleValue(item["filesize"]) ?? 0)
        let start = epochDate(item["start_time"])
        return PlaudRecording(
            id: id,
            title: title,
            startTime: start,
            duration: duration,
            fileSize: fileSize
        )
    }

    // MARK: - Header + encoding helpers (pure)

    static func applyAuthHeaders(_ request: inout URLRequest, token: PlaudToken, json: Bool) {
        request.setValue("Bearer " + token.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }

    /// x-www-form-urlencoded body with proper percent-encoding of `+`, `&`, etc.
    static func formURLEncodedBody(_ fields: [String: String]) -> Data {
        // Deterministic order (sorted keys) so tests can assert the exact bytes.
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            formEncode(key) + "=" + formEncode(value)
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    /// application/x-www-form-urlencoded component encoding (space → `%20`, and
    /// all reserved chars escaped).
    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~") // RFC 3986 unreserved
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Percent-encodes a single URL path component (ids are opaque; be safe).
    static func encodePathComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // MARK: - Loose JSON coercion (pure)

    /// Reads an Int from a JSON value that may be a number or a numeric string.
    static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    /// Reads a Double from a JSON value that may be a number or a numeric string.
    static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? Int { return Double(n) }
        if let s = any as? String { return Double(s) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Reads a String from a JSON value that may be a string or a number (ids can
    /// arrive either way across API versions).
    static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s.isEmpty ? nil : s }
        if let n = any as? Int { return String(n) }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    /// Interprets a PLAUD epoch timestamp (seconds or milliseconds) as a `Date`.
    /// Values ≥ 10^12 are treated as milliseconds. 0/nil → nil.
    static func epochDate(_ any: Any?) -> Date? {
        guard let raw = doubleValue(any), raw > 0 else { return nil }
        let seconds = raw >= 1_000_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Error mapping (pure)

    static func mapURLError(_ error: URLError) -> PlaudError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .timedOut, .dataNotAllowed, .dnsLookupFailed:
            return .network
        default:
            return .server(error.localizedDescription)
        }
    }

    static func mapHTTPError(status: Int, body: Data, context: RequestContext) -> PlaudError {
        switch status {
        case 401, 403:
            // On login, a 401 means bad credentials; elsewhere, an invalid/expired token.
            let msg = extractServerMessage(body)
            return .authFailed(msg)
        case 429:
            return .rateLimited
        default:
            let msg = extractServerMessage(body)
            return .server(msg.isEmpty ? "HTTP \(status)" : msg)
        }
    }

    /// Pulls a human message out of a PLAUD error body (`msg` / `message` / `detail`).
    static func extractServerMessage(_ body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        return (json["msg"] as? String)
            ?? (json["message"] as? String)
            ?? (json["detail"] as? String)
            ?? ""
    }
}

private extension String {
    /// `nil` when the string is empty/whitespace, else self.
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
