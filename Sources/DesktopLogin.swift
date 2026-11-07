import CommonCrypto
import Foundation
import Security
import SQLite3

/// Reuses the claude.ai login of the Claude desktop app (an Electron/Chromium app).
/// Cookies live in ~/Library/Application Support/Claude/Cookies, encrypted with a key
/// stored in the keychain item "Claude Safe Storage". macOS asks the user once before
/// Doro may read that key. Nothing is written back to the desktop app.
struct DesktopCookie {
    let domain: String
    let name: String
    let value: String
    let path: String
    let expires: Date?
    let secure: Bool
    let httpOnly: Bool
}

enum DesktopLoginError: LocalizedError {
    case noApp
    case keychainDenied
    case noSession
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .noApp: return "没找到 Claude 桌面版的数据"
        case .keychainDenied: return "没有获得钥匙串授权"
        case .noSession: return "桌面版没有登录 claude.ai"
        case .decryptFailed: return "cookie 解密失败"
        }
    }
}

enum DesktopLogin {
    static let dbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/Cookies").path

    private static let lock = NSLock()
    private static var cachedKey: Data?
    private static var denied = false

    /// Lets the keychain prompt appear again after the user declined it.
    static func resetDenied() {
        lock.lock(); denied = false; lock.unlock()
    }

    private static func aesKey() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let k = cachedKey { return k }
        if denied { throw DesktopLoginError.keychainDenied }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(query as CFDictionary, &out)
        guard st == errSecSuccess, let password = out as? Data else {
            if st != errSecItemNotFound { denied = true }
            throw st == errSecItemNotFound ? DesktopLoginError.noApp : DesktopLoginError.keychainDenied
        }

        // Chromium on macOS: PBKDF2-HMAC-SHA1(password, "saltysalt", 1003 rounds) -> AES-128 key.
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let r = key.withUnsafeMutableBytes { kb in
            password.withUnsafeBytes { pb in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pb.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                     salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     kb.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
            }
        }
        guard r == kCCSuccess else { throw DesktopLoginError.decryptFailed }
        cachedKey = key
        return key
    }

    private static func decrypt(_ blob: Data, key: Data, stripHostHash: Bool) -> String? {
        let v10 = Data("v10".utf8)
        guard blob.count > 3, blob.prefix(3) == v10 else { return nil }
        let ct = Data(blob.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: ct.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let st = out.withUnsafeMutableBytes { ob in
            ct.withUnsafeBytes { cb in
                key.withUnsafeBytes { kb in
                    iv.withUnsafeBytes { ivb in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                kb.baseAddress, key.count, ivb.baseAddress,
                                cb.baseAddress, ct.count, ob.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard st == kCCSuccess else { return nil }
        var plain = out.prefix(moved)
        // Cookie DB version >= 24 prefixes the value with SHA-256(host_key).
        if stripHostHash && plain.count >= 32 { plain = plain.dropFirst(32) }
        return String(data: Data(plain), encoding: .utf8)
    }

    /// Reads and decrypts the desktop app's claude.ai cookies. Throws if there is no login.
    static func readCookies() throws -> [DesktopCookie] {
        guard FileManager.default.fileExists(atPath: dbPath) else { throw DesktopLoginError.noApp }
        let encoded = dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbPath
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(encoded)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw DesktopLoginError.noApp
        }
        defer { sqlite3_close(db) }

        func query(_ sql: String, _ row: (OpaquePointer) -> Void) {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        }
        func text(_ s: OpaquePointer, _ i: Int32) -> String {
            sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
        }

        var version = 0
        query("SELECT value FROM meta WHERE key='version'") { version = Int(text($0, 0)) ?? 0 }

        let key = try aesKey()
        var cookies: [DesktopCookie] = []
        var decryptErrors = 0
        query("""
            SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly
            FROM cookies WHERE host_key IN ('claude.ai', '.claude.ai')
            """) { s in
            var value = text(s, 2)
            if value.isEmpty, let p = sqlite3_column_blob(s, 3) {
                let blob = Data(bytes: p, count: Int(sqlite3_column_bytes(s, 3)))
                if let v = decrypt(blob, key: key, stripHostHash: version >= 24) { value = v } else { decryptErrors += 1; return }
            }
            let chromeTime = sqlite3_column_int64(s, 5)   // microseconds since 1601-01-01
            let expires = chromeTime > 0 ? Date(timeIntervalSince1970: Double(chromeTime) / 1_000_000 - 11_644_473_600) : nil
            cookies.append(DesktopCookie(domain: text(s, 0), name: text(s, 1), value: value, path: text(s, 4),
                                         expires: expires, secure: sqlite3_column_int(s, 6) != 0,
                                         httpOnly: sqlite3_column_int(s, 7) != 0))
        }

        guard let session = cookies.first(where: { $0.name == "sessionKey" }) else {
            throw decryptErrors > 0 ? DesktopLoginError.decryptFailed : DesktopLoginError.noSession
        }
        if let exp = session.expires, exp < Date() { throw DesktopLoginError.noSession }
        return cookies
    }
}
