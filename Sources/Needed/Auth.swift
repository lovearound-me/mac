import Foundation

/// A signed-in Firebase account. Only the refresh token is kept; ID tokens
/// live in memory.
struct Session: Codable {
    var uid: String
    var email: String?
    var refreshToken: String
}

enum AuthError: LocalizedError {
    case signedOut
    /// A Firebase Auth error code, e.g. "EMAIL_EXISTS".
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut:
            return tr("Нужно войти заново")
        case .server(let code):
            let code = code.components(separatedBy: " ").first ?? code
            switch code {
            case "TOO_MANY_ATTEMPTS_TRY_LATER": return tr("Слишком много попыток, попробуй чуть позже")
            case "USER_DISABLED": return tr("Этот аккаунт отключён")
            case "BAD_CALLBACK": return tr("Вход не завершился, попробуй ещё раз")
            default: return tr("Не получилось войти ({code})", ["code": code])
            }
        }
    }

    /// Errors after which the stored session is useless.
    var endsSession: Bool {
        switch self {
        case .signedOut: return true
        case .server(let code):
            return ["TOKEN_EXPIRED", "USER_DISABLED", "USER_NOT_FOUND", "INVALID_REFRESH_TOKEN", "INVALID_GRANT_TYPE"]
                .contains { code.hasPrefix($0) }
        }
    }
}

/// Firebase Auth over its REST API. Signing in (Apple, Google or email) happens
/// on the site's /signin/ page in the browser, which hands the session back via
/// lovearound://signin, sealed to a one-time key of ours (SignInBox.swift).
@MainActor
final class Auth {
    private(set) var session: Session?
    private var idToken: String?
    private var expiresAt = Date.distantPast
    private var refreshing: Task<String, Error>?
    /// The sign-in page asked for and not answered yet: opening it again
    /// reuses it, so whichever tab finishes first signs in.
    private var pending: (url: URL, state: String, key: SignInKey)?
    private let file: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Migration.supportFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("session.json")
        if let data = try? Data(contentsOf: file) {
            session = try? JSONDecoder().decode(Session.self, from: data)
        }
    }

    /// A valid ID token, refreshed when it is about to expire.
    func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let idToken, expiresAt.timeIntervalSinceNow > 300 {
            return idToken
        }
        if let refreshing {
            return try await refreshing.value
        }
        let task = Task { try await self.refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard let session else { throw AuthError.signedOut }
        var req = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(Config.firebaseAPIKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: session.refreshToken),
        ]
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let json = try await Self.call(req)
        guard let id = json["id_token"] as? String, let refreshToken = json["refresh_token"] as? String else {
            throw AuthError.server("BAD_RESPONSE")
        }
        idToken = id
        expiresAt = Date().addingTimeInterval(Double(json["expires_in"] as? String ?? "") ?? 3600)
        if refreshToken != session.refreshToken {
            self.session?.refreshToken = refreshToken
            save()
        }
        return id
    }

    /// How this session signed in, from the ID token: "apple.com",
    /// "google.com" or "password". Nil until a token has been fetched.
    var provider: String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let firebase = claims["firebase"] as? [String: Any] else { return nil }
        return firebase["sign_in_provider"] as? String
    }

    // ---- signing in, through the site ---------------------------------------

    /// The page that signs in (Apple, Google or email) and returns to
    /// lovearound://signin, with the session sealed to our one-time key.
    func signInURL() -> URL {
        if let pending { return pending.url }
        let state = UUID().uuidString
        let key = SignInKey()
        let url = URL(string: "\(Config.site)/signin?state=\(state)&key=\(key.publicKey)")!
        pending = (url, state, key)
        return url
    }

    /// lovearound://signin?state=…&epk=…&box=…, the box holding uid, email and
    /// the refresh token. Only the box: the page sends them in the clear just
    /// to builds that open it without key=, and this one always sends a key.
    func completeSignIn(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        // The state proves the callback answers our own request, so a crafted
        // link cannot sign the app into someone else's account.
        guard let pending, q["state"] == pending.state else { throw AuthError.server("BAD_CALLBACK") }
        guard let sealed = pending.key.open(epk: q["epk"] ?? "", box: q["box"] ?? "", state: pending.state),
              !sealed.uid.isEmpty, !sealed.rt.isEmpty else { throw AuthError.server("BAD_CALLBACK") }
        self.pending = nil
        adopt(Session(uid: sealed.uid, email: sealed.email, refreshToken: sealed.rt))
        _ = try await token(forceRefresh: true)
    }

    // ---- session ------------------------------------------------------------

    func signOut() {
        session = nil
        idToken = nil
        expiresAt = .distantPast
        try? FileManager.default.removeItem(at: file)
    }

    private func adopt(_ session: Session) {
        self.session = session
        idToken = nil
        expiresAt = .distantPast
        save()
    }

    /// Readable by this user only from the first byte: a new file opened 0600,
    /// then renamed over the old one (atomic, and fine with no old file yet).
    private func save() {
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        let temp = file.deletingLastPathComponent().appendingPathComponent(".session-\(UUID().uuidString).json")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let written = (try? handle.write(contentsOf: data)) != nil
        try? handle.close()
        if !written || rename(temp.path, file.path) != 0 {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private static func call(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = json["error"] as? [String: Any]
            throw AuthError.server(error?["message"] as? String ?? "HTTP_\(status)")
        }
        return json
    }
}
