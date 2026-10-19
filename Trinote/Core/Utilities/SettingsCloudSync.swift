import CryptoKit
import Foundation
import UIKit

/// Keeps the person's settings and recently opened notes the same on every device through iCloud
/// key-value storage.
/// Preferences (appearance, tree, editor, Home screen, sync options) and the last 50 opened notes per
/// server sync. Security (app PIN, Face ID), device-only choices (portrait lock) and credentials
/// never leave the device.
@MainActor
final class SettingsCloudSync {
    static let shared = SettingsCloudSync()

    /// Settings › Sync settings with iCloud.
    static let enabledKey = "syncSettingsWithICloud"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The UserDefaults keys that follow the person across devices.
    static let syncedKeys: [String] = [
        AppAccent.storageKey, "colorTheme", "appearanceMode",
        "useTriliumNoteColors", "useCustomTreeColors", "treeLightBgColor", "treeDarkBgColor",
        "treeLightSelectedNoteColor", "treeDarkSelectedNoteColor",
        "useCustomTextColor", "treeLightTextColor", "treeDarkTextColor", "customLightTextColor", "customDarkTextColor",
        "highlightCurrentNoteInTree", "showNoteTabsBar",
        "noteEditorLongPressToEdit", "noteEditorInsertToolsAtTop", "noteCheckboxReorderEnabled",
        "welcomeShowsRecents", "welcomeShowsFavorites", "welcomeShowsCapture", "welcomeRecentsCount",
        "welcomeShowsTips", "welcomeShowsTodos", "welcomeSectionOrder",
        AppState.syncOnLaunchKey,
        // The sidebar's notebook order and custom order before build 108 (Trilium holds it now);
        // still synced so a device that has not migrated yet hands its order over.
        "sidebarNotebookOrder", "sidebarNotebookCustomOrder",
        SavedSearches.storageKey,
    ]

    private let store = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    /// Set while copying cloud values into UserDefaults, so that copy is not pushed straight back.
    private var isApplyingCloudValues = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Call once at launch. A new device takes the settings already in iCloud; settings iCloud does
    /// not have yet are uploaded from this device.
    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated {
                self?.pullFromCloud(keys: keys)
                self?.pullRecents(keys: keys)
                if keys?.contains(Self.serversKey) != false {
                    NotificationCenter.default.post(name: .trinoteCloudServersChanged, object: nil)
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushToCloud() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .trinoteRecentNotesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRecentsPush() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .trinoteServerProfilesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushServers() }
        })
        // Coming back to the app also offers this device's servers again, in case another device
        // changed the list meanwhile.
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.synchronize()
                self?.pushServers()
            }
        })
        store.synchronize()
        pullFromCloud(keys: nil)
        pushToCloud()
        pullRecents(keys: nil)
        pushRecents()
        pushServers()
    }

    // MARK: - Servers

    /// A Trilium server as another device knows it: enough to offer it on the login screen.
    /// Passwords and session cookies never go to iCloud.
    struct CloudServer: Codable, Hashable, Identifiable {
        let name: String
        let url: String
        let auth: String
        /// The devices signed in to it. A server leaves the list only once no device has it, so
        /// removing it on the iPad no longer takes it away from the iPhone's offer (TestFlight
        /// feedback). Lists written by older builds have none and count as kept.
        var devices: [String]? = nil
        var id: String { url.lowercased() }
    }

    /// This install's id in the shared server list.
    static var deviceId: String {
        let key = "cloudServersDeviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// The shared list after this device signed in to `mine` (and no longer to the others it had).
    static func merged(_ list: [CloudServer], mine: [CloudServer], device: String) -> [CloudServer] {
        let mineIds = Set(mine.map(\.id))
        var result: [CloudServer] = []
        for var server in list where !mineIds.contains(server.id) {
            if var devices = server.devices {
                devices.removeAll { $0 == device }
                if devices.isEmpty { continue }
                server.devices = devices
            }
            result.append(server)
        }
        for var server in mine {
            var devices = list.first { $0.id == server.id }?.devices ?? []
            if !devices.contains(device) { devices.append(device) }
            server.devices = devices
            result.append(server)
        }
        return result
    }

    private static let serversKey = "servers"

    /// Servers signed in on the person's other devices (and this one).
    static func cloudServers() -> [CloudServer] {
        guard isEnabled, let data = NSUbiquitousKeyValueStore.default.data(forKey: serversKey) else { return [] }
        return (try? JSONDecoder().decode([CloudServer].self, from: data)) ?? []
    }

    /// Puts this device's servers on the shared list; servers other devices still use stay listed.
    func pushServers() {
        guard Self.isEnabled else { return }
        let mine = ((try? PersistenceManager.shared.fetchServerProfiles()) ?? []).filter { !$0.isLocal }.map {
            CloudServer(name: $0.name, url: $0.normalizedBaseURL, auth: $0.authMethodRaw)
        }
        let list = Self.merged(Self.cloudServers(), mine: mine, device: Self.deviceId)
        guard let data = try? JSONEncoder().encode(list) else { return }
        store.set(data, forKey: Self.serversKey)
        store.synchronize()
    }

    /// A server removed on this device: this device leaves its entry; the server stays offered
    /// while another device still uses it.
    func removeServer(url: String) {
        pushServers()
    }

    /// Fetches the latest shared list (the login screen calls this when it appears).
    func refreshServers() {
        store.synchronize()
    }

    // MARK: - Recents

    private struct SyncedRecent: Codable {
        let n: String   // note id
        let t: String   // title
        let y: String   // note type
        let a: Date     // opened at
    }

    private var recentsPushTask: Task<Void, Never>?

    /// Server profile ids differ per device; the server address identifies the same Trilium.
    private static func recentsKey(for profile: ServerProfile) -> String {
        "recents." + serverKey(for: profile)
    }

    /// The same on every device for the same Trilium (profile ids are not): a hash of its address.
    static func serverKey(for profile: ServerProfile) -> String {
        let digest = SHA256.hash(data: Data(profile.normalizedBaseURL.lowercased().utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func scheduleRecentsPush() {
        recentsPushTask?.cancel()
        recentsPushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.pushRecents()
        }
    }

    private func pushRecents() {
        guard Self.isEnabled else { return }
        let persistence = PersistenceManager.shared
        for profile in (try? persistence.fetchServerProfiles()) ?? [] {
            let recents = (try? persistence.fetchRecentNotes(serverProfileId: profile.id, limit: 50)) ?? []
            guard !recents.isEmpty else { continue }
            let synced = recents.map { SyncedRecent(n: $0.noteId, t: $0.title, y: $0.noteType, a: $0.accessedAt) }
            if let data = try? JSONEncoder().encode(synced) {
                store.set(data, forKey: Self.recentsKey(for: profile))
            }
        }
        store.synchronize()
    }

    private func pullRecents(keys: [String]?) {
        guard Self.isEnabled else { return }
        let persistence = PersistenceManager.shared
        var changed = false
        for profile in (try? persistence.fetchServerProfiles()) ?? [] {
            let key = Self.recentsKey(for: profile)
            if let keys, !keys.contains(key) { continue }
            guard let data = store.data(forKey: key),
                  let synced = try? JSONDecoder().decode([SyncedRecent].self, from: data) else { continue }
            for item in synced {
                try? persistence.mergeRecentNote(noteId: item.n, title: item.t, noteType: item.y, accessedAt: item.a, serverProfileId: profile.id)
            }
            try? persistence.saveMergedRecents(serverProfileId: profile.id)
            changed = true
        }
        if changed {
            NotificationCenter.default.post(name: .trinoteRecentsMergedFromCloud, object: nil)
        }
    }

    private func pullFromCloud(keys: [String]?) {
        guard Self.isEnabled else { return }
        let wanted = keys.map { Set($0).intersection(Self.syncedKeys) } ?? Set(Self.syncedKeys)
        isApplyingCloudValues = true
        defer { isApplyingCloudValues = false }
        for key in wanted {
            guard let value = store.object(forKey: key) else { continue }
            if !Self.equal(defaults.object(forKey: key), value) {
                defaults.set(value, forKey: key)
            }
        }
    }

    private func pushToCloud() {
        guard Self.isEnabled, !isApplyingCloudValues else { return }
        var changed = false
        for key in Self.syncedKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            if !Self.equal(store.object(forKey: key), value) {
                store.set(value, forKey: key)
                changed = true
            }
        }
        if changed { store.synchronize() }
    }

    private static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (l as NSObject, r as NSObject): l.isEqual(r)
        default: false
        }
    }
}
