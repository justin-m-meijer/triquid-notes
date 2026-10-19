import Foundation

/// A search the person kept, shown under Saved searches in the sidebar.
struct SavedSearch: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var query: String
}

/// Saved searches per Trilium server, in one UserDefaults string that `SettingsCloudSync` carries to the
/// person's other devices. Servers are keyed by `SettingsCloudSync.serverKey(for:)` (a hash of the address),
/// because profile ids differ per device; a notebook on this device uses its profile id.
@MainActor
enum SavedSearches {
    /// The UserDefaults key, also listed in `SettingsCloudSync.syncedKeys`; views read it with `@AppStorage`.
    static let storageKey = "savedSearches"

    static func list(for profile: ServerProfile?, raw: String? = nil) -> [SavedSearch] {
        guard let profile else { return [] }
        return all(raw: raw)[key(for: profile)] ?? []
    }

    static func contains(query: String, profile: ServerProfile?) -> Bool {
        list(for: profile).contains { $0.query == normalized(query) }
    }

    static func add(name: String, query: String, profile: ServerProfile) {
        let query = normalized(query)
        guard !query.isEmpty else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(profile) { list in
            list.removeAll { $0.query == query }
            list.append(SavedSearch(name: name.isEmpty ? query : name, query: query))
        }
    }

    static func rename(_ search: SavedSearch, to name: String, profile: ServerProfile) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        update(profile) { list in
            if let i = list.firstIndex(where: { $0.id == search.id }) { list[i].name = name }
        }
    }

    static func remove(query: String, profile: ServerProfile) {
        let query = normalized(query)
        update(profile) { $0.removeAll { $0.query == query } }
    }

    static func remove(_ search: SavedSearch, profile: ServerProfile) {
        update(profile) { $0.removeAll { $0.id == search.id } }
    }

    // MARK: - Storage

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func key(for profile: ServerProfile) -> String {
        profile.isLocal ? "local." + profile.id : SettingsCloudSync.serverKey(for: profile)
    }

    private static func all(raw: String? = nil) -> [String: [SavedSearch]] {
        let string = raw ?? UserDefaults.standard.string(forKey: storageKey) ?? ""
        guard let data = string.data(using: .utf8), !data.isEmpty else { return [:] }
        return (try? JSONDecoder().decode([String: [SavedSearch]].self, from: data)) ?? [:]
    }

    private static func update(_ profile: ServerProfile, _ change: (inout [SavedSearch]) -> Void) {
        var everything = all()
        var list = everything[key(for: profile)] ?? []
        change(&list)
        everything[key(for: profile)] = list.isEmpty ? nil : list
        let data = (try? JSONEncoder().encode(everything)) ?? Data()
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: storageKey)
    }
}
