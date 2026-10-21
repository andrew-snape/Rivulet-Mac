// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  KeychainHelper.swift
//  Rivulet
//
//  Secure storage for sensitive credentials using iOS Keychain
//

import Foundation
import Security

enum KeychainHelper {

    private static let service = "com.rivulet.plex"

    /// Every value lives in one keychain item (a JSON dictionary), so macOS asks
    /// for access once rather than once per value.
    private static let vaultAccount = "vault"
    private static var vault: [String: String]?

    // MARK: - Public API

    /// Retrieve a string value from the Keychain
    static func get(_ key: String) -> String? {
        loadVault()[key]
    }

    /// Store a string value in the Keychain
    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        var values = loadVault()
        values[key] = value
        return saveVault(values)
    }

    /// Delete a value from the Keychain
    @discardableResult
    static func delete(_ key: String) -> Bool {
        var values = loadVault()
        guard values[key] != nil else { return true }
        values[key] = nil
        return saveVault(values)
    }

    // MARK: - Vault

    private static func loadVault() -> [String: String] {
        if let vault { return vault }
        var values = readVault() ?? [:]
        migrateLegacyItems(into: &values)
        vault = values
        return values
    }

    @discardableResult
    private static func saveVault(_ values: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(values) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount
        ]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        vault = values
        return true
    }

    private static func readVault() -> [String: String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// Folds the one-item-per-value layout of earlier versions into the vault and
    /// removes those items.
    private static func migrateLegacyItems(into values: inout [String: String]) {
        // The file-based keychain refuses to return data for several matches at
        // once, so list the accounts first and read each value on its own.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }

        var moved: [String] = []
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, account != vaultAccount else { continue }
            let read: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var data: AnyObject?
            guard SecItemCopyMatching(read as CFDictionary, &data) == errSecSuccess,
                  let bytes = data as? Data,
                  let string = String(data: bytes, encoding: .utf8) else { continue }
            if values[account] == nil { values[account] = string }
            moved.append(account)
        }
        guard !moved.isEmpty else { return }
        // Only drop the old items once the vault holds their values.
        guard saveVault(values) else { return }
        for account in moved {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ] as CFDictionary)
        }
    }

    // MARK: - PIN Storage for Plex Home Users

    private static let pinKeyPrefix = "plexPin_"

    /// Store a PIN for a Plex Home user
    @discardableResult
    static func setPin(_ pin: String, forUserUUID uuid: String) -> Bool {
        set(pin, forKey: pinKeyPrefix + uuid)
    }

    /// Retrieve a stored PIN for a Plex Home user
    static func getPin(forUserUUID uuid: String) -> String? {
        get(pinKeyPrefix + uuid)
    }

    /// Delete a stored PIN for a Plex Home user
    @discardableResult
    static func deletePin(forUserUUID uuid: String) -> Bool {
        delete(pinKeyPrefix + uuid)
    }

    /// Check if a PIN is stored for a Plex Home user
    static func hasSavedPin(forUserUUID uuid: String) -> Bool {
        getPin(forUserUUID: uuid) != nil
    }

    /// Delete all stored PINs (for sign out)
    static func deleteAllPins(forUserUUIDs uuids: [String]) {
        for uuid in uuids {
            deletePin(forUserUUID: uuid)
        }
    }
}
