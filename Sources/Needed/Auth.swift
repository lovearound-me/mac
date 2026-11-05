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
            case "INVALID_PASSWORD": return tr("Неверный пароль. Если раньше вход был через Google, нажми «Назад» и «Войти через Google»")
            case "WEAK_PASSWORD": return tr("Пароль слишком простой")
            case "INVALID_EMAIL", "MISSING_EMAIL": return tr("Проверь адрес почты")
            case "MISSING_PASSWORD": return tr("Введи пароль")
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

/// Firebase Auth over its REST API: email+password directly, Google through
/// the site's /signin/ page, which hands the session back via lovearound://signin,
/// sealed to a one-time key of ours (SignInBox.swift).
@MainActor
final class Auth {
    private(set) var session: Session?
    private var idToken: String?
    private var expiresAt = Date.distantPast
    private var refreshing: Task<String, Error>?
    private var googleState: String?
    private var googleKey: SignInKey?
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

    // ---- email + password ---------------------------------------------------

    /// Signs in, or creates the account when the email is new.
    func signIn(email: String, password: String) async throws {
        do {
            try await emailCall("signInWithPassword", email: email, password: password)
        } catch AuthError.server(let code) where code.hasPrefix("EMAIL_NOT_FOUND") || code.hasPrefix("INVALID_LOGIN_CREDENTIALS") {
            // With email enumeration protection both cases look the same:
            // try to create the account, and an existing email means a wrong password.
            do {
                try await emailCall("signUp", email: email, password: password)
            } catch AuthError.server(let code) where code.hasPrefix("EMAIL_EXISTS") {
                throw AuthError.server("INVALID_PASSWORD")
            }
        }
    }

    func sendPasswordReset(email: String) async throws {
        _ = try await Self.post("accounts:sendOobCode", ["requestType": "PASSWORD_RESET", "email": email])
    }

    private func emailCall(_ method: String, email: String, password: String) async throws {
        let json = try await Self.post("accounts:\(method)", ["email": email, "password": password, "returnSecureToken": true])
        guard let uid = json["localId"] as? String,
              let id = json["idToken"] as? String,
              let refreshToken = json["refreshToken"] as? String else {
            throw AuthError.server("BAD_RESPONSE")
        }
        adopt(Session(uid: uid, email: json["email"] as? String ?? email, refreshToken: refreshToken))
        idToken = id
        expiresAt = Date().addingTimeInterval(Double(json["expiresIn"] as? String ?? "") ?? 3600)
    }

    // ---- Google, through the site -------------------------------------------

    /// The page that signs in with Google and returns to lovearound://signin,
    /// with the session sealed to our one-time key.
    func googleSignInURL() -> URL {
        let state = UUID().uuidString
        let key = SignInKey()
        googleState = state
        googleKey = key
        return URL(string: "\(Config.site)/signin?state=\(state)&key=\(key.publicKey)")!
    }

    /// lovearound://signin?state=…&epk=…&box=…, the box holding uid, email and
    /// the refresh token. The site before the box sent them in the clear
    /// (needed://signin?state=…&uid=…&email=…&rt=…); that is still accepted
    /// until the site with the box is published.
    func completeGoogle(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        // The state proves the callback answers our own request, so a crafted
        // link cannot sign the app into someone else's account.
        guard let state = googleState, q["state"] == state else { throw AuthError.server("BAD_CALLBACK") }
        let sealed: SignInKey.Sealed?
        if let box = q["box"] {
            sealed = googleKey?.open(epk: q["epk"] ?? "", box: box, state: state)
        } else {
            sealed = SignInKey.Sealed(uid: q["uid"] ?? "", email: q["email"], rt: q["rt"] ?? "")
        }
        guard let sealed, !sealed.uid.isEmpty, !sealed.rt.isEmpty else { throw AuthError.server("BAD_CALLBACK") }
        googleState = nil
        googleKey = nil
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

    private func save() {
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func post(_ method: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/\(method)?key=\(Config.firebaseAPIKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await call(req)
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
