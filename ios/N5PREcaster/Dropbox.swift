import Foundation
import CryptoKit
import Security

/// Sign in with Dropbox (PKCE, no app secret), read the web app's sync.json, and save edits to it.
/// Saving needs Dropbox's revision of the copy the edit started from, so it never replaces a newer copy.
@MainActor
final class Dropbox: ObservableObject {
    static let appKey = "9yk2nzxp65t5krk"
    static let scheme = "db-9yk2nzxp65t5krk"
    static let redirect = "db-9yk2nzxp65t5krk://2/token"
    static let file = "/sync.json"

    @Published var signedIn: Bool
    /// Set when Dropbox refuses a save because this sign-in only allows reading.
    @Published var needsWriteSignIn = false
    private var accessToken = ""
    private var expires = Date.distantPast

    init() {
        signedIn = Keychain.get("dbx.refresh") != nil
    }

    // MARK: Sign-in

    /// Starts a sign-in. With a redirect, Dropbox comes straight back to the app;
    /// without one, Dropbox shows a code to paste.
    func authURL(redirect: Bool) -> URL {
        let verifier = Dropbox.randomString(64)
        UserDefaults.standard.set(verifier, forKey: "dbx.verifier")
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        var q = [
            URLQueryItem(name: "client_id", value: Dropbox.appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "scope", value: "files.content.read files.content.write")
        ]
        if redirect { q.append(URLQueryItem(name: "redirect_uri", value: Dropbox.redirect)) }
        c.queryItems = q
        return c.url!
    }

    func finish(callback: URL) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error_description" || $0.name == "error" })?.value {
            throw AppError("Dropbox said: \(err)")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw AppError("Dropbox didn't send a sign-in code back.")
        }
        try await exchange(code: code, redirect: true)
    }

    func finish(pastedCode: String) async throws {
        let code = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw AppError("Paste the code Dropbox showed you.") }
        try await exchange(code: code, redirect: false)
    }

    private func exchange(code: String, redirect: Bool) async throws {
        guard let verifier = UserDefaults.standard.string(forKey: "dbx.verifier") else {
            throw AppError("Start the sign-in again.")
        }
        var form = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client_id": Dropbox.appKey
        ]
        if redirect { form["redirect_uri"] = Dropbox.redirect }
        let j = try await tokenCall(form)
        guard let refresh = j["refresh_token"] as? String else {
            throw AppError("Dropbox didn't give the app a lasting sign-in.")
        }
        Keychain.set("dbx.refresh", refresh)
        take(j)
        signedIn = true
        needsWriteSignIn = false
    }

    func signOut() {
        Keychain.delete("dbx.refresh")
        accessToken = ""
        expires = .distantPast
        signedIn = false
    }

    // MARK: Tokens

    private func take(_ j: [String: Any]) {
        accessToken = j["access_token"] as? String ?? ""
        let secs = J.num(j["expires_in"]) ?? 14400
        expires = Date().addingTimeInterval(secs - 120)
    }

    private func token(force: Bool = false) async throws -> String {
        if !force && !accessToken.isEmpty && Date() < expires { return accessToken }
        guard let refresh = Keychain.get("dbx.refresh") else {
            signedIn = false
            throw AppError("Sign in with Dropbox in Settings.")
        }
        do {
            let j = try await tokenCall(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": Dropbox.appKey])
            take(j)
            return accessToken
        } catch let e as TokenRejected {
            signOut()
            throw AppError("Dropbox ended the sign-in (\(e.reason)). Sign in again in Settings.")
        }
    }

    private struct TokenRejected: LocalizedError {
        let reason: String
        var errorDescription: String? { "Dropbox said: \(reason)" }
    }

    private func tokenCall(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(Dropbox.encode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200, j["access_token"] != nil { return j }
        let said = J.str(j["error_description"]).isEmpty ? J.str(j["error"]) : J.str(j["error_description"])
        if status == 400 || status == 401 { throw TokenRejected(reason: said.isEmpty ? "HTTP \(status)" : said) }
        throw AppError("Dropbox sign-in failed: \(said.isEmpty ? "HTTP \(status)" : said)")
    }

    // MARK: Reading the list

    /// The web app's sync.json, or nil when Dropbox has none yet.
    func downloadSync() async throws -> Data? {
        try await downloadFile(Dropbox.file)
    }

    /// Saves a transcript as /transcripts/<key>.json. Only that folder can be written,
    /// and an existing file is never replaced (the copy already there stays).
    func uploadTranscript(key: String, data: Data) async throws {
        guard key.range(of: "^[0-9a-f]{24}$", options: .regularExpression) != nil else {
            throw AppError("Bad transcript name.")
        }
        let arg = "{\"path\":\"/transcripts/\(key).json\",\"mode\":\"add\",\"autorename\":false,\"mute\":true,\"strict_conflict\":true}"
        var tok = try await token()
        for attempt in 0..<2 {
            var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue(arg, forHTTPHeaderField: "Dropbox-API-Arg")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60
            let (body, resp) = try await URLSession.shared.upload(for: req, from: data)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(decoding: body, as: UTF8.self)
            if status == 200 { return }
            if status == 409 && text.contains("conflict") { return }
            if text.contains("missing_scope") {
                needsWriteSignIn = true
                throw AppError("Sign out of Dropbox and back in, in Settings, so transcripts can be saved there.")
            }
            if status == 401 && attempt == 0 {
                tok = try await token(force: true)
                continue
            }
            throw AppError("Dropbox answered \(status): \(text.prefix(200))")
        }
        throw AppError("Dropbox wouldn't accept the sign-in.")
    }

    /// Dropbox's copy of sync.json and its revision, or nil when Dropbox has none.
    func downloadSyncWithRev() async throws -> (data: Data, rev: String)? {
        var tok = try await token()
        for attempt in 0..<2 {
            var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("{\"path\":\"\(Dropbox.file)\"}", forHTTPHeaderField: "Dropbox-API-Arg")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 200 {
                let meta = (http?.value(forHTTPHeaderField: "Dropbox-API-Result")).flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let rev = J.str(meta["rev"])
                guard !rev.isEmpty else { throw AppError("Dropbox didn't say which copy of your list this is.") }
                return (data, rev)
            }
            let body = String(decoding: data, as: UTF8.self)
            if status == 409 && body.contains("not_found") { return nil }
            if status == 401 && attempt == 0 {
                tok = try await token(force: true)
                continue
            }
            throw AppError("Dropbox answered \(status): \(body.prefix(200))")
        }
        throw AppError("Dropbox wouldn't accept the sign-in.")
    }

    struct SyncConflict: Error {}

    /// Replaces sync.json only if it is still the revision the edit started from.
    /// When another device saved in between, this throws SyncConflict and nothing is written.
    func uploadSync(_ data: Data, rev: String) async throws {
        let arg = "{\"path\":\"\(Dropbox.file)\",\"mode\":{\".tag\":\"update\",\"update\":\"\(rev)\"},\"autorename\":false,\"mute\":true,\"strict_conflict\":true}"
        var tok = try await token()
        for attempt in 0..<2 {
            var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue(arg, forHTTPHeaderField: "Dropbox-API-Arg")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60
            let (body, resp) = try await URLSession.shared.upload(for: req, from: data)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(decoding: body, as: UTF8.self)
            if status == 200 { return }
            if status == 409 && text.contains("conflict") { throw SyncConflict() }
            if text.contains("missing_scope") {
                needsWriteSignIn = true
                throw AppError("Sign out of Dropbox and back in, in Settings, so changes can be saved there.")
            }
            if status == 401 && attempt == 0 {
                tok = try await token(force: true)
                continue
            }
            throw AppError("Dropbox answered \(status): \(text.prefix(200))")
        }
        throw AppError("Dropbox wouldn't accept the sign-in.")
    }

    /// A file from the app's Dropbox folder, or nil when it isn't there.
    func downloadFile(_ path: String) async throws -> Data? {
        var tok = try await token()
        for attempt in 0..<2 {
            var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("{\"path\":\"\(path)\"}", forHTTPHeaderField: "Dropbox-API-Arg")
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return data }
            let body = String(decoding: data, as: UTF8.self)
            if status == 409 && body.contains("not_found") { return nil }
            if status == 401 && attempt == 0 {
                tok = try await token(force: true)
                continue
            }
            throw AppError("Dropbox answered \(status): \(body.prefix(200))")
        }
        throw AppError("Dropbox wouldn't accept the sign-in.")
    }

    // MARK: Helpers

    static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var out = ""
        for _ in 0..<n { out.append(chars[Int.random(in: 0..<chars.count)]) }
        return out
    }

    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The lasting Dropbox sign-in lives in the iPhone's keychain.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "N5PREcaster",
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        delete(key)
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
