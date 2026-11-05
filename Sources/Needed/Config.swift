import Foundation

enum Config {
    /// needed-server on Cloud Run (REST + WS /v1/stream).
    static let apiBase = URL(string: "https://api.lovearound.me")!
    /// Firebase Web API key: public, identifies the project to Firebase Auth.
    static let firebaseAPIKey = "AIzaSyBZJfln_KXsxRxo3fvVaV1ePmiVUIn5YXY"
    /// The site: install page, invite links /i/<code>, Google sign-in bridge /signin/.
    static let site = "https://lovearound.me"
    /// Links the app opens: lovearound://add/<code>, lovearound://signin?….
    static let urlScheme = "lovearound"
    /// Plus the codename's needed://, which older builds of the site still send.
    static let urlSchemes: Set<String> = [urlScheme, "needed"]
    /// Sent as `X-Client` with every request, so the server logs which version sent what.
    static let client = "mac/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
}
