import Foundation
import Security

/// The Keychain, for the one secret Engrossed can hold: an ElevenLabs key a
/// reader chose to paste in.
///
/// Not UserDefaults. That is a plain plist in the app's folder, copied into
/// every backup and readable by anything that can read the folder. A key is
/// spendable money on someone else's account, so it goes where the system
/// keeps passwords.
///
/// Stored as "after first unlock, this device only". After first unlock, so a
/// reader who opens a book straight after a restart still gets their voice.
/// This device only, so the key never syncs to iCloud Keychain and is never
/// restored onto another device from a backup: it is pasted on purpose, on
/// the device that uses it, and stays there.
enum Keychain {
    struct Item {
        let service: String
        let account: String

        // On Item rather than on Keychain, so call sites can say
        // `Keychain.read(.elevenLabsKey)`.
        static let elevenLabsKey = Item(service: "com.lowshelf.engrossed.elevenlabs",
                                        account: "api-key")
    }

    /// Where an item can live. iPhone and iPad have one keychain. A Mac has
    /// two: the modern one, which honours the accessibility setting above and
    /// is what an App Store build uses, and the older login keychain. The
    /// modern one needs the app signed with a provisioning profile, which a
    /// local debug build usually isn't, so a Mac falls back to the login
    /// keychain rather than refuse to save. That one never syncs to iCloud
    /// either.
    private enum Backing {
        case dataProtection
        case login
    }

    #if os(macOS)
    private static let backings: [Backing] = [.dataProtection, .login]
    #else
    private static let backings: [Backing] = [.dataProtection]
    #endif

    /// Replaces whatever was saved before. Returns whether it stuck.
    @discardableResult
    static func save(_ value: String, for item: Item) -> Bool {
        delete(item)
        for backing in backings {
            var query = baseQuery(item, in: backing)
            query[kSecValueData] = Data(value.utf8)
            if backing == .dataProtection {
                query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess { return true }
            // Only a missing entitlement is worth trying the next keychain for.
            // Anything else is a real failure, and saying nothing was saved is
            // the honest answer.
            guard status == errSecMissingEntitlement else { return false }
        }
        return false
    }

    static func read(_ item: Item) -> String? {
        for backing in backings {
            var query = baseQuery(item, in: backing)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else { continue }
            return value
        }
        return nil
    }

    /// Whether anything is saved, without reading the secret itself out. The
    /// settings screen only needs to know which controls to show.
    static func contains(_ item: Item) -> Bool {
        backings.contains { backing in
            SecItemCopyMatching(baseQuery(item, in: backing) as CFDictionary, nil) == errSecSuccess
        }
    }

    /// Removes the item from every keychain it could be in. Returns whether it
    /// is gone, which includes it never having been there.
    @discardableResult
    static func delete(_ item: Item) -> Bool {
        // Every keychain is asked, even after one fails: a key left behind in
        // the second because the first complained would be a key the reader
        // believes is gone.
        let statuses = backings.map { SecItemDelete(baseQuery(item, in: $0) as CFDictionary) }
        return statuses.allSatisfy {
            $0 == errSecSuccess || $0 == errSecItemNotFound || $0 == errSecMissingEntitlement
        }
    }

    private static func baseQuery(_ item: Item, in backing: Backing) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: item.service,
            kSecAttrAccount: item.account,
        ]
        if backing == .dataProtection {
            // Ignored on iPhone and iPad, where there is only this one.
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }
}
