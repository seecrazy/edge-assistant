import Foundation
import SQLite3

public enum LocalAgentTool: String, CaseIterable, Codable, Identifiable, Sendable {
    case createReminder
    case createTimer
    case queryCalendar
    case createCalendarEvent
    case lookupContact
    case dictionaryLookup

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .createReminder: return "创建提醒"
        case .createTimer: return "设置计时"
        case .queryCalendar: return "查询日程"
        case .createCalendarEvent: return "创建日程"
        case .lookupContact: return "查询联系人"
        case .dictionaryLookup: return "本地查词"
        }
    }

    public var requiresPermission: Bool {
        switch self {
        case .createReminder, .queryCalendar, .createCalendarEvent, .lookupContact:
            return true
        case .createTimer, .dictionaryLookup:
            return false
        }
    }
}

public struct ToolGrant: Codable, Equatable, Identifiable, Sendable {
    public var id: LocalAgentTool { tool }
    public let tool: LocalAgentTool
    public let granted: Bool
    public let updatedAt: Date

    public init(tool: LocalAgentTool, granted: Bool, updatedAt: Date) {
        self.tool = tool
        self.granted = granted
        self.updatedAt = updatedAt
    }
}

public enum ToolGrantError: Error, Equatable {
    case databaseUnavailable(String)
}

extension ToolGrantError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable(let reason):
            return "工具授权存储不可用：\(reason)"
        }
    }
}

/// 授权记录不含用户内容，使用普通 SQLite；敏感会话/记忆仍走 AES-GCM 加密库。
public actor ToolGrantStore {
    private let databaseURL: URL
    private let now: @Sendable () -> Date

    public init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.databaseURL = directory.appendingPathComponent("tool-grants.sqlite")
        self.now = now
    }

    public func grants() throws -> [ToolGrant] {
        try open { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT tool, granted, updated_at FROM agent_tool_grants", -1, &statement, nil) == SQLITE_OK else {
                throw ToolGrantError.databaseUnavailable("无法读取授权")
            }
            defer { sqlite3_finalize(statement) }
            var results: [ToolGrant] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(statement, 0),
                      let tool = LocalAgentTool(rawValue: String(cString: raw)) else { continue }
                let granted = sqlite3_column_int(statement, 1) != 0
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                results.append(ToolGrant(tool: tool, granted: granted, updatedAt: updatedAt))
            }
            let defaults = Dictionary(uniqueKeysWithValues: results.map { ($0.tool, $0) })
            return LocalAgentTool.allCases.map { tool in
                defaults[tool] ?? ToolGrant(tool: tool, granted: false, updatedAt: .distantPast)
            }
        }
    }

    public func isGranted(_ tool: LocalAgentTool) throws -> Bool {
        try grants().first { $0.tool == tool }?.granted ?? false
    }

    public func set(_ tool: LocalAgentTool, granted: Bool) throws {
        try open { database in
            var statement: OpaquePointer?
            let sql = """
            INSERT INTO agent_tool_grants(tool, granted, updated_at)
            VALUES(?, ?, ?)
            ON CONFLICT(tool) DO UPDATE SET granted = excluded.granted, updated_at = excluded.updated_at
            """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ToolGrantError.databaseUnavailable("无法写入授权")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, tool.rawValue, -1, Self.transient)
            sqlite3_bind_int(statement, 2, granted ? 1 : 0)
            sqlite3_bind_double(statement, 3, now().timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ToolGrantError.databaseUnavailable("无法保存授权")
            }
        }
    }

    public func clearAll() throws {
        try open { database in
            guard sqlite3_exec(database, "DELETE FROM agent_tool_grants", nil, nil, nil) == SQLITE_OK else {
                throw ToolGrantError.databaseUnavailable("无法清除授权")
            }
        }
    }

    private func open<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            sqlite3_close_v2(database)
            throw ToolGrantError.databaseUnavailable("无法打开数据库")
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE IF NOT EXISTS agent_tool_grants(tool TEXT PRIMARY KEY, granted INTEGER NOT NULL, updated_at REAL NOT NULL)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw ToolGrantError.databaseUnavailable("无法初始化授权表")
        }
        return try body(database)
    }

    private static let transient = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )
}
