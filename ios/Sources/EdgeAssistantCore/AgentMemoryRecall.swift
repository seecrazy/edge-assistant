import Foundation

/// IOS-18 deterministic local hybrid recall. No network, no cloud embedding,
/// and no plaintext database index.
public enum AgentMemoryRecall {
    public struct Selection: Equatable, Sendable {
        public let records: [AgentMemoryRecord]
        public let usedCharacterCount: Int
        public let hasLexicalMatch: Bool
    }

    public static func select(
        records: [AgentMemoryRecord],
        query: String,
        now: Date = Date(),
        limit: Int = 5,
        characterBudget: Int = 1200
    ) -> Selection {
        let eligible = records.filter { $0.status == .confirmed }
        guard !eligible.isEmpty, limit > 0, characterBudget > 0 else {
            return Selection(records: [], usedCharacterCount: 0, hasLexicalMatch: false)
        }

        let ranked = eligible.map { record in
            (record: record, score: score(record, query: query, corpus: eligible, now: now))
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.record.lastSeenAt > $1.record.lastSeenAt
        }

        let hasLexicalMatch = ranked.first?.score ?? 0 >= 0.12
        var selected: [AgentMemoryRecord] = []
        var usedCharacters = 0

        for item in ranked where selected.count < limit {
            let required = item.record.text.count + 2
            if required > characterBudget { continue }
            if usedCharacters + required > characterBudget { continue }
            selected.append(item.record)
            usedCharacters += required
        }

        return Selection(
            records: selected,
            usedCharacterCount: usedCharacters,
            hasLexicalMatch: hasLexicalMatch
        )
    }

    static func score(
        _ record: AgentMemoryRecord,
        query: String,
        corpus: [AgentMemoryRecord],
        now: Date
    ) -> Double {
        let queryFeatures = Set(features(in: query))
        guard !queryFeatures.isEmpty else { return 0 }

        let documentFeatures = corpus.map {
            (id: $0.id, features: Set(features(in: $0.text)))
        }
        var queryWeight = 0.0
        var overlapWeight = 0.0
        var recordWeight = 0.0
        let recordFeatures = Set(features(in: record.text))
        for feature in queryFeatures {
            let documentCount = documentFeatures.filter { $0.features.contains(feature) }.count
            let idf = log(Double(corpus.count + 1) / Double(documentCount + 1)) + 0.25
            queryWeight += idf
            if recordFeatures.contains(feature) {
                overlapWeight += idf
                recordWeight += idf
            }
        }

        // Short memories should not be punished only because the query has
        // extra words. Normalize by the smaller weighted feature set, but cap
        // at 1.0 so a short memory cannot exceed perfect overlap.
        let relevance = min(1, overlapWeight / max(0.001, min(queryWeight, recordWeight)))
        let elapsedDays = max(0, now.timeIntervalSince(record.lastSeenAt)) / 86_400
        let recency = exp(-log(2) * elapsedDays / 21.0)
        let kindWeight = record.kind == .semantic ? 0.08 : 0.05
        return min(1, max(0, 0.72 * relevance + 0.22 * recency + kindWeight))
    }

    static func features(in text: String) -> [String] {
        let normalized = text.lowercased()
        let words = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var result: Set<String> = []
        for word in words {
            result.insert(word)
            let characters = Array(word)
            characters.forEach { result.insert(String($0)) }
            if characters.count > 4 {
                for index in 0..<(characters.count - 1) {
                    result.insert(String(characters[index...index + 1]))
                }
            }
        }
        return Array(result)
    }
}
