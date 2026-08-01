import Foundation
import Security

enum MusicProviderSessionStoreError: Error, Equatable {
    case keychain(OSStatus)
    case invalidStoredSession
}

actor KeychainMusicProviderSessionStore: MusicProviderSessionStore {
    static let defaultService = "ai.gmgn.radio.music-providers.v2"

    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var loadedProviderIDs = Set<MusicProviderID>()
    private var cachedSessions: [
        MusicProviderID: MusicProviderSession
    ] = [:]

    init(service: String = KeychainMusicProviderSessionStore.defaultService) {
        self.service = service
    }

    func session(
        for providerID: MusicProviderID
    ) throws -> MusicProviderSession? {
        if loadedProviderIDs.contains(providerID) {
            return cachedSessions[providerID]
        }
        var query = baseQuery(for: providerID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            loadedProviderIDs.insert(providerID)
            return nil
        }
        guard status == errSecSuccess else {
            throw MusicProviderSessionStoreError.keychain(status)
        }
        guard
            let data = result as? Data,
            let session = try? decoder.decode(
                MusicProviderSession.self,
                from: data
            )
        else {
            throw MusicProviderSessionStoreError.invalidStoredSession
        }
        loadedProviderIDs.insert(providerID)
        cachedSessions[providerID] = session
        return session
    }

    func save(
        _ session: MusicProviderSession,
        for providerID: MusicProviderID
    ) throws {
        let data = try encoder.encode(session)
        let query = baseQuery(for: providerID)
        let update = [kSecValueData: data] as CFDictionary
        let updateStatus = SecItemUpdate(query as CFDictionary, update)

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MusicProviderSessionStoreError.keychain(addStatus)
            }
            loadedProviderIDs.insert(providerID)
            cachedSessions[providerID] = session
            return
        }

        guard updateStatus == errSecSuccess else {
            throw MusicProviderSessionStoreError.keychain(updateStatus)
        }
        loadedProviderIDs.insert(providerID)
        cachedSessions[providerID] = session
    }

    func removeSession(
        for providerID: MusicProviderID
    ) throws {
        let status = SecItemDelete(baseQuery(for: providerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MusicProviderSessionStoreError.keychain(status)
        }
        loadedProviderIDs.insert(providerID)
        cachedSessions.removeValue(forKey: providerID)
    }

    private func baseQuery(
        for providerID: MusicProviderID
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: providerID.rawValue
        ]
    }
}
