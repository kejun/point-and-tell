#if os(macOS)
import Foundation
import Security
import PointAndTellCore

/// API keys are stored only in the local login keychain, never UserDefaults,
/// project manifests, crash diagnostics or exported documents.
enum APIKeyStore {
    private static let service = "io.github.kejun.point-and-tell.asr"
    private static let account = "qwen-audio-3.0-asr-flash"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法访问 macOS 钥匙串（状态 \(status)）。请解锁登录钥匙串后重试；密钥未写入普通文件。" }
    }
    static func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError(status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8),
              WorkflowReadiness.validAPIKey(key) else { throw StoreError(status: errSecDecode) }
        return key
    }
    static func save(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkflowReadiness.validAPIKey(key) else { throw ASRError.invalidAPIKey }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrLabel as String] = "Point & Tell · Qwen ASR API Key"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw StoreError(status: added) }
        } else if status != errSecSuccess { throw StoreError(status: status) }
    }
    static func saveAsync(_ key: String, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try save(key) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
#endif
