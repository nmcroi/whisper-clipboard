# PLAUD Cloud API — reverse-engineered contract

PLAUD has **no official public REST API**. This document captures the exact,
verified contract that Whisper Clipboard's native `PlaudClient` implements, so it
stays maintainable when PLAUD changes their web API.

Every fact below is cited to the open-source tool it was extracted from. The two
primary references were read verbatim from source and **agree on every endpoint**:

- **plaud-toolkit** (TypeScript) — `github.com/sergivalverde/plaud-toolkit`.
  Email+password login, `download`/`sync` CLI. The primary reference.
- **applaud** (TypeScript) — `github.com/rsteckler/applaud`.
  Polls `api.plaud.ai/file/simple/web`, auto-downloads. Used to cross-check.

> ⚠️ Unofficial. Not affiliated with or endorsed by PLAUD. It uses the same web
> API the PLAUD web app (`web.plaud.ai`) uses, with the user's own account.
> A recording only appears here **after it has synced from the NotePin to the
> PLAUD cloud** (via the official PLAUD phone app / dock).

---

## Base URLs (region hosts)

From `plaud-toolkit/packages/core/src/types.ts` (`BASE_URLS`):

```ts
export const BASE_URLS: Record<string, string> = {
  us: 'https://api.plaud.ai',
  eu: 'https://api-euc1.plaud.ai',
};
```

Cross-checked against `applaud/server/src/plaud/client.ts` (`REGION_API_BASES`),
which additionally documents an APAC host:

```ts
const REGION_API_BASES = {
  "aws:us-west-2":      "https://api.plaud.ai",
  "aws:eu-central-1":   "https://api-euc1.plaud.ai",
  "aws:ap-southeast-1": "https://api-apse1.plaud.ai",
};
const DEFAULT_API_BASE = "https://api.plaud.ai";
```

**Region auto-switch:** if a response body contains `status == -302` and
`data.domains.api`, the client must re-point to the host in that field and retry.
`plaud-toolkit/packages/core/src/client.ts`:

```ts
if (data?.status === -302 && data?.data?.domains?.api) {
  const domain = data.data.domains.api;
  this.region = domain.includes('euc1') ? 'eu' : 'us';
  return this.request(path, options);   // retry
}
```

Our implementation starts at the US host (`api.plaud.ai`) and follows this
`-302` redirect to the **exact host** in `data.domains.api` (not a collapsed
region enum, so a US-variant host is honoured rather than treated as "already
here"), bounded to a few hops to avoid a redirect loop. An EU account is thus
routed correctly without the user picking a region.

---

## Authentication — email + password → JWT bearer

**Preferred and implemented.** plaud-toolkit logs in with the user's PLAUD
email + password; no browser token-lift required. (applaud instead lifts a
`tokenstr` JWT from Chrome's leveldb — we do **not** do that; email+password is
cleaner and is our path. See "Fallback" below.)

From `plaud-toolkit/packages/core/src/auth.ts` (verbatim):

- **Endpoint:** `POST {baseUrl}/auth/access-token`
- **Content-Type:** `application/x-www-form-urlencoded`
- **Body:** `username=<email>&password=<password>` (password sent **plaintext**
  over HTTPS — this is what the PLAUD web app does)
- **Success check:** JSON `status == 0` **and** `access_token` present
- **Token field:** `access_token` (a JWT). `token_type` is `"Bearer"`.
- **Error message:** JSON `msg` (surfaced to the user on failure)

```ts
const baseUrl = BASE_URLS[creds.region] ?? BASE_URLS['us'];
const body = new URLSearchParams({ username: creds.email, password: creds.password });
const res = await requester({
  url: `${baseUrl}/auth/access-token`,
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: body.toString(),
});
const data = await res.json() as { status: number; msg?: string; access_token: string; token_type: string; };
if (data.status !== 0 || !data.access_token) {
  throw new Error(data.msg || `Login failed (status ${data.status})`);
}
```

**Token lifetime:** the JWT's `exp`/`iat` claims are decoded to know expiry.
plaud-toolkit refreshes (re-logs-in) when within **30 days** of expiry
(`TOKEN_REFRESH_BUFFER_MS = 30 * 24 * 60 * 60 * 1000`). Tokens last roughly
**~300 days** (README) / applaud says "~10 months". Because the token is long-
lived, we do not persist it: we log in fresh from the stored email+password when
needed and hold the token in memory for the session. (Simpler, and it means a
password change immediately takes effect.)

### Fallback (documented, not implemented): paste-a-token

If PLAUD ever breaks email+password login, applaud's approach still works: the
user pastes a bearer token. To obtain it manually:

1. Sign in to **https://web.plaud.ai** in a browser.
2. Open DevTools → Application/Storage → **Local Storage** for `web.plaud.ai`.
3. Copy the value of the **`tokenstr`** key (the raw JWT).
   (Source: `applaud/server/src/auth/chrome-leveldb.ts` reads `tokenstr` for
   `web.plaud.ai`.)

That token is then used directly as `Authorization: Bearer <token>` — identical
to the login-returned token. Our `PlaudClient` accepts a raw token as well as
email+password, so wiring a "paste token" field later is trivial.

---

## Required headers

From `plaud-toolkit/packages/core/src/client.ts` — every authenticated request:

```ts
headers: {
  'Authorization': `Bearer ${token}`,
  'Content-Type': 'application/json',
}
```

applaud additionally sends a desktop-Safari `user-agent` and `accept: application/json`
(`applaud/server/src/plaud/client.ts`). A browser-like `User-Agent` is harmless
and slightly more robust against WAF filtering, so we set one too. The login
request uses `Content-Type: application/x-www-form-urlencoded` (see above); all
other requests use `application/json`.

---

## List recordings

- **Endpoint:** `GET {baseUrl}/file/simple/web`
- **Auth:** `Authorization: Bearer <token>`
- **Query params** (from `applaud/server/src/plaud/list.ts`):
  `skip` (default `0`), `limit` (default `50`), `is_trash` (default `2` = not
  trashed), `sort_by` (default `start_time`), `is_desc` (default `true`).
  Example: `?skip=0&limit=50&is_trash=2&sort_by=start_time&is_desc=true`
- **Response array:** the recordings live under `data_file_list`, with
  `data` as a fallback. plaud-toolkit then filters out `is_trash`:

```ts
// plaud-toolkit client.ts
const data = await this.request('/file/simple/web');
const list = data.data_file_list ?? data.data ?? [];
return list.filter(r => !r.is_trash);
```

- **Pagination:** page while a full page comes back (`data_file_list.length >= limit`),
  incrementing `skip`. (`applaud/list.ts` loops until a short page.)

### Recording shape

From `plaud-toolkit/packages/core/src/types.ts` (`PlaudRecording`):

```ts
export interface PlaudRecording {
  id: string;            // recording id — used for download + dedup key
  filename: string;      // short name / stem
  fullname: string;      // display name
  filesize: number;      // bytes
  duration: number;      // seconds
  start_time: number;    // epoch (see note) — recording start
  end_time: number;      // epoch
  is_trash: boolean;
  is_trans: boolean;     // PLAUD-side transcription done?
  is_summary: boolean;
  keywords: string[];
  serial_number: string; // NotePin serial
}
```

- **id:** `id`. Used both as the download key and the dedup key in
  `plaud-processed.json`.
- **title:** prefer `fullname`, fall back to `filename`, then `id`.
- **timestamp:** `start_time`. Numeric epoch. PLAUD uses **milliseconds** in
  practice; our parser accepts both (values > 10^12 are treated as ms, else s).
- **duration:** `duration` (seconds).

The detail endpoint (`GET /file/detail/{id}`, fields `file_id` / `file_name`,
plus a `pre_download_content_list` carrying PLAUD's own transcript) exists but
we do **not** use it — Whisper Clipboard transcribes the audio itself.

---

## Download audio

Two independent paths, both verified. We use the **direct download** path as the
primary (one call, no presigned-URL round-trip), with the **temp-url** path as a
fallback.

### Primary — direct binary download

`plaud-toolkit/packages/core/src/client.ts` (`downloadAudio`):

```ts
async downloadAudio(id) {
  const token = await this.auth.getToken();
  const res = await requester({
    url: `${this.baseUrl}/file/download/${id}`,
    headers: { 'Authorization': `Bearer ${token}` },
  });
  if (!res.ok) throw new Error(`Download failed: ${res.status}`);
  return res.arrayBuffer();
}
```

- **Endpoint:** `GET {baseUrl}/file/download/{id}`
- **Auth:** `Authorization: Bearer <token>` (no JSON content-type — it returns bytes)
- **Body:** raw audio bytes.

### Fallback — presigned URL then fetch

`plaud-toolkit` (`getMp3Url`) and `applaud/server/src/plaud/audio.ts`:

```ts
// plaud-toolkit
const data = await this.request(`/file/temp-url/${id}?is_opus=false`);
return data?.url ?? data?.data?.url ?? data?.data ?? data?.temp_url ?? null;
```

```ts
// applaud audio.ts — response field is temp_url; then fetch(url) → stream to disk
`/file/temp-url/${id}${opus ? '?is_opus=1' : ''}`  →  { temp_url: <presigned S3 URL> }
```

- **Endpoint:** `GET {baseUrl}/file/temp-url/{id}?is_opus=false`
- **Response URL field:** `temp_url` (or `url` / `data.url` / `data`).
- The returned URL is a **presigned S3 URL**; fetch it directly (no auth header)
  to stream the bytes.

### Format

- `is_opus=false` → the MP3 rendition (what we request).
- `is_opus=true`/`1` → the Opus rendition.

We request `is_opus=false` and default the on-disk name to `.mp3` into
`~/Library/Application Support/Whisper Clipboard v2/PLAUD/`, then hand it to
`FileImportService`. When the response advertises a **different** format via
`Content-Type` (e.g. `audio/opus`) or a `Content-Disposition` filename, the saved
file's extension is switched to match (`.opus`, `.m4a`, `.wav`, …) so the on-disk
extension never lies about the container. Whisper Clipboard's importer decodes via
AVFoundation, which handles MP3 and other common containers; a decode failure
surfaces as a normal per-file import error.

The download itself uses `URLSession.download(for:)` (streamed to a temp file by
the framework, then `moveItem` into place) — no manual per-byte read loop — and
cleans up any partial file on failure.

---

## Endpoint summary (what we implement)

| Purpose      | Method | Path                                   | Auth            | Notes |
|--------------|--------|----------------------------------------|-----------------|-------|
| Login        | POST   | `/auth/access-token`                   | none            | form body `username`,`password`; token in `access_token`, ok when `status==0` |
| List         | GET    | `/file/simple/web?skip=&limit=&is_trash=2&sort_by=start_time&is_desc=true` | Bearer | array in `data_file_list` |
| Download     | GET    | `/file/download/{id}`                  | Bearer          | raw audio bytes (primary) |
| Download URL | GET    | `/file/temp-url/{id}?is_opus=false`    | Bearer          | presigned S3 url in `temp_url` (fallback) |

Base host: `https://api.plaud.ai` (US, default) · `https://api-euc1.plaud.ai` (EU)
· `https://api-apse1.plaud.ai` (APAC). Region auto-switch on body `status == -302`.

---

## Sources (files read verbatim)

- `sergivalverde/plaud-toolkit` — `packages/core/src/auth.ts`,
  `packages/core/src/client.ts`, `packages/core/src/types.ts`,
  `packages/core/src/config.ts` (login, headers, endpoints, region map, shapes).
- `rsteckler/applaud` — `server/src/plaud/client.ts` (region hosts, headers,
  user-agent), `server/src/plaud/list.ts` (list query params + pagination),
  `server/src/plaud/audio.ts` (temp-url + presigned S3 download),
  `server/src/auth/chrome-leveldb.ts` (the `tokenstr` browser-token fallback).

_Last verified: 2026-07 against both repos' `main` branch._
