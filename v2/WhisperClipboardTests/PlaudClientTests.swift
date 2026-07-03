import XCTest
@testable import WhisperClipboard

/// Unit tests for the pure PLAUD wire contract: request builders (exact
/// URLs/headers/bodies), response parsers against canned JSON fixtures derived
/// from the reference repos' documented shapes, field mapping, and error
/// mapping. No network is touched.
///
/// Fixtures mirror `Packaging/PLAUD_API_NOTES.md`.
final class PlaudClientTests: XCTestCase {

    private let usToken = PlaudToken(accessToken: "tok-123", region: .us)
    private let euToken = PlaudToken(accessToken: "tok-eu", region: .eu)

    // MARK: - Region hosts

    func testRegionBaseURLs() {
        XCTAssertEqual(PlaudRegion.us.baseURL, "https://api.plaud.ai")
        XCTAssertEqual(PlaudRegion.eu.baseURL, "https://api-euc1.plaud.ai")
        XCTAssertEqual(PlaudRegion.apac.baseURL, "https://api-apse1.plaud.ai")
    }

    func testRegionFromRedirectHost() {
        // Bare hosts that match a named region collapse to the named case.
        XCTAssertEqual(PlaudRegion.from(redirectHost: "api-euc1.plaud.ai"), .eu)
        XCTAssertEqual(PlaudRegion.from(redirectHost: "api-apse1.plaud.ai"), .apac)
        XCTAssertEqual(PlaudRegion.from(redirectHost: "https://api.plaud.ai"), .us)
    }

    func testRegionFromRedirectHostFullURLMatchesNamedRegion() {
        // A full URL to a known region host still resolves to the named case.
        XCTAssertEqual(PlaudRegion.from(redirectHost: "https://api-euc1.plaud.ai"), .eu)
    }

    func testRegionFromUnknownHostBecomesCustomNotUS() {
        // The core of finding #2: a US-*variant* host must NOT collapse to `.us`
        // (which would make a -302 redirect a no-op). It becomes `.custom` with the
        // exact base URL so the redirect is actually followed.
        let region = PlaudRegion.from(redirectHost: "api-usw2.plaud.ai")
        XCTAssertEqual(region, .custom(baseURL: "https://api-usw2.plaud.ai"))
        XCTAssertNotEqual(region, .us)
        XCTAssertEqual(region?.baseURL, "https://api-usw2.plaud.ai")
    }

    func testRegionFromRedirectHostNormalizesTrailingPath() {
        // A redirect value with a path/trailing slash is normalized to scheme+host.
        XCTAssertEqual(
            PlaudRegion.from(redirectHost: "https://api-usw2.plaud.ai/"),
            .custom(baseURL: "https://api-usw2.plaud.ai")
        )
    }

    func testRegionFromEmptyHostIsNil() {
        XCTAssertNil(PlaudRegion.from(redirectHost: ""))
        XCTAssertNil(PlaudRegion.from(redirectHost: "   "))
    }

    func testCustomRegionBuildsRequestsAgainstItsHost() {
        // A token carrying a custom region must build list/download requests
        // against that exact host — proving the redirect endpoint is honoured.
        let token = PlaudToken(accessToken: "t", region: .custom(baseURL: "https://api-usw2.plaud.ai"))
        let list = PlaudClient.makeListRequest(token: token, skip: 0, limit: 50)
        XCTAssertEqual(URLComponents(url: list.url!, resolvingAgainstBaseURL: false)?.host, "api-usw2.plaud.ai")
        let dl = PlaudClient.makeDownloadRequest(id: "r1", token: token)
        XCTAssertEqual(dl.url?.absoluteString, "https://api-usw2.plaud.ai/file/download/r1")
    }

    // MARK: - Login request builder

    func testLoginRequestURLAndMethod() {
        let req = PlaudClient.makeLoginRequest(email: "a@b.com", password: "pw", region: .us)
        XCTAssertEqual(req.url?.absoluteString, "https://api.plaud.ai/auth/access-token")
        XCTAssertEqual(req.httpMethod, "POST")
    }

    func testLoginRequestHeaders() {
        let req = PlaudClient.makeLoginRequest(email: "a@b.com", password: "pw", region: .us)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "User-Agent"))
    }

    func testLoginRequestBodyIsFormEncoded() {
        let req = PlaudClient.makeLoginRequest(email: "a@b.com", password: "pw", region: .us)
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8)
        // Keys are sorted (password before username) and form-encoded.
        XCTAssertEqual(body, "password=pw&username=a%40b.com")
    }

    func testLoginRequestBodyEscapesReservedChars() {
        let req = PlaudClient.makeLoginRequest(email: "x+y@b.com", password: "p&w=z", region: .us)
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        // '+' must be escaped (%2B), '&' and '=' inside values escaped too.
        XCTAssertTrue(body.contains("username=x%2By%40b.com"), body)
        XCTAssertTrue(body.contains("password=p%26w%3Dz"), body)
    }

    func testLoginRequestUsesRegionHost() {
        let req = PlaudClient.makeLoginRequest(email: "a@b.com", password: "pw", region: .eu)
        XCTAssertEqual(req.url?.absoluteString, "https://api-euc1.plaud.ai/auth/access-token")
    }

    // MARK: - List request builder

    func testListRequestURLHasExactQueryParams() {
        let req = PlaudClient.makeListRequest(token: usToken, skip: 0, limit: 50)
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.host, "api.plaud.ai")
        XCTAssertEqual(comps.path, "/file/simple/web")
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["skip"], "0")
        XCTAssertEqual(items["limit"], "50")
        XCTAssertEqual(items["is_trash"], "2")
        XCTAssertEqual(items["sort_by"], "start_time")
        XCTAssertEqual(items["is_desc"], "true")
    }

    func testListRequestAuthHeader() {
        let req = PlaudClient.makeListRequest(token: usToken, skip: 0, limit: 50)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testListRequestPagingSkip() {
        let req = PlaudClient.makeListRequest(token: usToken, skip: 100, limit: 50)
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["skip"], "100")
    }

    // MARK: - Download request builders

    func testDownloadRequestURLAndAuth() {
        let req = PlaudClient.makeDownloadRequest(id: "rec42", token: usToken)
        XCTAssertEqual(req.url?.absoluteString, "https://api.plaud.ai/file/download/rec42")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        // No JSON content-type on the binary download.
        XCTAssertNil(req.value(forHTTPHeaderField: "Content-Type"))
    }

    func testTempURLRequest() {
        let req = PlaudClient.makeTempURLRequest(id: "rec42", token: euToken)
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.host, "api-euc1.plaud.ai")
        XCTAssertEqual(comps.path, "/file/temp-url/rec42")
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["is_opus"], "false")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-eu")
    }

    // MARK: - Login response parsing

    func testParseLoginSuccess() throws {
        let json = #"{"status":0,"access_token":"jwt-abc","token_type":"Bearer"}"#.data(using: .utf8)!
        XCTAssertEqual(try PlaudClient.parseLoginResponse(json), "jwt-abc")
    }

    func testParseLoginStatusAsStringSucceeds() throws {
        // Some API versions return status as a numeric string.
        let json = #"{"status":"0","access_token":"jwt-str"}"#.data(using: .utf8)!
        XCTAssertEqual(try PlaudClient.parseLoginResponse(json), "jwt-str")
    }

    func testParseLoginFailureCarriesMsg() {
        let json = #"{"status":1,"msg":"wrong password"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try PlaudClient.parseLoginResponse(json)) { error in
            XCTAssertEqual(error as? PlaudError, .authFailed("wrong password"))
        }
    }

    /// The EXACT bad-credentials body observed from the live endpoint
    /// (`POST https://api.plaud.ai/auth/access-token`, 2026-07): HTTP 200 with
    /// `status:-2`, `msg:"wrong account or password"`, empty `access_token`.
    /// Must map to `.authFailed` with the server message (not a false redirect,
    /// since -2 ≠ -302).
    func testParseLoginRealBadCredentialsBody() {
        let json = #"{"status":-2,"msg":"wrong account or password","access_token":"","token_type":"bearer"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try PlaudClient.parseLoginResponse(json)) { error in
            XCTAssertEqual(error as? PlaudError, .authFailed("wrong account or password"))
        }
        // And it is NOT mistaken for a region redirect.
        XCTAssertNil(PlaudClient.redirectRegion(fromBody: json))
    }

    func testParseLoginMissingTokenIsAuthFailure() {
        let json = #"{"status":0}"#.data(using: .utf8)!
        XCTAssertThrowsError(try PlaudClient.parseLoginResponse(json)) { error in
            guard let plaud = error as? PlaudError, case .authFailed = plaud else {
                return XCTFail("expected authFailed, got \(error)")
            }
        }
    }

    func testParseLoginGarbageThrowsUnexpected() {
        XCTAssertThrowsError(try PlaudClient.parseLoginResponse(Data("not json".utf8))) { error in
            guard let plaud = error as? PlaudError, case .unexpectedResponse = plaud else {
                return XCTFail("expected unexpectedResponse, got \(error)")
            }
        }
    }

    // MARK: - List response parsing

    /// A canned list page mirroring the documented `PlaudRecording` shape.
    private let listFixture = """
    {
      "status": 0,
      "data_file_list": [
        {"id":"rec1","fullname":"Vergadering maandag","filename":"rec1.mp3","duration":123.5,"filesize":204800,"start_time":1719849600000,"is_trash":false},
        {"id":"rec2","filename":"losse memo","duration":42,"start_time":1719936000000,"is_trash":false},
        {"id":"rec3","fullname":"Prullenbak","duration":10,"start_time":1719000000000,"is_trash":true}
      ]
    }
    """.data(using: .utf8)!

    func testParseListReadsDataFileList() throws {
        let recordings = try PlaudClient.parseListResponse(listFixture)
        // Trashed rec3 is filtered out.
        XCTAssertEqual(recordings.map(\.id), ["rec1", "rec2"])
    }

    func testParseListMapsFields() throws {
        let recordings = try PlaudClient.parseListResponse(listFixture)
        let rec1 = recordings[0]
        XCTAssertEqual(rec1.id, "rec1")
        XCTAssertEqual(rec1.title, "Vergadering maandag") // fullname preferred
        XCTAssertEqual(rec1.duration, 123.5, accuracy: 0.001)
        XCTAssertEqual(rec1.fileSize, 204800)
        // start_time is epoch ms → 2024-07-01T16:00:00Z
        XCTAssertEqual(rec1.startTime?.timeIntervalSince1970 ?? 0, 1719849600, accuracy: 1)

        let rec2 = recordings[1]
        XCTAssertEqual(rec2.title, "losse memo") // falls back to filename
    }

    func testParseListFallsBackToDataKey() throws {
        let json = #"{"data":[{"id":"x","fullname":"X","duration":1,"start_time":1000}]}"#.data(using: .utf8)!
        let recordings = try PlaudClient.parseListResponse(json)
        XCTAssertEqual(recordings.map(\.id), ["x"])
    }

    func testParseListEmptyList() throws {
        let json = #"{"status":0,"data_file_list":[]}"#.data(using: .utf8)!
        XCTAssertTrue(try PlaudClient.parseListResponse(json).isEmpty)
    }

    func testRecordingWithoutIdIsDropped() {
        let item: [String: Any] = ["fullname": "no id", "duration": 5]
        XCTAssertNil(PlaudClient.recording(from: item))
    }

    // MARK: - epoch handling (ms vs s)

    func testEpochMillisecondsAndSeconds() {
        // ms (>= 10^12)
        let ms = PlaudClient.epochDate(1_719_849_600_000)
        XCTAssertEqual(ms?.timeIntervalSince1970 ?? 0, 1_719_849_600, accuracy: 1)
        // s
        let s = PlaudClient.epochDate(1_719_849_600)
        XCTAssertEqual(s?.timeIntervalSince1970 ?? 0, 1_719_849_600, accuracy: 1)
        // zero / nil
        XCTAssertNil(PlaudClient.epochDate(0))
        XCTAssertNil(PlaudClient.epochDate(nil))
    }

    // MARK: - temp-url parsing

    func testParseTempURLPrefersTempURLField() {
        let json = #"{"temp_url":"https://s3.example/rec.mp3?sig=1"}"#.data(using: .utf8)!
        XCTAssertEqual(PlaudClient.parseTempURLResponse(json), "https://s3.example/rec.mp3?sig=1")
    }

    func testParseTempURLFallbacks() {
        XCTAssertEqual(PlaudClient.parseTempURLResponse(#"{"url":"https://a"}"#.data(using: .utf8)!), "https://a")
        XCTAssertEqual(PlaudClient.parseTempURLResponse(#"{"data":{"url":"https://b"}}"#.data(using: .utf8)!), "https://b")
        XCTAssertEqual(PlaudClient.parseTempURLResponse(#"{"data":"https://c"}"#.data(using: .utf8)!), "https://c")
        XCTAssertNil(PlaudClient.parseTempURLResponse(#"{"nope":1}"#.data(using: .utf8)!))
    }

    // MARK: - region redirect (-302)

    func testRedirectRegionFromBody() {
        let json = #"{"status":-302,"data":{"domains":{"api":"https://api-euc1.plaud.ai"}}}"#.data(using: .utf8)!
        XCTAssertEqual(PlaudClient.redirectRegion(fromBody: json), .eu)
    }

    func testRedirectRegionFromBodyToVariantHostIsCustom() {
        // A -302 to a US-variant host is followed to that exact host, not `.us`.
        let json = #"{"status":-302,"data":{"domains":{"api":"https://api-usw2.plaud.ai"}}}"#.data(using: .utf8)!
        let region = PlaudClient.redirectRegion(fromBody: json)
        XCTAssertEqual(region, .custom(baseURL: "https://api-usw2.plaud.ai"))
        // The follow decision the login loop makes: a US-start client would move.
        XCTAssertNotEqual(region?.baseURL, PlaudRegion.us.baseURL)
    }

    func testNoRedirectWhenStatusNormal() {
        let json = #"{"status":0,"data_file_list":[]}"#.data(using: .utf8)!
        XCTAssertNil(PlaudClient.redirectRegion(fromBody: json))
    }

    // MARK: - Download extension derivation (finding 9a)

    private func httpResponse(headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.plaud.ai/file/download/x")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    func testContentTypeMappingToExtensions() {
        XCTAssertEqual(PlaudClient.audioExtension(forContentType: "audio/mpeg"), "mp3")
        XCTAssertEqual(PlaudClient.audioExtension(forContentType: "audio/opus"), "opus")
        XCTAssertEqual(PlaudClient.audioExtension(forContentType: "audio/ogg; charset=binary"), "opus")
        XCTAssertEqual(PlaudClient.audioExtension(forContentType: "audio/mp4"), "m4a")
        XCTAssertEqual(PlaudClient.audioExtension(forContentType: "audio/wav"), "wav")
        // Unknown/generic → nil so the caller keeps the requested .mp3.
        XCTAssertNil(PlaudClient.audioExtension(forContentType: "application/octet-stream"))
    }

    func testFinalDestinationKeepsMp3WhenServerSaysMpeg() {
        let preferred = URL(fileURLWithPath: "/tmp/rec.mp3")
        let resp = httpResponse(headers: ["Content-Type": "audio/mpeg"])
        XCTAssertEqual(PlaudClient.finalDestination(preferred: preferred, response: resp).pathExtension, "mp3")
    }

    func testFinalDestinationSwitchesToOpusFromContentType() {
        let preferred = URL(fileURLWithPath: "/tmp/rec.mp3")
        let resp = httpResponse(headers: ["Content-Type": "audio/opus"])
        let final = PlaudClient.finalDestination(preferred: preferred, response: resp)
        XCTAssertEqual(final.pathExtension, "opus")
        XCTAssertEqual(final.deletingPathExtension().lastPathComponent, "rec")
    }

    func testFinalDestinationDerivesFromContentDisposition() {
        let preferred = URL(fileURLWithPath: "/tmp/rec.mp3")
        let resp = httpResponse(headers: ["Content-Disposition": #"attachment; filename="meeting.opus""#])
        XCTAssertEqual(PlaudClient.finalDestination(preferred: preferred, response: resp).pathExtension, "opus")
    }

    func testFinalDestinationRFC5987Filename() {
        let name = PlaudClient.filename(fromContentDisposition: "attachment; filename*=UTF-8''caf%C3%A9.opus")
        XCTAssertEqual(name, "café.opus")
    }

    func testFinalDestinationFallsBackToPreferredWhenNoHints() {
        let preferred = URL(fileURLWithPath: "/tmp/rec.mp3")
        let resp = httpResponse(headers: [:])
        XCTAssertEqual(PlaudClient.finalDestination(preferred: preferred, response: resp).pathExtension, "mp3")
    }

    // MARK: - Error mapping

    func testHTTP401OnLoginMapsToAuthFailed() {
        let err = PlaudClient.mapHTTPError(status: 401, body: Data(), context: .login)
        guard case PlaudError.authFailed = err else { return XCTFail("expected authFailed, got \(err)") }
    }

    func testHTTP429MapsToRateLimited() {
        XCTAssertEqual(PlaudClient.mapHTTPError(status: 429, body: Data(), context: .list), .rateLimited)
    }

    func testHTTP500ExtractsMessage() {
        let body = #"{"msg":"boom"}"#.data(using: .utf8)!
        XCTAssertEqual(PlaudClient.mapHTTPError(status: 500, body: body, context: .list), .server("boom"))
    }

    func testHTTP500WithoutBodyFallsBack() {
        XCTAssertEqual(PlaudClient.mapHTTPError(status: 500, body: Data(), context: .list), .server("HTTP 500"))
    }

    func testURLErrorOfflineMapsToNetwork() {
        XCTAssertEqual(PlaudClient.mapURLError(URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(PlaudClient.mapURLError(URLError(.timedOut)), .network)
        XCTAssertEqual(PlaudClient.mapURLError(URLError(.dnsLookupFailed)), .network)
    }

    // MARK: - Dutch error messages

    func testDutchErrorMessages() {
        XCTAssertTrue(PlaudError.missingCredentials.localizedDescription.contains("PLAUD"))
        XCTAssertTrue(PlaudError.network.localizedDescription.contains("internetverbinding"))
        XCTAssertTrue(PlaudError.rateLimited.localizedDescription.contains("beperkt"))
        XCTAssertTrue(PlaudError.authFailed("").localizedDescription.contains("Inloggen"))
        XCTAssertTrue(PlaudError.unexpectedResponse("").localizedDescription.contains("Onverwacht"))
    }

    // MARK: - Filename stem

    func testSuggestedFilenameStemIsSafeAndUnique() {
        let rec = PlaudRecording(
            id: "abcdef1234567890",
            title: "Gesprek: klant/verkoper?",
            startTime: Date(timeIntervalSince1970: 1_719_849_600),
            duration: 60,
            fileSize: 0
        )
        let stem = rec.suggestedFilenameStem
        // No path-hostile characters survive.
        XCTAssertFalse(stem.contains("/"))
        XCTAssertFalse(stem.contains(":"))
        XCTAssertFalse(stem.contains("?"))
        // Includes a short id for uniqueness.
        XCTAssertTrue(stem.contains("abcdef12"))
    }

    func testSanitizeCollapsesWhitespace() {
        XCTAssertEqual(PlaudRecording.sanitize("a   b\tc"), "a b c")
    }
}
