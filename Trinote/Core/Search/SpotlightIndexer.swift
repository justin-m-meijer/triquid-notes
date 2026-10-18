import CoreSpotlight
import Foundation
import os
import SwiftData
import UniformTypeIdentifiers

/// Puts cached notes into the system Spotlight index (and the app's own semantic index, which
/// `SpotlightSemanticSearch` queries offline). One domain per server profile, so removing a server or
/// turning indexing off clears exactly its items. Protected notes are never indexed.
///
/// Updates are incremental: only notes fetched since the last pass are indexed. Once a day the
/// profile's domain is rebuilt from scratch, which is how notes deleted on the server drop out.
@ModelActor
actor SpotlightIndexer {
    static let enabledKey = "spotlightIndexingEnabled"
    static let indexName = "TrinoteNotes"
    /// Rebuild a domain at least this often, so deletions disappear from Spotlight.
    private static let fullRebuildInterval: TimeInterval = 24 * 60 * 60
    /// Spotlight only needs enough text to match on; huge notes are cut.
    private static let maxIndexedCharacters = 20_000
    private static let batchSize = 200

    private let log = Logger(subsystem: "Trinote", category: "Spotlight")

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// With the app locked behind a PIN or Face ID, note text must not be readable from system
    /// search, so only titles are indexed.
    static var indexesTitlesOnly: Bool {
        UserDefaults.standard.bool(forKey: "appPinEnabled") || UserDefaults.standard.bool(forKey: "appBiometricEnabled")
    }

    /// The index both Spotlight and `CSUserQuery` read.
    nonisolated static var index: CSSearchableIndex { CSSearchableIndex(name: indexName) }

    /// `profileId/noteId`, the unique identifier of an indexed note.
    nonisolated static func identifier(profileId: String, noteId: String) -> String {
        "\(profileId)/\(noteId)"
    }

    nonisolated static func parse(identifier: String) -> (profileId: String, noteId: String)? {
        let parts = identifier.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    private struct ClientState: Codable {
        var lastIndexedAt: [String: Date] = [:]
        var lastRebuildAt: [String: Date] = [:]
        /// The title-only setting the domain was built with; a change forces a rebuild.
        var titlesOnly: [String: Bool] = [:]
    }

    /// Indexes what changed for `profileId` since the last pass (or everything, when due).
    func update(profileId: String, profileName: String) async {
        guard Self.isEnabled, CSSearchableIndex.isIndexingAvailable() else { return }
        let index = Self.index
        var state = await loadState(index)
        let now = Date.now
        let titlesOnly = Self.indexesTitlesOnly
        let rebuild = state.titlesOnly[profileId] != titlesOnly
            || state.lastRebuildAt[profileId].map { now.timeIntervalSince($0) > Self.fullRebuildInterval } ?? true
        let since: Date? = rebuild ? nil : state.lastIndexedAt[profileId]

        do {
            if rebuild {
                try await index.deleteSearchableItems(withDomainIdentifiers: [profileId])
            }
            if !rebuild {
                // A note made protected since the last pass must disappear now, not at the next rebuild.
                let protectedIds = try modelContext.fetch(FetchDescriptor<CachedNote>(
                    predicate: #Predicate { $0.serverProfileId == profileId && $0.isProtected }
                )).map { Self.identifier(profileId: profileId, noteId: $0.noteId) }
                if !protectedIds.isEmpty {
                    try await index.deleteSearchableItems(withIdentifiers: protectedIds)
                }
            }
            let count = try await indexNotes(profileId: profileId, profileName: profileName, changedSince: since, into: index)
            state.lastIndexedAt[profileId] = now
            if rebuild { state.lastRebuildAt[profileId] = now }
            state.titlesOnly[profileId] = titlesOnly
            try await saveState(state, into: index)
            log.info("Spotlight: indexed \(count) notes (rebuild: \(rebuild))")
        } catch {
            log.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes everything indexed for `profileId` (server removed) or, with `nil`, for every profile.
    func removeAll(profileId: String? = nil) async {
        let index = Self.index
        do {
            if let profileId {
                try await index.deleteSearchableItems(withDomainIdentifiers: [profileId])
                var state = await loadState(index)
                state.lastIndexedAt[profileId] = nil
                state.lastRebuildAt[profileId] = nil
                try await saveState(state, into: index)
            } else {
                try await index.deleteAllSearchableItems()
                try await saveState(ClientState(), into: index)
            }
        } catch {
            log.error("Spotlight removal failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops single notes right away (deleted or made protected on this device).
    func remove(noteIds: [String], profileId: String) async {
        let ids = noteIds.map { Self.identifier(profileId: profileId, noteId: $0) }
        try? await Self.index.deleteSearchableItems(withIdentifiers: ids)
    }

    // MARK: - Indexing

    private func indexNotes(profileId: String, profileName: String, changedSince: Date?, into index: CSSearchableIndex) async throws -> Int {
        var descriptor = FetchDescriptor<CachedNote>(
            predicate: #Predicate { $0.serverProfileId == profileId && !$0.isProtected }
        )
        descriptor.propertiesToFetch = [\.noteId, \.title, \.noteType, \.content, \.metadataFetchedAt, \.contentFetchedAt, \.utcDateModified]
        let notes = try modelContext.fetch(descriptor).filter { note in
            guard let changedSince else { return true }
            return note.metadataFetchedAt > changedSince || (note.contentFetchedAt ?? .distantPast) > changedSince
        }
        guard !notes.isEmpty else { return 0 }

        let labelsByNote = try visibleLabels(profileId: profileId, noteIds: Set(notes.map(\.noteId)))
        var batch: [CSSearchableItem] = []
        batch.reserveCapacity(Self.batchSize)
        var count = 0
        for note in notes {
            // Bookkeeping notes Trilium creates for itself are not worth finding.
            guard !note.noteId.hasPrefix("_") else { continue }
            batch.append(item(for: note, labels: labelsByNote[note.noteId] ?? [], profileId: profileId, profileName: profileName))
            if batch.count == Self.batchSize {
                try await index.indexSearchableItems(batch)
                count += batch.count
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try await index.indexSearchableItems(batch)
            count += batch.count
        }
        return count
    }

    private func item(for note: CachedNote, labels: [String], profileId: String, profileName: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = note.title.isEmpty ? String(localized: "Untitled", comment: "Spotlight: note without a title") : note.title
        let text = Self.indexesTitlesOnly ? "" : Self.plainText(for: note)
        if !text.isEmpty {
            attributes.textContent = String(text.prefix(Self.maxIndexedCharacters))
            attributes.contentDescription = String(text.prefix(280))
        }
        attributes.keywords = labels
        attributes.containerTitle = profileName
        attributes.domainIdentifier = profileId
        if let modified = note.utcDateModified.flatMap(Self.parseTriliumDate) {
            attributes.contentModificationDate = modified
        }
        let item = CSSearchableItem(
            uniqueIdentifier: Self.identifier(profileId: profileId, noteId: note.noteId),
            domainIdentifier: profileId,
            attributeSet: attributes
        )
        // Notes do not expire from Spotlight on their own; the daily rebuild keeps the set current.
        item.expirationDate = .distantFuture
        return item
    }

    private func visibleLabels(profileId: String, noteIds: Set<String>) throws -> [String: [String]] {
        let descriptor = FetchDescriptor<CachedAttribute>(
            predicate: #Predicate { $0.serverProfileId == profileId && $0.type == "label" }
        )
        var result: [String: [String]] = [:]
        for attribute in try modelContext.fetch(descriptor) where noteIds.contains(attribute.noteId) {
            guard NoteLabelVisibility.isVisible(attribute.name) else { continue }
            result[attribute.noteId, default: []].append(attribute.value.isEmpty ? attribute.name : "\(attribute.name) \(attribute.value)")
        }
        return result
    }

    /// Text and code notes contribute their body; other types (canvas, maps, files) only their title.
    static func plainText(for note: CachedNote) -> String {
        guard let data = note.content, let raw = String(data: data, encoding: .utf8) else { return "" }
        switch NoteType(rawValue: note.noteType) {
        case .text: return LabelSuggester.plainText(fromHTML: raw)
        case .code, .markdown: return raw
        default: return ""
        }
    }

    /// Trilium writes `2026-09-30 14:03:12.123Z`.
    static func parseTriliumDate(_ value: String) -> Date? {
        let iso = value.replacingOccurrences(of: " ", with: "T")
        return fractionalFormatter.date(from: iso) ?? wholeSecondsFormatter.date(from: iso)
    }

    // Made once: creating a formatter per date took seconds for a few hundred notes (the sidebar's
    // counts parse every note's date). `ISO8601DateFormatter` is thread-safe.
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let wholeSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Client state

    private func loadState(_ index: CSSearchableIndex) async -> ClientState {
        guard let data = try? await index.fetchLastClientState() else { return ClientState() }
        return (try? JSONDecoder().decode(ClientState.self, from: data)) ?? ClientState()
    }

    private func saveState(_ state: ClientState, into index: CSSearchableIndex) async throws {
        let data = try JSONEncoder().encode(state)
        index.beginBatch()
        try await index.endBatch(withClientState: data)
    }
}
