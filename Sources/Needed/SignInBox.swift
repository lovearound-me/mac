import CryptoKit
import Foundation

/// The Google sign-in box: the site seals the session to a one-time key of
/// the app, so the lovearound://signin link that carries it back is useless
/// to whoever else sees it (the browser's history, another app that
/// registered the scheme).
///
/// ECDH P-256 between our key and the page's (`epk`, the raw uncompressed
/// point), HKDF-SHA256 (no salt, info "lovearound signin v1") → AES-256-GCM
/// key, the state as associated data; box = 12-byte nonce + ciphertext + tag.
/// Base64url without padding. The page's half is in
/// site/src/signin/index.html; the Windows and Linux apps do the same.
struct SignInKey {
    struct Sealed: Decodable, Equatable {
        let uid: String
        let email: String?
        let rt: String
    }

    private static let info = Data("lovearound signin v1".utf8)
    let privateKey: P256.KeyAgreement.PrivateKey

    init(privateKey: P256.KeyAgreement.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    /// For the page's key= parameter.
    var publicKey: String { Self.base64url(privateKey.publicKey.x963Representation) }

    /// The session from the link's epk and box; nil when it isn't ours or
    /// was tampered with.
    func open(epk: String, box: String, state: String) -> Sealed? {
        guard let epk = Self.data(base64url: epk), let box = Self.data(base64url: box),
              let theirs = try? P256.KeyAgreement.PublicKey(x963Representation: epk),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: theirs) else { return nil }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Self.info, outputByteCount: 32)
        guard let sealed = try? AES.GCM.SealedBox(combined: box),
              let plain = try? AES.GCM.open(sealed, using: key, authenticating: Data(state.utf8)) else { return nil }
        return try? JSONDecoder().decode(Sealed.self, from: plain)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64url text: String) -> Data? {
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
}
