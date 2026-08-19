import CryptoKit
import Foundation
import Security

struct SecureFileStore {
    private final class EncryptionKeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var keyData: Data?

        func value(orLoad load: () throws -> Data) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let keyData { return keyData }
            let loaded = try load()
            keyData = loaded
            return loaded
        }
    }
    private struct Envelope: Codable {
        let version: Int
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    private enum StoreError: LocalizedError {
        case invalidEnvelope
        case invalidCombinedRepresentation
        case unexpectedKeyData
        case keychainFailure(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidEnvelope:
                return "The encrypted file contents are invalid."
            case .invalidCombinedRepresentation:
                return "The encrypted payload could not be assembled."
            case .unexpectedKeyData:
                return "The stored encryption key is invalid."
            case .keychainFailure(let status):
                return "Keychain error: \(status)"
            }
        }
    }

    private static let service = "alice.turcanu.LocalAI.secure-file-store"
    private static let account = "app-data-encryption-key"
    private static let fileProtection: FileProtectionType = .complete
    private static let encryptionKeyCache = EncryptionKeyCache()

    static func load<T: Codable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        if let value = try? decryptDecoded(type, from: data) {
            try applyProtectionAttributes(to: url)
            return value
        }

        let decoded = try decoder.decode(T.self, from: data)
        try save(decoded, to: url)
        return decoded
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        let plaintext = try encoder.encode(value)
        let key = try encryptionKey()
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw StoreError.invalidCombinedRepresentation
        }

        let envelope = Envelope(
            version: 1,
            nonce: Data(sealedBox.nonce),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        let payload = try encoder.encode(envelope)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: url, options: .atomic)
        try applyProtectionAttributes(to: url)

        if combined.isEmpty {
            throw StoreError.invalidCombinedRepresentation
        }
    }

    static func removeFileIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func decryptDecoded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.version == 1 else {
            throw StoreError.invalidEnvelope
        }

        let combined = envelope.nonce + envelope.ciphertext + envelope.tag
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: encryptionKey())
        return try decoder.decode(T.self, from: plaintext)
    }

    private static func encryptionKey() throws -> SymmetricKey {
        let keyData = try encryptionKeyCache.value {
            if let existing = try existingKeyData() {
                guard existing.count == 32 else {
                    throw StoreError.unexpectedKeyData
                }
                return existing
            }

            let generated = Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
            try storeKeyData(generated)
            return generated
        }
        return SymmetricKey(data: keyData)
    }

    private static func existingKeyData() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.keychainFailure(status)
        }
    }

    private static func storeKeyData(_ data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw StoreError.keychainFailure(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StoreError.keychainFailure(addStatus)
        }
    }

    private static func applyProtectionAttributes(to url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: fileProtection], ofItemAtPath: url.path)
    }
}
