import Foundation

/// The Eileen Darby Images REST API, v1.
///
/// One instance per base URL. Holds the access token in memory and the
/// refresh token for as long as it lives; the caller persists the refresh
/// token (see `TokenStore`) and hands it back on the next launch.
///
/// **Refresh on 401, not on a timer.** Every authenticated request that comes
/// back 401 is retried once after a refresh. If the refresh itself is refused
/// the client throws `.unauthenticated` and stops — a revoked device must not
/// loop, and the operator needs to be told to sign in again.
public actor ArchiveClient {
    public nonisolated let baseURL: URL
    public private(set) var refreshToken: String?
    private var accessToken: String?
    private let urlSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL, refreshToken: String? = nil, urlSession: URLSession? = nil) {
        // Normalise to a directory URL so relative paths append cleanly.
        var base = baseURL
        if !base.absoluteString.hasSuffix("/") {
            base = URL(string: base.absoluteString + "/") ?? base
        }
        self.baseURL = base
        self.refreshToken = refreshToken
        self.urlSession = urlSession ?? Self.makeSession()
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        decoder = d
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        encoder = e
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// Turn what an operator typed into a base URL: trims whitespace, assumes
    /// https when no scheme is given, and leaves the path alone — the API is
    /// mounted at `/api/v1` and the operator is expected to include that.
    public static func parseBaseURL(_ text: String) throws -> URL {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw ArchiveError.invalidBaseURL(text) }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            throw ArchiveError.invalidBaseURL(text)
        }
        return url
    }

    public var isSignedIn: Bool { refreshToken != nil }

    // MARK: - Authentication

    private struct CodeRequest: Encodable { var login: String; var password: String }
    private struct LoginRequest: Encodable { var login: String; var password: String; var code: String; var device: String }
    private struct RefreshRequest: Encodable { var refreshToken: String }

    /// Ask for the one-time code to be emailed. The reply is the same whether
    /// or not the account exists, by design.
    public func requestCode(login: String, password: String) async throws -> CodeResponse {
        try await send("POST", "auth/code", body: CodeRequest(login: login, password: password), authenticated: false)
    }

    /// Exchange login, password and the emailed code for tokens. On success
    /// the client is signed in; persist `refreshToken` from the response.
    public func login(login: String, password: String, code: String, device: String) async throws -> LoginResponse {
        let r: LoginResponse = try await send(
            "POST", "auth/login",
            body: LoginRequest(login: login, password: password, code: code, device: device),
            authenticated: false
        )
        accessToken = r.accessToken
        refreshToken = r.refreshToken
        return r
    }

    /// New access token from the refresh token. A refusal signs the client
    /// out: that is what a revoked or expired device looks like.
    @discardableResult
    public func refresh() async throws -> RefreshResponse {
        guard let refreshToken else { throw ArchiveError.unauthenticated }
        do {
            let r: RefreshResponse = try await send(
                "POST", "auth/refresh", body: RefreshRequest(refreshToken: refreshToken), authenticated: false
            )
            accessToken = r.accessToken
            return r
        } catch ArchiveError.http(let status, _) where status == 401 || status == 403 {
            signOut()
            throw ArchiveError.unauthenticated
        }
    }

    /// Forget the tokens. Local only; see `revoke(session:)` for the server side.
    public func signOut() {
        accessToken = nil
        refreshToken = nil
    }

    public func sessions() async throws -> [ArchiveSession] {
        let r: SessionsResponse = try await send("GET", "auth/sessions")
        return r.sessions
    }

    public func revoke(session id: Int) async throws {
        let _: Empty = try await send("DELETE", "auth/sessions/\(id)")
    }

    // MARK: - Shows

    private struct CreateShowRequest: Encodable {
        var category: String
        var number: Int
        var name: String?
    }

    public func searchShows(query: String, page: Int = 1, perpage: Int = 25) async throws -> ShowPage {
        try await send("GET", "shows", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "perpage", value: String(perpage)),
        ])
    }

    public func show(id: String) async throws -> ArchiveShow {
        try await send("GET", "shows/\(id)")
    }

    /// `201` with the created show; `409` if it exists. The server pads the
    /// number and composes the id.
    public func createShow(category: String, number: Int, name: String?) async throws -> ArchiveShow {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        return try await send("POST", "shows", body: CreateShowRequest(
            category: category, number: number, name: trimmed?.isEmpty == false ? trimmed : nil
        ))
    }

    public func inventory(show: String) async throws -> ArchiveInventory {
        try await send("GET", "shows/\(show)/inventory")
    }

    // MARK: - Assets

    private struct RegisterRequest: Encodable {
        var type: String
        var roll: String?
        var number: String?
        var first: String?
        var last: String?
        var format: Int
        /// The server defaults to 0; 1 is the JPEG that sits beside a RAW.
        var version: Int?
    }

    public func assets(show: String, type: String? = nil, page: Int = 1, perpage: Int = 200,
                       allVersions: Bool = false) async throws -> AssetPage {
        var q = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "perpage", value: String(perpage)),
        ]
        if let type { q.append(URLQueryItem(name: "type", value: type)) }
        if allVersions { q.append(URLQueryItem(name: "all_versions", value: "1")) }
        return try await send("GET", "shows/\(show)/assets", query: q)
    }

    /// Every canonical asset of one type, following the pages.
    public func allAssets(show: String, type: String) async throws -> [ArchiveAsset] {
        var all: [ArchiveAsset] = []
        var page = 1
        while true {
            let p = try await assets(show: show, type: type, page: page, perpage: 200)
            all.append(contentsOf: p.assets)
            let total = p.total ?? all.count
            if p.assets.isEmpty || all.count >= total || page > 50 { break }
            page += 1
        }
        return all
    }

    /// Register a run of assets. `first`/`last` in the API's notation ("1",
    /// "12A"). The whole batch is validated before anything is written; a
    /// `409` names the ones that already exist.
    public func registerAssets(show: String, type: String, roll: String?, first: String, last: String,
                               format: Int, version: Int? = nil) async throws -> AssetBatch {
        try await send("POST", "shows/\(show)/assets", body: RegisterRequest(
            type: type, roll: roll?.isEmpty == true ? nil : roll, number: nil,
            first: first, last: last, format: format, version: version
        ))
    }

    /// Register a single asset.
    public func registerAsset(show: String, type: String, roll: String?, number: String,
                              format: Int, version: Int? = nil) async throws -> AssetBatch {
        try await send("POST", "shows/\(show)/assets", body: RegisterRequest(
            type: type, roll: roll?.isEmpty == true ? nil : roll, number: number,
            first: nil, last: nil, format: format, version: version
        ))
    }

    /// Delete one version of an asset. **Needs access level 61**; a scanning
    /// station gets a 403, which the caller should expect and explain.
    public func deleteAssetVersion(show: String, asset: String, version: String) async throws {
        let _: Empty = try await send("DELETE", "shows/\(show)/assets/\(asset)/versions/\(version)")
    }

    // MARK: - Uploads

    private struct CreateUploadRequest: Encodable {
        var assetid: String
        var filename: String
        var bytes: Int
        var chunkSize: Int
        var sha256: String
        var chunks: [String]
        var attributes: CaptureAttributes?
    }

    /// Register a transfer and get the block list back. Nothing has moved yet.
    public func createUpload(assetID: String, filename: String, file: ChunkedFile,
                             attributes: CaptureAttributes? = nil) async throws -> ArchiveUpload {
        try await send("POST", "uploads", body: CreateUploadRequest(
            assetid: assetID, filename: filename, bytes: file.bytes, chunkSize: file.chunkSize,
            sha256: file.sha256, chunks: file.chunks, attributes: attributes
        ))
    }

    /// Send one block. The reply is the transfer's state; when this block
    /// was the last outstanding one, `state` is `complete` and the scan is
    /// filed — there is no separate completion call.
    public func putChunk(uploadID: Int, index: Int, data: Data) async throws -> ArchiveUpload {
        try await send("PUT", "uploads/\(uploadID)/chunks/\(index)", rawBody: data,
                       contentType: "application/octet-stream")
    }

    public func upload(id: Int) async throws -> ArchiveUpload {
        try await send("GET", "uploads/\(id)")
    }

    public func abandonUpload(id: Int) async throws {
        let _: Empty = try await send("DELETE", "uploads/\(id)")
    }

    // MARK: - Images

    /// A derivative's bytes — `thumbnail`, `gallery`, `subscriber` or
    /// `original`. The asset is named by its middle part (`NA0012`), the
    /// show being in the path. "Not made yet" is a 404 whose message says so,
    /// distinct from an asset that doesn't exist.
    public func image(show: String, asset: String, kind: String) async throws -> Data {
        try await download("shows/\(show)/assets/\(asset)/images/\(kind)")
    }

    /// GET raw bytes with the same token handling as `send`.
    private func download(_ path: String, retryOn401: Bool = true) async throws -> Data {
        var request = try makeRequest("GET", path, query: [])
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if accessToken == nil { try await refresh() }
        guard let token = accessToken else { throw ArchiveError.unauthenticated }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        if response.statusCode == 401, retryOn401 {
            try await refresh()
            return try await download(path, retryOn401: false)
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? decoder.decode(ErrorBody.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw ArchiveError.http(status: response.statusCode, message: message)
        }
        return data
    }

    // MARK: - Transport

    struct Empty: Decodable {}

    private func send<T: Decodable, B: Encodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: B,
        authenticated: Bool = true
    ) async throws -> T {
        let data: Data
        do { data = try encoder.encode(body) } catch { throw ArchiveError.decoding("could not encode request") }
        return try await send(method, path, query: query, rawBody: data,
                              contentType: "application/json", authenticated: authenticated)
    }

    private func send<T: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], rawBody: Data? = nil,
        contentType: String? = nil, authenticated: Bool = true, retryOn401: Bool = true
    ) async throws -> T {
        var request = try makeRequest(method, path, query: query)
        if let rawBody {
            request.httpBody = rawBody
            request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            if accessToken == nil { try await refresh() }
            guard let token = accessToken else { throw ArchiveError.unauthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await perform(request)
        let status = response.statusCode

        if status == 401, authenticated, retryOn401 {
            try await refresh()
            return try await send(method, path, query: query, rawBody: rawBody, contentType: contentType,
                                  authenticated: true, retryOn401: false)
        }
        guard (200..<300).contains(status) else {
            let message = (try? decoder.decode(ErrorBody.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw ArchiveError.http(status: status, message: message)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ArchiveError.decoding(String(describing: error))
        }
    }

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ArchiveError.invalidBaseURL(baseURL.absoluteString)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ArchiveError.invalidBaseURL(baseURL.absoluteString) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ArchiveError.badResponse }
            return (data, http)
        } catch let e as ArchiveError {
            throw e
        } catch {
            throw ArchiveError.network(error.localizedDescription)
        }
    }
}
