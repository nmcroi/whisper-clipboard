import XCTest
@testable import WhisperClipboard

/// Integration tests for `PlaudClient` that exercise the *stateful* I/O paths
/// (login redirect-follow, list `since`/`limit` request building, and the
/// download-to-file + extension derivation) against a canned `URLProtocol` — no
/// real network. Complements the pure wire tests in `PlaudClientTests`.
final class PlaudClientIntegrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PlaudRouteURLProtocol.reset()
    }

    override func tearDown() {
        PlaudRouteURLProtocol.reset()
        super.tearDown()
    }

    private func client(region: PlaudRegion = .us) -> PlaudClient {
        PlaudClient(session: PlaudRouteURLProtocol.session(), region: region)
    }

    // MARK: - Login redirect follow (finding #2)

    func testLoginFollowsMinus302ToVariantHostAndSucceeds() async throws {
        // US host answers with a -302 redirect to a US-*variant* host; that host
        // returns a real token. The redirect MUST be followed (not collapsed to
        // `.us` and its body mis-parsed as a failed login).
        PlaudRouteURLProtocol.handler = { request in
            let host = request.url?.host ?? ""
            let body: Data
            if host == "api.plaud.ai" {
                body = #"{"status":-302,"data":{"domains":{"api":"https://api-usw2.plaud.ai"}}}"#.data(using: .utf8)!
            } else if host == "api-usw2.plaud.ai" {
                body = #"{"status":0,"access_token":"jwt-usw2"}"#.data(using: .utf8)!
            } else {
                body = #"{"status":1,"msg":"unexpected host"}"#.data(using: .utf8)!
            }
            return (200, [:], body)
        }

        let token = try await client().login(email: "a@b.com", password: "pw")
        XCTAssertEqual(token.accessToken, "jwt-usw2")
        // The token carries the redirected endpoint, so later calls use it.
        XCTAssertEqual(token.region.baseURL, "https://api-usw2.plaud.ai")

        // We hit the US host first, then the variant host — the redirect was followed.
        let hosts = PlaudRouteURLProtocol.requestedURLs.compactMap(\.host)
        XCTAssertEqual(hosts, ["api.plaud.ai", "api-usw2.plaud.ai"])
    }

    func testLoginRedirectLoopIsBounded() async {
        // A host that always redirects to a different host would loop forever
        // without the bound; assert we give up with the "repeated redirect" error
        // rather than hanging.
        PlaudRouteURLProtocol.handler = { request in
            // Alternate the redirect target so it never settles.
            let n = PlaudRouteURLProtocol.requestedURLs.count
            let target = "https://api-loop\(n).plaud.ai"
            let body = #"{"status":-302,"data":{"domains":{"api":"\#(target)"}}}"#.data(using: .utf8)!
            return (200, [:], body)
        }

        do {
            _ = try await self.client().login(email: "a@b.com", password: "pw")
            XCTFail("expected a bounded-redirect failure")
        } catch let error as PlaudError {
            guard case .unexpectedResponse = error else {
                return XCTFail("expected unexpectedResponse, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        // Bounded: initial + maxLoginRedirects attempts, no more.
        XCTAssertLessThanOrEqual(PlaudRouteURLProtocol.requestedURLs.count, PlaudClient.maxLoginRedirects + 1)
    }

    // MARK: - List: since + limit request building (findings #3 & #7)

    func testListPassesSinceAndPagesUntilPastSince() async throws {
        let since = Date(timeIntervalSince1970: 2_000)
        // Page 1 (full, all newer than `since`) then page 2 (contains an item at/
        // older than since) → paging stops. Items older than since are filtered.
        let page1 = Self.listPage(startTimes: Array(repeating: 5_000_000, count: 50)) // full page, ms epoch
        let page2 = Self.listPage(startTimes: [3_000_000, 1_000]) // 1_000s <= since
        PlaudRouteURLProtocol.handler = { request in
            let skip = Self.queryValue("skip", request.url) ?? "0"
            return (200, [:], skip == "0" ? page1 : page2)
        }

        let token = PlaudToken(accessToken: "t", region: .us)
        let recordings = try await client().listRecordings(token: token, since: since)

        // Two pages fetched: skip=0 then skip=50.
        let skips = PlaudRouteURLProtocol.requestedURLs.compactMap { Self.queryValue("skip", $0) }
        XCTAssertEqual(skips, ["0", "50"])
        // The item with start_time 1_000s (< since 2_000s) is filtered out.
        XCTAssertFalse(recordings.contains { $0.startTime == Date(timeIntervalSince1970: 1_000) })
    }

    func testProbeConnectionMakesExactlyOneCheapCall() async throws {
        // Finding #7: the connection test is an explicit cheap call — one page,
        // limit=1, no paging, no `since` query param — regardless of what the
        // server returns (even a "full" page of 1 must NOT trigger paging).
        PlaudRouteURLProtocol.handler = { _ in (200, [:], Self.listPage(startTimes: [9_000_000])) }
        let token = PlaudToken(accessToken: "t", region: .us)
        _ = try await client().probeConnection(token: token)

        XCTAssertEqual(PlaudRouteURLProtocol.requestedURLs.count, 1)
        let first = PlaudRouteURLProtocol.requestedURLs.first
        XCTAssertEqual(Self.queryValue("limit", first), "1")
        XCTAssertNil(Self.queryValue("since", first)) // `since` is a client-side filter, never a query param
    }

    func testProbeConnectionSurfacesAuthError() async {
        PlaudRouteURLProtocol.handler = { _ in (401, [:], #"{"msg":"bad token"}"#.data(using: .utf8)!) }
        let token = PlaudToken(accessToken: "t", region: .us)
        do {
            _ = try await client().probeConnection(token: token)
            XCTFail("expected authFailed")
        } catch let error as PlaudError {
            guard case .authFailed = error else { return XCTFail("expected authFailed, got \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Download to file + extension derivation (findings #1 & #9a)

    func testDownloadWritesFileAndKeepsMp3() async throws {
        let audio = Data([0x49, 0x44, 0x33, 0x00]) // "ID3.." bytes
        PlaudRouteURLProtocol.handler = { _ in (200, ["Content-Type": "audio/mpeg"], audio) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plaud-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let preferred = dir.appendingPathComponent("rec.mp3")

        let rec = PlaudRecording(id: "r1", title: "t", startTime: nil, duration: 1, fileSize: 0)
        let written = try await client().downloadAudio(rec, token: PlaudToken(accessToken: "t", region: .us), to: preferred)

        XCTAssertEqual(written.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: written), audio)
    }

    func testDownloadSwitchesExtensionToOpus() async throws {
        let audio = Data([0x4F, 0x67, 0x67, 0x53]) // "OggS"
        PlaudRouteURLProtocol.handler = { _ in (200, ["Content-Type": "audio/opus"], audio) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plaud-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let preferred = dir.appendingPathComponent("rec.mp3")

        let rec = PlaudRecording(id: "r1", title: "t", startTime: nil, duration: 1, fileSize: 0)
        let written = try await client().downloadAudio(rec, token: PlaudToken(accessToken: "t", region: .us), to: preferred)

        XCTAssertEqual(written.pathExtension, "opus")
        XCTAssertEqual(written.deletingPathExtension().lastPathComponent, "rec")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        // The requested .mp3 path was NOT left behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferred.path))
    }

    // MARK: - Fixtures

    /// A `data_file_list` page with the given start_times (epoch ms). Each item id
    /// is unique per index so dedup can distinguish them.
    static func listPage(startTimes: [Int]) -> Data {
        let items = startTimes.enumerated().map { i, t in
            #"{"id":"rec-\#(i)-\#(t)","fullname":"r","duration":1,"start_time":\#(t),"is_trash":false}"#
        }.joined(separator: ",")
        return #"{"status":0,"data_file_list":[\#(items)]}"#.data(using: .utf8)!
    }

    static func queryValue(_ name: String, _ url: URL?) -> String? {
        guard let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return comps.queryItems?.first { $0.name == name }?.value
    }
}

// MARK: - Route-based URLProtocol

/// A `URLProtocol` that answers each request via a caller-supplied `handler`
/// (status, headers, body) and records the requested URLs — enough to drive the
/// PLAUD login/list/download flows offline.
final class PlaudRouteURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requestedURLs: [URL] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        requestedURLs = []
    }

    static func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        requestedURLs.append(url)
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaudRouteURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.record(url) }
        let (status, headers, body) = Self.handler?(request) ?? (200, [:], Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
