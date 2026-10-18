import CryptoKit
import Foundation
import os
import Security

/// TLS settings for self-hosted servers, kept in the Keychain per host:
///
/// - a **client certificate** (`.p12`) for servers behind mutual TLS (a reverse proxy asking for a
///   certificate before it lets anyone reach Trilium);
/// - a **trusted server certificate**: the SHA-256 fingerprint of a self-signed certificate the user
///   confirmed, so the server works without installing a CA profile.
///
/// Every URLSession delegate in the app routes authentication challenges through
/// `handle(_:)`, so the API client, the login request, long uploads and the WebSocket all behave
/// the same.
enum ServerCertificates {
    private static let log = Logger(subsystem: "Trinote", category: "TLS")
    private static let identityLabelPrefix = "trinote.client-certificate."
    private static let pinService = "com.trinote.pinned-server-certificate"

    // MARK: - Challenges

    /// For one-off requests to a Trilium server outside `TriliumClient` (SSO handler check).
    static let session = URLSession(configuration: .default, delegate: ServerCertificateSessionDelegate(), delegateQueue: nil)

    /// The answer to a URLSession authentication challenge.
    static func handle(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let host = space.host.lowercased()
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity = cache.identity(forHost: host) else {
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))

        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
            // The system's verdict comes first: a valid chain never needs a pin.
            if SecTrustEvaluateWithError(trust, nil) {
                return (.performDefaultHandling, nil)
            }
            guard let pinned = cache.pinnedFingerprint(forHost: host),
                  let presented = leafFingerprint(of: trust),
                  pinned == presented
            else {
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, URLCredential(trust: trust))

        default:
            return (.performDefaultHandling, nil)
        }
    }

    // MARK: - Client certificate

    struct ClientCertificateInfo: Equatable, Sendable {
        let subject: String
        let expires: Date?
    }

    enum ImportError: LocalizedError, Equatable {
        case wrongPassword
        case noIdentity
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .wrongPassword:
                String(localized: "The password for this certificate is not correct.", comment: "Client certificate import error")
            case .noIdentity:
                String(localized: "This file does not contain a certificate with its private key (.p12 / .pfx).", comment: "Client certificate import error")
            case .keychain(let status):
                String(localized: "The certificate could not be saved (\(status)).", comment: "Client certificate import error; argument is an OSStatus")
            }
        }
    }

    /// Imports a PKCS #12 file for `host`, replacing any certificate stored for it.
    @discardableResult
    static func importClientCertificate(p12 data: Data, password: String, forHost host: String) throws -> ClientCertificateInfo {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        switch status {
        case errSecSuccess: break
        case errSecAuthFailed, errSecPkcs12VerifyFailure: throw ImportError.wrongPassword
        default: throw ImportError.noIdentity
        }
        guard let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String]
        else { throw ImportError.noIdentity }
        let identity = value as! SecIdentity // CF type: the cast cannot fail once the key exists.

        removeClientCertificate(forHost: host)
        let add: [String: Any] = [
            kSecValueRef as String: identity,
            kSecAttrLabel as String: identityLabelPrefix + host.lowercased(),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw ImportError.keychain(addStatus) }
        cache.invalidate()
        log.info("Client certificate stored for \(host, privacy: .public)")
        return info(for: identity)
    }

    static func clientCertificate(forHost host: String) -> ClientCertificateInfo? {
        cache.identity(forHost: host.lowercased()).map(info(for:))
    }

    static func removeClientCertificate(forHost host: String) {
        // Deleting the identity by its certificate label removes the certificate and its key.
        for itemClass in [kSecClassIdentity, kSecClassCertificate] {
            SecItemDelete([
                kSecClass as String: itemClass,
                kSecAttrLabel as String: identityLabelPrefix + host.lowercased(),
            ] as CFDictionary)
        }
        cache.invalidate()
    }

    fileprivate static func loadIdentity(forHost host: String) -> SecIdentity? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: identityLabelPrefix + host,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let result else { return nil }
        return (result as! SecIdentity)
    }

    private static func info(for identity: SecIdentity) -> ClientCertificateInfo {
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        let subject = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "–"
        return ClientCertificateInfo(subject: subject, expires: certificate.flatMap(expiryDate(of:)))
    }

    private static func expiryDate(of certificate: SecCertificate) -> Date? {
        SecCertificateCopyNotValidAfterDate(certificate) as Date?
    }

    // MARK: - Trusted server certificate

    /// What a server presented, for the user to confirm before it is trusted.
    struct PresentedCertificate: Equatable, Sendable {
        let host: String
        let subject: String
        let fingerprint: String
        /// The system already trusts this chain; pinning is unnecessary.
        let isTrustedBySystem: Bool
    }

    static func trust(fingerprint: String, forHost host: String) throws {
        let data = Data(fingerprint.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pinService,
            kSecAttrAccount as String: host.lowercased(),
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw ImportError.keychain(status) }
        cache.invalidate()
    }

    static func trustedFingerprint(forHost host: String) -> String? {
        cache.pinnedFingerprint(forHost: host.lowercased())
    }

    static func removeTrust(forHost host: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pinService,
            kSecAttrAccount as String: host.lowercased(),
        ] as CFDictionary)
        cache.invalidate()
    }

    fileprivate static func loadPinnedFingerprint(forHost host: String) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pinService,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Connects to `url` and reports the certificate the server presents, without trusting it.
    static func fetchPresentedCertificate(from url: URL) async throws -> PresentedCertificate {
        let probe = CertificateProbe()
        let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)
        guard let presented = probe.presented else { throw URLError(.serverCertificateUntrusted) }
        return presented
    }

    /// `AB:CD:…`, the SHA-256 of the leaf certificate's DER bytes (as browsers show it).
    static func fingerprint(of certificate: SecCertificate) -> String {
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return fingerprint(of: leaf)
    }

    // MARK: - Cache

    /// Challenges arrive on URLSession's queues, often several at once; Keychain reads are cached.
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var identities: [String: SecIdentity?] = [:]
        private var pins: [String: String?] = [:]

        func identity(forHost host: String) -> SecIdentity? {
            lock.withLock {
                if let cached = identities[host] { return cached }
                let loaded = ServerCertificates.loadIdentity(forHost: host)
                identities[host] = loaded
                return loaded
            }
        }

        func pinnedFingerprint(forHost host: String) -> String? {
            lock.withLock {
                if let cached = pins[host] { return cached }
                let loaded = ServerCertificates.loadPinnedFingerprint(forHost: host)
                pins[host] = loaded
                return loaded
            }
        }

        func invalidate() {
            lock.withLock {
                identities.removeAll()
                pins.removeAll()
            }
        }
    }
}

/// Records the server certificate during a probe and then refuses the connection.
private final class CertificateProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _presented: ServerCertificates.PresentedCertificate?

    var presented: ServerCertificates.PresentedCertificate? { lock.withLock { _presented } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let presented = ServerCertificates.PresentedCertificate(
            host: space.host.lowercased(),
            subject: (SecCertificateCopySubjectSummary(leaf) as String?) ?? space.host,
            fingerprint: ServerCertificates.fingerprint(of: leaf),
            isTrustedBySystem: SecTrustEvaluateWithError(trust, nil)
        )
        lock.withLock { _presented = presented }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

/// Answers TLS challenges through `ServerCertificates` (client certificate, trusted fingerprint).
/// Used as the delegate of sessions that need no other delegate behaviour.
final class ServerCertificateSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = ServerCertificates.handle(challenge)
        completionHandler(disposition, credential)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = ServerCertificates.handle(challenge)
        completionHandler(disposition, credential)
    }
}
