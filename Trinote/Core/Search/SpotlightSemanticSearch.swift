import CoreSpotlight
import Foundation
import SwiftData

/// Semantic matches from the Spotlight index (`SpotlightIndexer`), added after offline search's own
/// results: "meeting" also finding "call with the team". Spotlight ranks; this looks the notes up in
/// the cache. Protected notes are never returned (they are not indexed either).
@ModelActor
actor SpotlightSemanticSearch {
    func hits(for query: String, profileId: String, excluding: Set<String>, limit: Int = 20) async -> [LocalSearchHit] {
        guard SpotlightIndexer.isEnabled, CSSearchableIndex.isIndexingAvailable(),
              !query.trimmingCharacters(in: .whitespaces).isEmpty
        else { return [] }
        let context = CSUserQueryContext()
        context.fetchAttributes = ["title"]
        context.maxResultCount = limit
        var ids: [String] = []
        do {
            for try await element in CSUserQuery(userQueryString: query, userQueryContext: context).responses {
                guard case .item(let item) = element,
                      let parsed = SpotlightIndexer.parse(identifier: item.item.uniqueIdentifier),
                      parsed.profileId == profileId,
                      !excluding.contains(parsed.noteId),
                      !ids.contains(parsed.noteId)
                else { continue }
                ids.append(parsed.noteId)
            }
        } catch {
            return []
        }
        guard !ids.isEmpty else { return [] }
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<CachedNote>(
            predicate: #Predicate { $0.serverProfileId == profileId && idSet.contains($0.noteId) && !$0.isProtected }
        )
        let byId = Dictionary(((try? modelContext.fetch(descriptor)) ?? []).map { ($0.noteId, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id in
            byId[id].map { note in
                LocalSearchHit(
                    noteId: note.noteId,
                    title: note.title,
                    noteType: note.noteType,
                    mime: note.mime,
                    isProtected: false,
                    parentNoteIds: note.parentNoteIds,
                    childNoteIds: note.childNoteIds,
                    parentBranchIds: note.parentBranchIds,
                    childBranchIds: note.childBranchIds,
                    utcDateModified: note.utcDateModified,
                    snippet: nil
                )
            }
        }
    }
}
