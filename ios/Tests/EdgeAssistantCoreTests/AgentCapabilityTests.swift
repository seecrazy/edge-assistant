import XCTest
import CryptoKit
@testable import EdgeAssistantCore

final class AgentCapabilityTests: XCTestCase {
    func testCompatibilityPinsRequestedModels() {
        let gemma = ModelCompatibilityChecker.check(
            repositoryID: "mlx-community/gemma-4-e2b-it-4bit",
            modelType: "gemma4"
        )
        XCTAssertEqual(gemma.compatibility, .supported)
        XCTAssertEqual(gemma.format, "mlx-vlm")

        let miniCPM = ModelCompatibilityChecker.check(
            repositoryID: "mlx-community/MiniCPM-V-4.7-35B-A3B-OptiQ-4bit",
            modelType: "minicpmv4_7"
        )
        XCTAssertEqual(miniCPM.compatibility, .unsupported)

        let mnn = ModelCompatibilityChecker.check(
            repositoryID: "taobao-mnn/MNN-Pocket-0.3B",
            modelType: "qwen3",
            tags: ["mnn"]
        )
        XCTAssertEqual(mnn.compatibility, .requiresConversion)
    }

    func testCompatibilityRequiresMLXLayoutBeforeTrustingArchitecture() {
        let rawTransformers = ModelCompatibilityChecker.check(
            repositoryID: "meta-llama/Llama-3.2-1B-Instruct",
            modelType: "llama"
        )
        XCTAssertEqual(rawTransformers.compatibility, .requiresConversion)

        let gguf = ModelCompatibilityChecker.check(
            repositoryID: "example/model-qwen3-gguf",
            modelType: "qwen3",
            tags: ["gguf"]
        )
        XCTAssertEqual(gguf.compatibility, .requiresConversion)

        let mlx = ModelCompatibilityChecker.check(
            repositoryID: "mlx-community/qwen3-1b-4bit",
            modelType: "qwen3"
        )
        XCTAssertEqual(mlx.compatibility, .supported)
        XCTAssertEqual(mlx.format, "mlx")

        let unknown = ModelCompatibilityChecker.check(
            repositoryID: "mlx-community/missing-config",
            modelType: nil
        )
        XCTAssertEqual(unknown.compatibility, .unknown)
    }

    func testSearchProbesCandidatesInParallelAndIsolatesProbeFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.protocolClasses = [SearchStubURLProtocol.self]
        let client = HuggingFaceModelCatalogClient(
            session: URLSession(configuration: configuration),
            searchProbeLimit: 6
        )
        SearchStubURLProtocol.reset()

        let candidates = try await client.searchModels(query: "test", limit: 10)
        XCTAssertEqual(candidates.count, 2)
        let supported = try XCTUnwrap(candidates.first { $0.repositoryID == "example/model-a" })
        XCTAssertEqual(supported.compatibility, .supported)
        XCTAssertEqual(supported.estimatedSizeBytes, 700_000_000)
        let unknown = try XCTUnwrap(candidates.first { $0.repositoryID == "example/model-b" })
        XCTAssertEqual(unknown.compatibility, .unknown)

        let configStarts = SearchStubURLProtocol.starts(for: "config")
        // model-a 一次主源 config；model-b 主源失败后追加一次镜像 config。
        XCTAssertEqual(configStarts.count, 3)
        let span = configStarts.max()!.timeIntervalSince(configStarts.min()!)
        XCTAssertLessThan(span, 0.20, "候选探测应并行执行，而不是等待上一个 config 请求完成")
    }

    func testSearchQueriesExpandCommonNamesToMLXQuantizations() {
        let qwen = HuggingFaceModelCatalogClient.searchQueries(for: "qwen")
        XCTAssertEqual(qwen, ["qwen", "mlx-community qwen 4bit", "mlx-community qwen 8bit"])

        let explicitMLX = HuggingFaceModelCatalogClient.searchQueries(for: "mlx-community/Qwen3-0.6B-4bit")
        XCTAssertEqual(explicitMLX, ["mlx-community/Qwen3-0.6B-4bit"])

        let empty = HuggingFaceModelCatalogClient.searchQueries(for: "  ")
        XCTAssertEqual(empty, ["mlx-community 4bit instruct"])
    }

    func testProbeFallsBackToMirrorWhenPrimaryConfigUnavailable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.protocolClasses = [MirrorProbeStubURLProtocol.self]
        let client = HuggingFaceModelCatalogClient(session: URLSession(configuration: configuration))
        MirrorProbeStubURLProtocol.reset()

        let candidates = try await client.searchModels(query: "test", limit: 1)
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidate.repositoryID, "example/model-b")
        XCTAssertEqual(candidate.modelType, "qwen3")
        XCTAssertEqual(candidate.compatibility, .supported)
        XCTAssertTrue(
            MirrorProbeStubURLProtocol.requestedPaths.contains {
                $0 == "https://huggingface.co/example/model-b/resolve/main/config.json"
            }
        )
        XCTAssertTrue(
            MirrorProbeStubURLProtocol.requestedPaths.contains {
                $0 == "https://hf-mirror.com/example/model-b/resolve/main/config.json"
            }
        )
    }

    func testManifestFallsBackToMirrorWhenPrimaryRequestTimesOut() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.protocolClasses = [MirrorStubURLProtocol.self]
        let client = HuggingFaceModelCatalogClient(session: URLSession(configuration: configuration))
        MirrorStubURLProtocol.reset(primaryTimesOut: true)

        let files = try await client.files(
            repositoryID: "example/model-a",
            mirrorBase: "https://hf-mirror.com/example/model-a/resolve/main/"
        )

        XCTAssertTrue(MirrorStubURLProtocol.requestedPaths.contains { $0.contains("huggingface.co") })
        XCTAssertTrue(MirrorStubURLProtocol.requestedPaths.contains { $0.contains("hf-mirror.com") })
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.path, "model.safetensors")
        XCTAssertEqual(files.first?.url.absoluteString, "https://hf-mirror.com/example/model-a/resolve/main/model.safetensors")
        XCTAssertTrue(
            MirrorStubURLProtocol.requestedPaths.contains {
                $0 == "https://hf-mirror.com/api/models/example/model-a/tree/main?recursive=true"
            }
        )
    }

    func testFactorySelectsTextAndVisionMLXBackends() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("factory-kind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data("fake-weight".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        defer { try? FileManager.default.removeItem(at: directory) }

        func asset(format: String) -> ModelAsset {
            ModelAsset(
                id: format, tier: .entry, version: "1.0.0",
                sha256: String(repeating: "a", count: 64), sizeBytes: 1,
                capabilities: [.chat], localDirectory: directory, format: format
            )
        }
        XCTAssertTrue(InferenceEngineFactory.make(for: asset(format: "mlx-4bit")) is MLXInferenceEngine)
        XCTAssertTrue(InferenceEngineFactory.make(for: asset(format: "mlx-vlm-4bit")) is MLXVisionLanguageEngine)
    }

    func testMemoryExtractorPersistsDeduplicatesAndRecalls() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-\(UUID().uuidString)", isDirectory: true)
        let keyProvider: @Sendable () throws -> SymmetricKey = {
            SymmetricKey(data: Data(repeating: 9, count: 32))
        }
        let deleteKeyProvider: @Sendable () throws -> Void = {}
        let store = AgentMemoryStore(
            directory: directory,
            keyProvider: keyProvider,
            deleteKeyProvider: deleteKeyProvider
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let candidates = AgentMemoryExtractor.candidates(
            from: "我叫小明，我喜欢黑咖啡。请记住下周三要复盘模型部署。",
            now: now
        )
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates.filter { $0.status == .confirmed }.count, 1)
        XCTAssertEqual(candidates.filter { $0.status == .pending }.count, 2)
        XCTAssertTrue(candidates.contains { $0.kind == .episodic && $0.status == .confirmed })

        _ = try await store.learn(from: "我叫小明，我喜欢黑咖啡。请记住下周三要复盘模型部署。")
        let records = try await store.records()
        XCTAssertEqual(records.filter { $0.status == .pending }.count, 2)
        let pendingFacts = try await store.facts()
        XCTAssertEqual(pendingFacts.count, 1)
        XCTAssertEqual(pendingFacts.first?.text, "下周三要复盘模型部署")

        let preference = try XCTUnwrap(records.first { $0.text.contains("黑咖啡") })
        try await store.confirm(preference.id)
        let confirmedFacts = try await store.facts()
        XCTAssertTrue(confirmedFacts.contains { $0.text.contains("黑咖啡") })

        let recalled = try await store.recall(query: "黑咖啡")
        XCTAssertTrue(recalled.contains { $0.id == preference.id })

        try await store.update(preference.id, text: "我喜欢高山乌龙茶")
        let updatedRecords = try await store.records()
        XCTAssertTrue(updatedRecords.contains { $0.text == "我喜欢高山乌龙茶" })

        try await store.delete(preference.id)
        let deletedRecords = try await store.records()
        XCTAssertFalse(deletedRecords.contains { $0.text == "我喜欢高山乌龙茶" })

        try await store.clearAll()
        let cleared = try await store.records()
        XCTAssertTrue(cleared.isEmpty)
    }

    func testHybridRecallExcludesPendingAndRespectsWorkingMemoryBudget() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let pending = AgentMemoryRecord(
            text: "我喜欢乌龙茶",
            kind: .semantic,
            status: .pending,
            confidence: 0.75,
            createdAt: now,
            lastSeenAt: now
        )
        let matching = AgentMemoryRecord(
            text: "我喜欢铁观音",
            kind: .semantic,
            status: .confirmed,
            confidence: 1,
            createdAt: now.addingTimeInterval(-86_400),
            lastSeenAt: now.addingTimeInterval(-86_400)
        )
        let recentUnrelated = AgentMemoryRecord(
            text: "记住周五复盘",
            kind: .episodic,
            status: .confirmed,
            confidence: 1,
            createdAt: now,
            lastSeenAt: now
        )
        let oldMatching = AgentMemoryRecord(
            text: "乌龙茶是最好的茶",
            kind: .semantic,
            status: .confirmed,
            confidence: 1,
            createdAt: now.addingTimeInterval(-120 * 86_400),
            lastSeenAt: now.addingTimeInterval(-120 * 86_400)
        )

        let selection = AgentMemoryRecall.select(
            records: [pending, matching, recentUnrelated, oldMatching],
            query: "乌龙茶",
            now: now,
            limit: 5,
            characterBudget: 1200
        )
        XCTAssertEqual(selection.records.first?.text, "乌龙茶是最好的茶")
        XCTAssertFalse(selection.records.contains { $0.id == pending.id })

        let budget = AgentMemoryRecall.select(
            records: [matching, oldMatching],
            query: "乌龙茶",
            now: now,
            limit: 5,
            characterBudget: 15
        )
        XCTAssertEqual(budget.records.count, 1)
        XCTAssertLessThanOrEqual(budget.usedCharacterCount, 15)
    }

    func testMemoryStoreUsesEncryptedSQLiteAndRemovesLegacyJSON() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("encrypted-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyData = Data(repeating: 7, count: 32)
        let deleteKeyCalled = LockedIsDeleted()
        let keyProvider: @Sendable () throws -> SymmetricKey = { SymmetricKey(data: keyData) }
        let deleteKeyProvider: @Sendable () throws -> Void = { deleteKeyCalled.value = true }
        let legacyFactsURL = directory.appendingPathComponent("agent-memory.json")
        let legacyTranscriptURL = directory.appendingPathComponent("conversation.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([MemoryFact(text: "旧记忆小明")]).write(to: legacyFactsURL)
        try encoder.encode([AgentChatTurn(role: .user, text: "旧会话黑咖啡")]).write(to: legacyTranscriptURL)

        let store = AgentMemoryStore(
            directory: directory,
            keyProvider: keyProvider,
            deleteKeyProvider: deleteKeyProvider
        )
        let facts = try await store.facts()
        let transcript = try await store.transcript()
        XCTAssertTrue(facts.contains { $0.text.contains("旧记忆小明") })
        XCTAssertTrue(transcript.contains { $0.text.contains("旧会话黑咖啡") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFactsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyTranscriptURL.path))

        try await store.learn(from: "记住乌龙茶")
        let databaseURL = directory.appendingPathComponent("agent-memory.sqlite")
        let rawDatabase = try Data(contentsOf: databaseURL)
        XCTAssertFalse(rawDatabase.range(of: Data("乌龙茶".utf8)) != nil)
        XCTAssertFalse(rawDatabase.range(of: Data("旧记忆小明".utf8)) != nil)

        try await store.clearAll()
        XCTAssertTrue(deleteKeyCalled.value)
        let cleared = try await store.facts()
        XCTAssertTrue(cleared.isEmpty)
    }

    private final class LockedIsDeleted: @unchecked Sendable {
        private let lock = NSLock()
        private var backingValue = false

        var value: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return backingValue
            }
            set {
                lock.lock()
                backingValue = newValue
                lock.unlock()
            }
        }
    }

    func testContextIncludesMemorySearchResultsAndHistory() {
        let memory = AgentMemoryRecord(
            text: "用户姓名是小明",
            kind: .semantic,
            status: .confirmed,
            confidence: 1
        )
        let pending = AgentMemoryRecord(
            text: "待确认不该注入",
            kind: .semantic,
            status: .pending,
            confidence: 0.75
        )
        let prompt = AgentContextBuilder.buildPrompt(
            userText: "最新版本是什么？",
            history: [AgentChatTurn(role: .user, text: "上一轮")],
            memories: [memory, pending],
            searchResults: [WebSearchResult(title: "Release", url: "https://example.com", content: "v3 released")],
            searchQuery: "latest release"
        )
        XCTAssertTrue(prompt.contains("用户姓名是小明"))
        XCTAssertTrue(prompt.contains("[语义]"))
        XCTAssertFalse(prompt.contains("待确认不该注入"))
        XCTAssertFalse(prompt.contains("你是在用户设备本地运行的 Agent"))
        XCTAssertTrue(prompt.contains("上一轮"))
        XCTAssertTrue(prompt.contains("https://example.com"))
        XCTAssertTrue(prompt.contains("latest release"))
    }

    func testDownloadRejectsBlockedCompatibilityWithoutFetching() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocked-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ModelStoreManager(
            baseDirectory: base,
            fetcher: RecordingFileFetcher()
        )
        let model = OpenSourceModel(
            id: "blocked", displayName: "Blocked", source: "taobao-mnn/model",
            format: "mnn", parameters: "0.3B", sizeBytes: 1,
            license: "Apache-2.0", minTier: .entry, capabilities: [],
            files: [], compatibility: .requiresConversion,
            compatibilityReason: "needs conversion"
        )
        do {
            _ = try await store.download(model)
            XCTFail("Expected compatibility block")
        } catch let error as ModelStoreError {
            XCTAssertEqual(error, .compatibilityBlocked("needs conversion"))
        }
    }

    func testMemoryGateBlocksModelBeforeSystemKill() {
        let decision = ModelMemoryGate.evaluate(
            modelBytes: 3_600_000_000,
            availableBytes: 4_000_000_000
        )
        XCTAssertFalse(decision.canLoad)
        XCTAssertEqual(decision.requiredBytes, 5_100_000_000)

        let smaller = ModelMemoryGate.evaluate(
            modelBytes: 700_000_000,
            availableBytes: 3_000_000_000
        )
        XCTAssertTrue(smaller.canLoad)
    }
}

private struct RecordingFileFetcher: ModelFileFetching {
    func fetch(
        from url: URL,
        to destination: URL,
        expectedBytes: Int64?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        XCTFail("Blocked models must not download")
        try Data("blocked".utf8).write(to: destination)
    }
}

private final class SearchStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requestStarts: [String: [Date]] = [:]

    static func reset() {
        lock.lock()
        requestStarts = [:]
        lock.unlock()
    }

    static func starts(for marker: String) -> [Date] {
        lock.lock()
        defer { lock.unlock() }
        return (requestStarts[marker] ?? []).sorted()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        let response: (status: Int, data: Data, delay: UInt32)

        if url.contains("filter=text-generation") {
            response = (
                200,
                Data("""
                [
                  {"id":"example/model-a","tags":["mlx"],"safetensors":{"total":700000000}},
                  {"id":"example/model-b","tags":["mlx"]}
                ]
                """.utf8),
                0
            )
        } else if url.contains("filter=image-text-to-text") {
            response = (200, Data("[]".utf8), 0)
        } else if url.contains("/model-a/resolve/main/config.json") {
            recordStart("config")
            response = (200, Data(#"{"model_type":"qwen3","architectures":["Qwen3ForCausalLM"]}"#.utf8), 200)
        } else if url.contains("/model-b/resolve/main/config.json") {
            recordStart("config")
            response = (500, Data("unavailable".utf8), 200)
        } else if url.contains("/api/models/example/model-a") {
            response = (
                200,
                Data(#"{"id":"example/model-a","tags":["mlx"],"safetensors":{"total":700000000}}"#.utf8),
                0
            )
        } else {
            response = (404, Data("{}".utf8), 0)
        }

        if response.delay > 0 {
            usleep(response.delay)
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func recordStart(_ marker: String) {
        Self.lock.lock()
        Self.requestStarts[marker, default: []].append(Date())
        Self.lock.unlock()
    }
}

private final class MirrorProbeStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var paths: [String] = []

    static var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    static func reset() {
        lock.lock()
        paths = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.absoluteString ?? ""
        Self.lock.lock()
        Self.paths.append(path)
        Self.lock.unlock()

        let response: (status: Int, data: Data)
        if path.contains("/api/models?search=") {
            response = (
                200,
                Data("""
                [{"id":"example/model-b","tags":["mlx"],"safetensors":{"total":700000000}}]
                """.utf8)
            )
        } else if path == "https://huggingface.co/example/model-b/resolve/main/config.json" {
            response = (503, Data("primary unavailable".utf8))
        } else if path == "https://hf-mirror.com/example/model-b/resolve/main/config.json" {
            response = (200, Data(#"{"model_type":"qwen3","architectures":["Qwen3ForCausalLM"]}"#.utf8))
        } else {
            response = (404, Data("{}".utf8))
        }

        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MirrorStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var paths: [String] = []
    private static var primaryTimesOut = false

    static var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    static func reset(primaryTimesOut: Bool = false) {
        lock.lock()
        paths = []
        self.primaryTimesOut = primaryTimesOut
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.absoluteString ?? ""
        Self.lock.lock()
        Self.paths.append(path)
        Self.lock.unlock()

        let isMirror = path.contains("hf-mirror.com")
        if !isMirror, Self.primaryTimesOut {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }

        let payload = isMirror
            ? Data(#"[{"type":"file","path":"model.safetensors","size":123}]"#.utf8)
            : Data("[]".utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
