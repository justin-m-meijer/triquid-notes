import Foundation
import NaturalLanguage
import SwiftData

/// Finds notes about the same thing as a given note, entirely on device: TF-IDF vectors over the
/// cached notes (title and labels weigh more than body text), compared by cosine similarity.
/// Works in any language the tokenizer knows and needs no model download.
///
/// The index is built once per server profile in the background and rebuilt when the cache
/// changes (`invalidate()` after a sync).
@ModelActor
actor RelatedNotesIndex {
    struct Match: Sendable, Hashable, Identifiable {
        let noteId: String
        let title: String
        let noteType: String
        /// Cosine similarity, 0…1.
        let score: Double
        var id: String { noteId }
    }

    private struct Document {
        let noteId: String
        let title: String
        let noteType: String
        /// term → tf-idf weight, L2-normalised.
        var vector: [String: Double]
    }

    private var profileId: String?
    private var documents: [String: Document] = [:]
    private var isStale = true

    /// Body text beyond this adds little to "what is the note about" and costs time.
    private static let maxBodyCharacters = 6_000
    private static let titleWeight = 3
    private static let labelWeight = 4
    private static let minimumScore = 0.12

    func invalidate() {
        isStale = true
    }

    func related(to noteId: String, profileId: String, limit: Int = 6) throws -> [Match] {
        if isStale || self.profileId != profileId {
            try build(profileId: profileId)
        }
        guard let source = documents[noteId], !source.vector.isEmpty else { return [] }
        var matches: [Match] = []
        for (id, document) in documents where id != noteId {
            let score = Self.cosine(source.vector, document.vector)
            if score >= Self.minimumScore {
                matches.append(Match(noteId: id, title: document.title, noteType: document.noteType, score: score))
            }
        }
        return Array(matches.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Building

    private func build(profileId: String) throws {
        let notes = try modelContext.fetch(FetchDescriptor<CachedNote>(
            predicate: #Predicate { $0.serverProfileId == profileId && !$0.isProtected }
        ))
        let labels = try labelTerms(profileId: profileId)

        var termCounts: [String: [String: Int]] = [:]
        var documentFrequency: [String: Int] = [:]
        var meta: [String: (title: String, type: String)] = [:]
        for note in notes where !note.noteId.hasPrefix("_") {
            var counts: [String: Int] = [:]
            for term in Self.terms(in: note.title) { counts[term, default: 0] += Self.titleWeight }
            for term in labels[note.noteId] ?? [] { counts[term, default: 0] += Self.labelWeight }
            let body = String(SpotlightIndexer.plainText(for: note).prefix(Self.maxBodyCharacters))
            for term in Self.terms(in: body) { counts[term, default: 0] += 1 }
            guard !counts.isEmpty else { continue }
            termCounts[note.noteId] = counts
            meta[note.noteId] = (note.title, note.noteType)
            for term in counts.keys { documentFrequency[term, default: 0] += 1 }
        }

        let total = Double(max(termCounts.count, 1))
        var built: [String: Document] = [:]
        for (noteId, counts) in termCounts {
            var vector: [String: Double] = [:]
            for (term, count) in counts {
                let df = Double(documentFrequency[term] ?? 1)
                // Terms in nearly every note say nothing about this one.
                guard df / total < 0.5 || total < 4 else { continue }
                vector[term] = (1 + log(Double(count))) * log((1 + total) / df)
            }
            let norm = sqrt(vector.values.reduce(0) { $0 + $1 * $1 })
            if norm > 0 {
                for key in vector.keys { vector[key]! /= norm }
            }
            built[noteId] = Document(noteId: noteId, title: meta[noteId]?.title ?? "", noteType: meta[noteId]?.type ?? "text", vector: vector)
        }
        documents = built
        self.profileId = profileId
        isStale = false
    }

    private func labelTerms(profileId: String) throws -> [String: [String]] {
        let attributes = try modelContext.fetch(FetchDescriptor<CachedAttribute>(
            predicate: #Predicate { $0.serverProfileId == profileId && $0.type == "label" }
        ))
        var result: [String: [String]] = [:]
        for attribute in attributes where NoteLabelVisibility.isVisible(attribute.name) {
            // `#topic=garden` contributes "label:topic=garden", so only notes sharing it match on it.
            let term = "label:" + (attribute.value.isEmpty ? attribute.name : "\(attribute.name)=\(attribute.value)").lowercased()
            result[attribute.noteId, default: []].append(term)
        }
        return result
    }

    // MARK: - Text

    /// Lowercased, accent-folded words of three letters or more, without stop words or numbers.
    static func terms(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if word.count >= 3, !stopWords.contains(word), word.contains(where: \.isLetter) {
                result.append(word)
            }
            return true
        }
        return result
    }

    static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        let (small, large) = a.count < b.count ? (a, b) : (b, a)
        var sum = 0.0
        for (term, weight) in small {
            if let other = large[term] { sum += weight * other }
        }
        return sum
    }

    /// Frequent English and Dutch function words (the app's main languages); TF-IDF handles the rest.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "has", "have", "this", "that", "with", "from", "they", "will", "would", "there", "their", "what", "about", "which",
        "when", "your", "into", "than", "then", "them", "these", "some", "could", "other", "also", "just", "only", "over",
        "een", "het", "van", "dat", "die", "met", "voor", "zijn", "niet", "aan", "ook", "als", "maar", "bij", "nog",
        "wel", "naar", "kan", "wat", "dan", "door", "over", "uit", "deze", "dit", "worden", "wordt", "werd", "hun", "hij",
        "zij", "wij", "jij", "mijn", "jouw", "onze", "omdat", "toen", "geen", "meer", "veel", "heel", "hebben", "heeft",
    ]
}

/// The app-wide index, created on first use.
@MainActor
enum RelatedNotes {
    private static var index: RelatedNotesIndex?

    static var shared: RelatedNotesIndex {
        if let index { return index }
        let created = RelatedNotesIndex(modelContainer: PersistenceManager.shared.container)
        index = created
        return created
    }
}
