import Foundation

// MARK: - Errors (Dutch, user-facing)

/// Typed errors from the PLAUD client, each with a Dutch, user-facing message.
enum PlaudError: Error, LocalizedError, Equatable {
    /// No credentials configured (no email+password and no token).
    case missingCredentials
    /// Login rejected — bad email/password, or an expired/invalid token.
    case authFailed(String)
    /// Network offline / could not reach PLAUD.
    case network
    /// 429 — rate limited by PLAUD.
    case rateLimited
    /// The response wasn't the shape we expected (API changed, or unexpected body).
    case unexpectedResponse(String)
    /// Any other HTTP failure, with the server message when present.
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Stel eerst je PLAUD e-mailadres en wachtwoord in bij Instellingen."
        case .authFailed(let message):
            return message.isEmpty
                ? "Inloggen bij PLAUD mislukte. Controleer je e-mailadres en wachtwoord."
                : "Inloggen bij PLAUD mislukte: \(message)"
        case .network:
            return "Geen verbinding met PLAUD. Controleer je internetverbinding."
        case .rateLimited:
            return "PLAUD beperkt het aantal aanvragen. Probeer het over een moment opnieuw."
        case .unexpectedResponse(let detail):
            return detail.isEmpty
                ? "Onverwacht antwoord van PLAUD. Mogelijk is hun API gewijzigd."
                : "Onverwacht antwoord van PLAUD: \(detail)"
        case .server(let message):
            return message.isEmpty
                ? "Er ging iets mis bij het benaderen van PLAUD."
                : "PLAUD gaf een fout: \(message)"
        }
    }
}

// MARK: - Region

/// A PLAUD API endpoint. See `Packaging/PLAUD_API_NOTES.md`.
/// The three named cases are the documented region hosts (plaud-toolkit
/// `BASE_URLS` / applaud `REGION_API_BASES`); `.custom` carries the **exact**
/// base URL from a `-302` redirect so we follow the host PLAUD actually points
/// us at — including US-variant hosts that don't match a named case — rather
/// than collapsing every non-EU/APAC host back to `.us` (which would make a
/// redirect a no-op and mis-parse the redirect body as a login result).
enum PlaudRegion: Sendable, Equatable {
    case us
    case eu
    case apac
    /// An arbitrary base URL from a redirect (`data.domains.api`), e.g.
    /// `https://api-usw2.plaud.ai`. Normalized (scheme + host, no trailing slash).
    case custom(baseURL: String)

    var baseURL: String {
        switch self {
        case .us: return "https://api.plaud.ai"
        case .eu: return "https://api-euc1.plaud.ai"
        case .apac: return "https://api-apse1.plaud.ai"
        case .custom(let url): return url
        }
    }

    /// Builds a region from a redirect `domains.api` value. Prefers a named case
    /// when the host matches a known region (so equality/telemetry stay tidy),
    /// otherwise carries the exact base URL via `.custom`. Normalizes to a bare
    /// `scheme://host` (drops any path/trailing slash); returns `nil` when the
    /// value can't be turned into an absolute `https`/`http` base URL.
    static func from(redirectHost host: String) -> PlaudRegion? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Accept either a bare host ("api-euc1.plaud.ai") or a full URL.
        let raw = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let comps = URLComponents(string: raw),
              let hostName = comps.host, !hostName.isEmpty else { return nil }
        // Security: login re-POSTs the account email+password to this host, so only
        // honour a redirect that stays on PLAUD's own domain and uses https. A
        // compromised/misconfigured login endpoint therefore cannot harvest
        // credentials by pointing us at an attacker host (or downgrading to http).
        let lowerHost = hostName.lowercased()
        guard lowerHost == "plaud.ai" || lowerHost.hasSuffix(".plaud.ai") else { return nil }
        guard (comps.scheme ?? "https") == "https" else { return nil }
        let normalized = "https://\(hostName)"

        // Prefer a named case when it's exactly a known region host.
        for named: PlaudRegion in [.us, .eu, .apac] where named.baseURL == normalized {
            return named
        }
        return .custom(baseURL: normalized)
    }
}

// MARK: - Recording model

/// One PLAUD cloud recording. Field names mirror PLAUD's `PlaudRecording` shape
/// (plaud-toolkit `types.ts`).
struct PlaudRecording: Equatable, Sendable, Identifiable {
    /// PLAUD recording id — the download key **and** the dedup key.
    let id: String
    /// Best display title (`fullname` → `filename` → `id`).
    let title: String
    /// Recording start, normalized to a `Date` (PLAUD sends epoch ms or s).
    let startTime: Date?
    /// Duration in seconds.
    let duration: Double
    /// Size in bytes (0 when unknown).
    let fileSize: Int64

    /// A filesystem-safe filename stem (no extension) for the downloaded audio.
    /// Combines a date prefix (when known) with the sanitized title, and always
    /// includes the id so two same-named recordings never collide on disk.
    var suggestedFilenameStem: String {
        let safeTitle = Self.sanitize(title)
        let datePart: String
        if let startTime {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd_HHmm"
            datePart = f.string(from: startTime) + "_"
        } else {
            datePart = ""
        }
        let shortId = String(id.prefix(8))
        let base = safeTitle.isEmpty ? "PLAUD" : safeTitle
        return "\(datePart)\(base)_\(shortId)"
    }

    /// Strips path/filename-hostile characters and collapses whitespace.
    static func sanitize(_ raw: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = raw.components(separatedBy: disallowed).joined(separator: " ")
        let collapsed = cleaned.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Token

/// A PLAUD access token plus the raw region host that issued/serves it.
struct PlaudToken: Equatable, Sendable {
    let accessToken: String
    let region: PlaudRegion
}

// MARK: - Client

/// URLSession client implementing the reverse-engineered PLAUD cloud API.
///
/// No SDK. The **pure** request-building (`makeLoginRequest`,
/// `makeListRequest`, `makeDownloadRequest`) and **pure** response-parsing
/// (`parseLoginResponse`, `parseListResponse`, `redirectRegion`) are static so
/// they can be unit-tested against canned bytes with no network. The stateful
/// `PlaudClient` composes them and performs the I/O.
///
/// See `Packaging/PLAUD_API_NOTES.md` for the full contract + citations.
struct PlaudClient {

    /// A browser-like UA — harmless and slightly more robust against WAF filtering.
    /// applaud sends a desktop-Safari UA on every call.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Default list-page size (plaud-toolkit / applaud use 50).
    static let pageSize = 50

    private let session: URLSession
    /// The region to start requests from (US by default). May be updated by a
    /// `-302` redirect during a call and returned via ``PlaudToken``.
    let region: PlaudRegion

    init(session: URLSession = .shared, region: PlaudRegion = .us) {
        self.session = session
        self.region = region
    }

    // MARK: Login

    /// Max number of `-302` region redirects to follow during login before giving
    /// up (guards against a redirect loop).
    static let maxLoginRedirects = 3

    /// Logs in with email + password, returning a bearer token (and the endpoint
    /// that served it). Follows `-302` region redirects to the **actual host** in
    /// the redirect body, bounded by ``maxLoginRedirects``.
    func login(email: String, password: String) async throws -> PlaudToken {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password
        guard !trimmedEmail.isEmpty, !trimmedPassword.isEmpty else {
            throw PlaudError.missingCredentials
        }

        var currentRegion = region
        // Initial attempt + up to `maxLoginRedirects` redirect follows.
        for _ in 0...Self.maxLoginRedirects {
            let request = Self.makeLoginRequest(email: trimmedEmail, password: trimmedPassword, region: currentRegion)
            let (data, http) = try await perform(request)

            // A -302 redirect is delivered as a 200 body; check before status
            // gating. Follow it only when it points at a *different* host than the
            // one we just hit (comparing the real base URL, not a collapsed enum),
            // so a redirect to a US-variant host is honoured instead of being
            // mistaken for the current region and its body parsed as a login result.
            if let redirect = Self.redirectRegion(fromBody: data),
               redirect.baseURL != currentRegion.baseURL {
                currentRegion = redirect
                continue
            }

            guard (200..<300).contains(http.statusCode) else {
                throw Self.mapHTTPError(status: http.statusCode, body: data, context: .login)
            }
            let token = try Self.parseLoginResponse(data)
            return PlaudToken(accessToken: token, region: currentRegion)
        }
        throw PlaudError.unexpectedResponse("herhaalde regio-omleiding")
    }

    /// Resolves a usable token from credentials: a pasted token is used directly
    /// (validated by a cheap list call by the caller); otherwise email+password
    /// login runs.
    func token(for credentials: PlaudCredentials) async throws -> PlaudToken {
        let pasted = credentials.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pasted.isEmpty {
            return PlaudToken(accessToken: pasted, region: region)
        }
        return try await login(email: credentials.email, password: credentials.password)
    }

    // MARK: List

    /// Hard cap on how many pages a single list call will fetch, so pagination is
    /// always bounded even if PLAUD never returns a short page and no `since`
    /// stop-condition ever fires (e.g. a run of pages with no usable timestamps).
    /// At `pageSize == 50` this bounds a full-history walk to 5 000 recordings.
    static let maxListPages = 100

    /// Lists recordings, newest first, paging until PLAUD returns a short page.
    /// `since` (when provided) stops early: once a page contains an item at/older
    /// than `since`, remaining older pages are skipped and out-of-range items
    /// filtered out. Trashed items are already excluded server-side (`is_trash=2`)
    /// and again client-side.
    ///
    /// `limit` overrides the per-page size (used by the connection test to fetch a
    /// single item cheaply). Pagination is bounded by ``maxListPages`` regardless.
    func listRecordings(token: PlaudToken, since: Date? = nil, limit: Int = pageSize) async throws -> [PlaudRecording] {
        let pageLimit = max(1, limit)
        var all: [PlaudRecording] = []
        var skip = 0
        var pagesFetched = 0
        while pagesFetched < Self.maxListPages {
            let request = Self.makeListRequest(token: token, skip: skip, limit: pageLimit)
            let (data, http) = try await perform(request)
            guard (200..<300).contains(http.statusCode) else {
                throw Self.mapHTTPError(status: http.statusCode, body: data, context: .list)
            }
            let page = try Self.parseListResponse(data)
            all.append(contentsOf: page)
            pagesFetched += 1

            // Stop when the page wasn't full (no more data).
            if page.count < pageLimit { break }
            // Stop when we've paged past `since` (list is sorted desc by
            // start_time): if any item on this page is at/older than `since`, older
            // pages can only be older still. `compactMap` skips items with no
            // timestamp; when a *whole* page lacks timestamps this can't fire, so
            // the `maxListPages` cap above is what bounds that pathological case —
            // not an unbounded 10k-item walk.
            if let since, let oldest = page.compactMap(\.startTime).min(), oldest <= since {
                break
            }
            skip += pageLimit
        }

        if let since {
            all = all.filter { ($0.startTime ?? .distantPast) > since }
        }
        return all
    }

    /// A cheap, single-request authenticated call used to validate a token/login:
    /// one list page of `limit` (default 1), **no** paging and no `since` heuristic.
    /// Throws on any auth/network/HTTP failure; the returned recordings are
    /// irrelevant (the connection test only cares that the call succeeded).
    @discardableResult
    func probeConnection(token: PlaudToken, limit: Int = 1) async throws -> [PlaudRecording] {
        let request = Self.makeListRequest(token: token, skip: 0, limit: max(1, limit))
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTPError(status: http.statusCode, body: data, context: .list)
        }
        return try Self.parseListResponse(data)
    }

    // MARK: Download

    /// Downloads a recording's audio near `destination` (a preferred file path the
    /// caller owns; its extension is a hint — `.mp3` by default). Tries the direct
    /// `/file/download/{id}` path first; on failure falls back to the presigned-URL
    /// (`/file/temp-url`) path. Downloads to a temp file then moves it into place.
    ///
    /// Returns the URL actually written, whose extension may differ from
    /// `destination`'s when the server advertises a different audio format (e.g.
    /// opus) via `Content-Type`/`Content-Disposition`. Callers must use the
    /// returned URL, not the passed `destination`.
    @discardableResult
    func downloadAudio(_ recording: PlaudRecording, token: PlaudToken, to destination: URL) async throws -> URL {
        // Primary: presigned URL with is_opus=false — this yields a
        // macOS-decodable rendition (mp3/wav). PLAUD's raw device recordings are
        // Opus, which AudioToolbox/AVFoundation on macOS CANNOT decode, so the
        // direct binary download returns files the transcription pipeline can't
        // open. The presigned non-opus path is therefore the correct primary.
        do {
            let presigned = try await fetchPresignedURL(id: recording.id, token: token)
            var req = URLRequest(url: presigned)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            return try await downloadToFile(req, preferredDestination: destination)
        } catch let primaryError {
            // Fallback: direct binary download (only useful when PLAUD serves a
            // decodable container for this recording).
            do {
                let request = Self.makeDownloadRequest(id: recording.id, token: token)
                return try await downloadToFile(request, preferredDestination: destination)
            } catch {
                // Prefer the more specific/primary error when the fallback also failed.
                throw primaryError
            }
        }
    }

    /// Requests a presigned download URL via `/file/temp-url/{id}?is_opus=false`.
    private func fetchPresignedURL(id: String, token: PlaudToken) async throws -> URL {
        let request = Self.makeTempURLRequest(id: id, token: token)
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTPError(status: http.statusCode, body: data, context: .download)
        }
        guard let urlString = Self.parseTempURLResponse(data), let url = URL(string: urlString) else {
            throw PlaudError.unexpectedResponse("geen download-URL ontvangen")
        }
        return url
    }

    // MARK: - I/O helpers

    /// Performs a request, buffering the (small, JSON) response body and mapping
    /// URL/transport errors to typed ``PlaudError``.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PlaudError.unexpectedResponse("geen HTTP-antwoord")
            }
            return (data, http)
        } catch let urlError as URLError {
            throw Self.mapURLError(urlError)
        } catch let plaud as PlaudError {
            throw plaud
        }
    }

    /// Downloads a response body to disk near `preferredDestination`, letting
    /// `URLSession` stream it to a temp file (memory stays bounded regardless of
    /// size — no manual per-byte loop). Non-2xx becomes a typed error. The final
    /// extension is derived from the server's advertised format when known,
    /// otherwise `preferredDestination`'s extension is kept.
    ///
    /// Returns the URL actually written.
    private func downloadToFile(_ request: URLRequest, preferredDestination: URL) async throws -> URL {
        let tmp: URL
        let response: URLResponse
        do {
            (tmp, response) = try await session.download(for: request)
        } catch let urlError as URLError {
            throw Self.mapURLError(urlError)
        }
        // The temp file is cleaned up by the OS, but remove it eagerly on any
        // early exit so a rejected download never leaves a stray file behind.
        var consumedTmp = false
        defer { if !consumedTmp { try? FileManager.default.removeItem(at: tmp) } }

        guard let http = response as? HTTPURLResponse else {
            throw PlaudError.unexpectedResponse("geen HTTP-antwoord")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Read a bounded slice of the (error) body to surface any message.
            var raw = (try? Data(contentsOf: tmp)) ?? Data()
            if raw.count > 8192 { raw = raw.prefix(8192) }
            throw Self.mapHTTPError(status: http.statusCode, body: raw, context: .download)
        }

        let destination = Self.finalDestination(preferred: preferredDestination, response: http)

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: tmp, to: destination)
            consumedTmp = true
        } catch {
            // The move failed: make sure we don't leave a half-written partial
            // file at `destination` (double-download / retry safety).
            try? fm.removeItem(at: destination)
            throw PlaudError.server(error.localizedDescription)
        }
        return destination
    }

    /// Picks the file to write to: `preferred`, but with its extension swapped to
    /// match the server-advertised audio format (from `Content-Type`, or a
    /// `Content-Disposition` filename) when that is known and differs. Falls back
    /// to `preferred`'s extension (`.mp3`) otherwise.
    static func finalDestination(preferred: URL, response: HTTPURLResponse) -> URL {
        guard let ext = downloadExtension(from: response) else { return preferred }
        if preferred.pathExtension.lowercased() == ext { return preferred }
        return preferred.deletingPathExtension().appendingPathExtension(ext)
    }

    /// Derives a lowercase file extension for the downloaded audio from the
    /// response's `Content-Type` (preferred) or a `Content-Disposition` filename.
    /// Returns `nil` when nothing usable is advertised (caller keeps `.mp3`).
    static func downloadExtension(from response: HTTPURLResponse) -> String? {
        if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
           let ext = audioExtension(forContentType: contentType) {
            return ext
        }
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let name = filename(fromContentDisposition: disposition) {
            let ext = (name as NSString).pathExtension.lowercased()
            if !ext.isEmpty { return ext }
        }
        return nil
    }

    /// Maps a MIME `Content-Type` (ignoring any `; charset=…` suffix) to an audio
    /// file extension. Only the formats PLAUD is known to serve are mapped; an
    /// unknown/generic type (e.g. `application/octet-stream`) returns `nil` so the
    /// caller keeps the requested `.mp3`.
    static func audioExtension(forContentType contentType: String) -> String? {
        let mime = contentType
            .split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? contentType.lowercased()
        switch mime {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/opus", "audio/ogg", "application/ogg": return "opus"
        case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        default: return nil
        }
    }

    /// Extracts a `filename` from a `Content-Disposition` header value, handling
    /// both `filename="x.opus"` and RFC 5987 `filename*=UTF-8''x.opus`.
    static func filename(fromContentDisposition value: String) -> String? {
        for part in value.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("filename*=") {
                // RFC 5987: filename*=UTF-8''percent-encoded-name
                let raw = String(trimmed.dropFirst("filename*=".count))
                let afterCharset = raw.components(separatedBy: "''").last ?? raw
                return afterCharset.removingPercentEncoding ?? afterCharset
            }
            if trimmed.lowercased().hasPrefix("filename=") {
                var name = String(trimmed.dropFirst("filename=".count))
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !name.isEmpty { return name }
            }
        }
        return nil
    }
}
