import Foundation
import CryptoKit
import SQLite3

public struct AgentChatTurn: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user, assistant, system
    }

    public let role: Role
    public let text: String
    public let createdAt: Date

    public init(role: Role, text: String, createdAt: Date = Date()) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public struct MemoryFact: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let lastSeenAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

public enum AgentMemoryKind: String, Codable, Equatable, Sendable, CaseIterable {
    case semantic
    case episodic

    public var displayName: String {
        switch self {
        case .semantic: return "语义"
        case .episodic: return "情景"
        }
    }
}

public enum AgentMemoryStatus: String, Codable, Equatable, Sendable {
    case confirmed
    case pending

    public var displayName: String {
        switch self {
        case .confirmed: return "已确认"
        case .pending: return "待确认"
        }
    }
}

public struct AgentMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var kind: AgentMemoryKind
    public var status: AgentMemoryStatus
    public var confidence: Double
    public let createdAt: Date
    public var lastSeenAt: Date
    public let sourceExcerpt: String

    public init(
        id: UUID = UUID(),
        text: String,
        kind: AgentMemoryKind,
        status: AgentMemoryStatus,
        confidence: Double,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date(),
        sourceExcerpt: String = ""
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.status = status
        self.confidence = min(max(confidence, 0), 1)
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.sourceExcerpt = String(sourceExcerpt.prefix(160))
    }

    public var fact: MemoryFact {
        MemoryFact(id: id, text: text, createdAt: createdAt, lastSeenAt: lastSeenAt)
    }
}

public struct AgentMemoryCandidate: Equatable, Sendable {
    public let text: String
    public let kind: AgentMemoryKind
    public let status: AgentMemoryStatus
    public let confidence: Double
    public let sourceExcerpt: String

    public init(
        text: String,
        kind: AgentMemoryKind,
        status: AgentMemoryStatus,
        confidence: Double,
        sourceExcerpt: String = ""
    ) {
        self.text = text
        self.kind = kind
        self.status = status
        self.confidence = confidence
        self.sourceExcerpt = sourceExcerpt
    }
}

public enum AgentMemoryExtractor {
    public static func candidates(from text: String, now: Date = Date()) -> [AgentMemoryCandidate] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var results: [AgentMemoryCandidate] = []

        func candidate(
            after keyword: String,
            kind: AgentMemoryKind,
            status: AgentMemoryStatus,
            confidence: Double
        ) {
            guard let keywordRange = trimmed.range(of: keyword) else { return }
            let remainder = String(trimmed[keywordRange.upperBound...])
            let separators = CharacterSet(charactersIn: "，,。.；;！!？?\n\r")
            let segment: String
            if status == .confirmed {
                segment = String(remainder.prefix(160))
            } else if let range = remainder.rangeOfCharacter(from: separators) {
                segment = String(remainder[..<range.lowerBound])
            } else {
                segment = String(remainder.prefix(160))
            }
            results.append(
                AgentMemoryCandidate(
                    text: segment,
                    kind: kind,
                    status: status,
                    confidence: confidence,
                    sourceExcerpt: String(trimmed.prefix(160))
                )
            )
        }

        candidate(after: "记住", kind: .episodic, status: .confirmed, confidence: 1.0)
        for keyword in ["我的名字是", "我的名字叫", "我的姓名是", "我叫", "我是"] {
            candidate(after: keyword, kind: .semantic, status: .pending, confidence: 0.9)
        }
        for keyword in ["我喜欢", "我偏爱", "我偏好", "我不喜欢"] {
            candidate(after: keyword, kind: .semantic, status: .pending, confidence: 0.75)
        }
        for keyword in ["我的工作是", "我的职业是", "我的职位是", "我的工作为", "我的职业为", "我的职位为"] {
            candidate(after: keyword, kind: .semantic, status: .pending, confidence: 0.7)
        }

        return results
            .map {
                AgentMemoryCandidate(
                    text: $0.text
                        .replacingOccurrences(of: "^[，,。.！!？?\\s]+", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "[，,。.！!？?\\s]+$", with: "", options: .regularExpression),
                    kind: $0.kind,
                    status: $0.status,
                    confidence: $0.confidence,
                    sourceExcerpt: $0.sourceExcerpt
                )
            }
            .filter { $0.text.count >= 2 && $0.text.count <= 160 }
            .deduplicatedTextually()
    }

    public static func facts(from text: String, now: Date = Date()) -> [MemoryFact] {
        candidates(from: text, now: now)
            .filter { $0.status == .confirmed }
            .map { MemoryFact(text: $0.text, createdAt: now, lastSeenAt: now) }
    }
}

public enum AgentMemoryError: Error, Equatable {
    case databaseUnavailable(String)
    case encryptionUnavailable
    case corruptedPayload(String)
    case invalidMemoryText
    case recordNotFound
}

extension AgentMemoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable(let reason):
            return "本地加密数据库不可用：\(reason)"
        case .encryptionUnavailable:
            return "无法解锁本地加密数据。请重试；数据密钥在系统安全存储中。"
        case .corruptedPayload(let kind):
            return "本地加密数据校验失败：\(kind)。为避免错误记忆，已停止加载。"
        case .invalidMemoryText:
            return "记忆内容必须在 2–160 字之间。"
        case .recordNotFound:
            return "未找到这条记忆，可能已被删除。"
        }
    }
}

/// 系统安全存储中的 256-bit 数据密钥；测试可注入确定性 provider。
public struct KeychainMemoryKeyProvider: Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.startthree.edgeassistant", account: String = "agent-store-master-key") {
        self.service = service
        self.account = account
    }

    public func key() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess || insertStatus == errSecDuplicateItem else {
            throw AgentMemoryError.encryptionUnavailable
        }
        if insertStatus == errSecDuplicateItem {
            var existing: AnyObject?
            let readStatus = SecItemCopyMatching(query as CFDictionary, &existing)
            guard readStatus == errSecSuccess, let data = existing as? Data, data.count == 32 else {
                throw AgentMemoryError.encryptionUnavailable
            }
            return SymmetricKey(data: data)
        }
        return key
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentMemoryError.encryptionUnavailable
        }
    }
}

/// SQLite 只保存密文；JSON 和索引字段都不落明文。
struct EncryptedSQLiteAgentStore {
    static let transientDestructor = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    let databaseURL: URL
    let keyProvider: @Sendable () throws -> SymmetricKey

    func read(_ kind: String) throws -> Data? {
        try open { database in
            let sql = "SELECT payload FROM agent_blob WHERE kind = ? LIMIT 1"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AgentMemoryError.databaseUnavailable(lastError(database))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, kind, -1, Self.transientDestructor)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
            let count = Int(sqlite3_column_bytes(statement, 0))
            return Data(bytes: bytes, count: count)
        }
    }

    func write(_ kind: String, data: Data) throws {
        try open { database in
            let sql = """
            INSERT INTO agent_blob(kind, payload, updated_at)
            VALUES(?, ?, ?)
            ON CONFLICT(kind) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AgentMemoryError.databaseUnavailable(lastError(database))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, kind, -1, Self.transientDestructor)
            data.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(raw.count), Self.transientDestructor)
            }
            sqlite3_bind_int64(statement, 3, Int64(Date().timeIntervalSince1970))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw AgentMemoryError.databaseUnavailable(lastError(database))
            }
        }
    }

    func clear() throws {
        try open { database in
            guard sqlite3_exec(database, "DELETE FROM agent_blob", nil, nil, nil) == SQLITE_OK else {
                throw AgentMemoryError.databaseUnavailable(lastError(database))
            }
        }
    }

    func delete(_ kind: String) throws {
        try open { database in
            let sql = "DELETE FROM agent_blob WHERE kind = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AgentMemoryError.databaseUnavailable(lastError(database))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, kind, -1, Self.transientDestructor)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw AgentMemoryError.databaseUnavailable(lastError(database))
            }
        }
    }

    private func open<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            sqlite3_close_v2(database)
            throw AgentMemoryError.databaseUnavailable("无法打开数据库")
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE IF NOT EXISTS agent_blob(kind TEXT PRIMARY KEY, payload BLOB NOT NULL, updated_at INTEGER NOT NULL)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw AgentMemoryError.databaseUnavailable(lastError(database))
        }
        return try body(database)
    }

    private func decrypt(_ data: Data?, kind: String) throws -> Data? {
        guard let data, !data.isEmpty else { return nil }
        guard let sealed = try? AES.GCM.SealedBox(combined: data) else {
            throw AgentMemoryError.corruptedPayload(kind)
        }
        do {
            return try AES.GCM.open(sealed, using: keyProvider())
        } catch {
            throw AgentMemoryError.corruptedPayload(kind)
        }
    }

    func decryptData(_ kind: String) throws -> Data? {
        try decrypt(try read(kind), kind: kind)
    }

    func encryptData(_ data: Data, kind: String) throws {
        let sealed = try AES.GCM.seal(data, using: keyProvider())
        guard let combined = sealed.combined else {
            throw AgentMemoryError.encryptionUnavailable
        }
        try write(kind, data: combined)
    }

    private func lastError(_ database: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(database) else { return "未知错误" }
        return String(cString: message)
    }
}

public actor AgentMemoryStore {
    private let databaseURL: URL
    private let legacyFactsURL: URL
    private let legacyTranscriptURL: URL
    private let sqlite: EncryptedSQLiteAgentStore
    private let now: @Sendable () -> Date
    private let deleteKey: @Sendable () throws -> Void
    private var cachedRecords: [AgentMemoryRecord]?

    public init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        keyProvider: @escaping @Sendable () throws -> SymmetricKey = { try KeychainMemoryKeyProvider().key() },
        deleteKeyProvider: @escaping @Sendable () throws -> Void = { try KeychainMemoryKeyProvider().delete() }
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.databaseURL = directory.appendingPathComponent("agent-memory.sqlite")
        self.legacyFactsURL = directory.appendingPathComponent("agent-memory.json")
        self.legacyTranscriptURL = directory.appendingPathComponent("conversation.json")
        self.sqlite = EncryptedSQLiteAgentStore(databaseURL: databaseURL, keyProvider: keyProvider)
        self.now = now
        self.deleteKey = deleteKeyProvider
    }

    public func records() throws -> [AgentMemoryRecord] {
        if let cachedRecords { return cachedRecords }
        try migrateLegacyIfNeeded()

        if let records = try load([AgentMemoryRecord].self, kind: "records") {
            cachedRecords = records
            return records
        }

        let upgraded: [AgentMemoryRecord]
        if let legacyFacts = try load([MemoryFact].self, kind: "facts") {
            upgraded = legacyFacts.map(Self.upgradedRecord(from:))
        } else {
            upgraded = []
        }
        try save(upgraded, kind: "records")
        try sqlite.delete("facts")
        cachedRecords = upgraded
        return upgraded
    }

    public func facts() throws -> [MemoryFact] {
        try records().filter { $0.status == .confirmed }.map(\.fact)
    }

    public func transcript() throws -> [AgentChatTurn] {
        try migrateLegacyIfNeeded()
        return try load([AgentChatTurn].self, kind: "transcript") ?? []
    }

    public func saveTranscript(_ turns: [AgentChatTurn]) throws {
        let bounded = Array(turns.suffix(200))
        try save(bounded, kind: "transcript")
    }

    public func learn(from text: String) throws -> [AgentMemoryRecord] {
        try merge(AgentMemoryExtractor.candidates(from: text, now: now()))
    }

    public func learnCandidates(from text: String) throws -> [AgentMemoryRecord] {
        try merge(AgentMemoryExtractor.candidates(from: text, now: now()))
    }

    public func recall(query: String, limit: Int = 5) throws -> [AgentMemoryRecord] {
        AgentMemoryRecall.select(
            records: try records(),
            query: query,
            now: now(),
            limit: limit,
            characterBudget: 1200
        ).records
    }

    public func confirm(_ id: UUID) throws {
        try mutate(id: id) { record, timestamp in
            record.status = .confirmed
            record.confidence = max(record.confidence, 1.0)
            record.lastSeenAt = timestamp
        }
    }

    public func dismiss(_ id: UUID) throws {
        try remove(id: id)
    }

    public func delete(_ id: UUID) throws {
        try remove(id: id)
    }

    public func update(_ id: UUID, text newText: String) throws {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 160 else {
            throw AgentMemoryError.invalidMemoryText
        }
        try mutate(id: id) { record, timestamp in
            record.text = trimmed
            record.status = .confirmed
            record.confidence = 1.0
            record.lastSeenAt = timestamp
        }
    }

    private func merge(_ extracted: [AgentMemoryCandidate]) throws -> [AgentMemoryRecord] {
        guard !extracted.isEmpty else { return [] }
        var all = try records()
        var added: [AgentMemoryRecord] = []
        let timestamp = now()
        for candidate in extracted {
            let normalized = candidate.text.lowercased()
            if let index = all.firstIndex(where: { $0.text.lowercased() == normalized }) {
                let existing = all[index]
                let shouldPromote = existing.status == .pending && candidate.status == .confirmed
                all[index] = AgentMemoryRecord(
                    id: existing.id,
                    text: existing.text,
                    kind: shouldPromote ? candidate.kind : existing.kind,
                    status: shouldPromote ? .confirmed : existing.status,
                    confidence: shouldPromote ? max(existing.confidence, candidate.confidence) : existing.confidence,
                    createdAt: existing.createdAt,
                    lastSeenAt: timestamp,
                    sourceExcerpt: existing.sourceExcerpt
                )
                if shouldPromote {
                    added.append(all[index])
                }
            } else {
                let record = AgentMemoryRecord(
                    text: candidate.text,
                    kind: candidate.kind,
                    status: candidate.status,
                    confidence: candidate.confidence,
                    createdAt: timestamp,
                    lastSeenAt: timestamp,
                    sourceExcerpt: candidate.sourceExcerpt
                )
                all.append(record)
                added.append(record)
            }
        }
        let bounded = Array(all.suffix(200))
        try save(bounded, kind: "records")
        cachedRecords = bounded
        return added
    }

    private func mutate(
        id: UUID,
        _ change: (inout AgentMemoryRecord, Date) -> Void
    ) throws {
        var all = try records()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw AgentMemoryError.recordNotFound
        }
        let timestamp = now()
        change(&all[index], timestamp)
        try save(all, kind: "records")
        cachedRecords = all
    }

    private func remove(id: UUID) throws {
        var all = try records()
        let originalCount = all.count
        all.removeAll { $0.id == id }
        guard all.count != originalCount else {
            throw AgentMemoryError.recordNotFound
        }
        try save(all, kind: "records")
        cachedRecords = all
    }

    public func clearAll() throws {
        try deleteKey()
        try sqlite.clear()
        try? FileManager.default.removeItem(at: legacyFactsURL)
        try? FileManager.default.removeItem(at: legacyTranscriptURL)
        cachedRecords = nil
    }

    private func migrateLegacyIfNeeded() throws {
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            let factsData = try? sqlite.decryptData("facts")
            let transcriptData = try? sqlite.decryptData("transcript")
            if factsData != nil || transcriptData != nil {
                return
        }
        }

        if let legacyFacts = Self.load([MemoryFact].self, from: legacyFactsURL), !legacyFacts.isEmpty {
            try save(legacyFacts, kind: "facts")
            cachedRecords = legacyFacts.map(Self.upgradedRecord(from:))
            try FileManager.default.removeItem(at: legacyFactsURL)
        }
        if let legacyTranscript = Self.load([AgentChatTurn].self, from: legacyTranscriptURL), !legacyTranscript.isEmpty {
            try save(legacyTranscript, kind: "transcript")
            try FileManager.default.removeItem(at: legacyTranscriptURL)
        }
    }

    private func load<T: Decodable>(_ type: T.Type, kind: String) throws -> T? {
        guard let plaintext = try sqlite.decryptData(kind) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: plaintext)
        } catch {
            throw AgentMemoryError.corruptedPayload(kind)
        }
    }

    private func save<T: Encodable>(_ value: T, kind: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try sqlite.encryptData(data, kind: kind)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private static func upgradedRecord(from fact: MemoryFact) -> AgentMemoryRecord {
        let explicit = fact.text.lowercased().contains("记住")
        return AgentMemoryRecord(
            id: fact.id,
            text: fact.text,
            kind: explicit ? .episodic : .semantic,
            status: .confirmed,
            confidence: 1.0,
            createdAt: fact.createdAt,
            lastSeenAt: fact.lastSeenAt
        )
    }
}

private extension Sequence where Element == AgentMemoryCandidate {
    func deduplicatedTextually() -> [AgentMemoryCandidate] {
        var seen = Set<String>()
        return filter { seen.insert($0.text.lowercased()).inserted }
    }
}
