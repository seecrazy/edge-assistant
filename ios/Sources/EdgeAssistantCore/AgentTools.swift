import Foundation
import Security

public struct WebSearchResult: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public let content: String

    public init(id: String = UUID().uuidString, title: String, url: String, content: String) {
        self.id = id
        self.title = title
        self.url = url
        self.content = content
    }
}

public protocol WebSearchServicing: Sendable {
    func search(query: String, apiKey: String, limit: Int) async throws -> [WebSearchResult]
}

/// 第一版使用 Tavily 的稳定 JSON API；后续换服务商只替换 client，不改授权和 prompt 边界。
public struct TavilyWebSearchClient: WebSearchServicing {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(query: String, apiKey: String, limit: Int) async throws -> [WebSearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AgentToolError.emptyQuery
        }
        guard !apiKey.isEmpty else { throw AgentToolError.apiKeyMissing }
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "api_key": apiKey,
            "query": query,
            "search_depth": "basic",
            "max_results": max(1, min(limit, 8)),
            "include_answer": false,
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentToolError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentToolError.searchFailed(status: http.statusCode)
        }
        struct Payload: Decodable {
            struct Item: Decodable {
                let title: String?
                let url: String?
                let content: String?
            }

            let results: [Item]?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.results ?? []).compactMap { item in
            guard let url = item.url else { return nil }
            return WebSearchResult(
                title: item.title ?? url,
                url: url,
                content: String((item.content ?? "").prefix(800))
            )
        }
    }
}

public enum AgentContextBuilder {
    public static func buildPrompt(
        userText: String,
        history: [AgentChatTurn],
        memories: [AgentMemoryRecord],
        searchResults: [WebSearchResult],
        searchQuery: String?
    ) -> String {
        var sections: [String] = []

        let confirmedMemories = memories.filter { $0.status == .confirmed }
        if !confirmedMemories.isEmpty {
            var memoryLines: [String] = []
            var usedCharacters = 0
            for record in confirmedMemories where memoryLines.count < 5 {
                let line = "- [\(record.kind.displayName)] \(record.text)"
                if usedCharacters + line.count > 1200 { break }
                memoryLines.append(line)
                usedCharacters += line.count
            }
            sections.append("长期记忆（仅已确认，仅供个性化回答；不含本次检索信息）：\n\(memoryLines.joined(separator: "\n"))")
        }

        let recent = history.suffix(8).map { turn in
            "\(turn.role == .user ? "用户" : turn.role == .assistant ? "助手" : "系统"): \(turn.text.prefix(400))"
        }
        if !recent.isEmpty {
            sections.append("最近对话：\n\(recent.joined(separator: "\n"))")
        }

        if let searchQuery, !searchResults.isEmpty {
            let results = searchResults.enumerated().map { index, result in
                "[\(index + 1)] \(result.title)\nURL: \(result.url)\n摘要: \(result.content)"
            }.joined(separator: "\n\n")
            sections.append("用户已授权本次联网检索。检索词：\(searchQuery)\n仅根据这些结果回答实时信息，并标注 [编号]；无结果依据时明确说明。\n\(results)")
        }

        sections.append("当前用户输入：\(userText)")
        return sections.joined(separator: "\n\n")
    }
}

public enum AgentToolError: Error, Equatable {
    case apiKeyMissing
    case emptyQuery
    case invalidResponse
    case searchFailed(status: Int)
    case keychainUnavailable(status: Int32)
}

public struct KeychainStore {
    private let service: String
    private let account: String

    public init(service: String = "com.startthree.edgeassistant", account: String = "tavily-search-api-key") {
        self.service = service
        self.account = account
    }

    public func save(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus != errSecSuccess {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            if insertStatus != errSecSuccess {
                throw AgentToolError.invalidResponse
            }
        }
    }

    public func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentToolError.keychainUnavailable(status: status)
        }
    }
}
