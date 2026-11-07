import XCTest
@testable import EdgeAssistantCore

final class InferenceEngineTests: XCTestCase {
    private let asset = ModelAsset(
        id: "flagship-1.0.0",
        tier: .flagship,
        version: "1.0.0",
        sha256: String(repeating: "a", count: 64),
        sizeBytes: 1,
        capabilities: [.chat, .voice, .video]
    )

    func testStreamsDeterministicOutputAndDoneMetrics() async throws {
        let engine = MockInferenceEngine()
        try engine.load(asset)

        var text = ""
        var doneMetrics: InferenceMetrics?
        for try await event in engine.generateStream(InferenceRequest(mode: .chat, prompt: "你好")) {
            switch event {
            case let .token(t, _, chars): text += t
            case let .done(m): doneMetrics = m
            }
        }

        XCTAssertEqual(text, "本地模拟推理完成：你好")
        XCTAssertEqual(doneMetrics?.cancelled, false)
        XCTAssertGreaterThan(doneMetrics?.outputChars ?? 0, 0)
    }

    func testRejectsUnsupportedModesAndMissingPrompt() async throws {
        let engine = MockInferenceEngine()
        try engine.load(ModelAsset(
            id: "entry-1.0.0", tier: .entry, version: "1.0.0",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 1, capabilities: [.chat, .voice]
        ))

        await XCTAssertThrowsErrorAsync(try await collect(engine.generateStream(InferenceRequest(mode: .video, prompt: "看"))))
        await XCTAssertThrowsErrorAsync(try await collect(engine.generateStream(InferenceRequest(mode: .chat, prompt: "  "))))
    }

    func testFailsBeforeModelIsLoaded() async {
        let engine = MockInferenceEngine()
        await XCTAssertThrowsErrorAsync(try await collect(engine.generateStream(InferenceRequest(mode: .chat, prompt: "hi"))))
    }

    func testCancellationRecordsCancelledMetrics() async throws {
        let engine = MockInferenceEngine(
            replyBuilder: { _ in "这是一段足够长的输出，用于验证取消能力。" },
            // 注入真实挂起，保证取消发生在流式过程中而不是流结束后。
            sleep: { _ in try? await Task.sleep(nanoseconds: 20_000_000) }
        )
        try engine.load(asset)

        let stream = engine.generateStream(InferenceRequest(mode: .chat, prompt: "测试"))
        let task = Task {
            var tokens = 0
            for try await event in stream {
                if case .token = event { tokens += 1 }
            }
            return tokens
        }
        // 等待流式开始后取消消费任务 → 流终止 → 内部推理 Task 被取消。
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.result

        // 等待内部 Task 记录取消指标。
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.status().lastMetrics?.cancelled, true)
    }

    func testUnloadReturnsCleanState() throws {
        let engine = MockInferenceEngine()
        try engine.load(asset)
        XCTAssertEqual(engine.status().state, .ready)
        engine.unload()
        XCTAssertEqual(engine.status().state, .unloaded)
        XCTAssertNil(engine.status().asset)
    }

    func testFactoryUsesMockForBundledAssetAndMLXForInstalledAsset() throws {
        let bundledEngine = InferenceEngineFactory.make(for: asset)
        XCTAssertTrue(bundledEngine is MockInferenceEngine)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        let headerData = Data(#"{"weight":{"dtype":"F16","shape":[1],"data_offsets":[0,1]}}"#.utf8)
        try (withUnsafeBytes(of: UInt64(headerData.count).littleEndian) { Data($0) } + headerData + Data([1]))
            .write(to: directory.appendingPathComponent("model.safetensors"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let installedAsset = ModelAsset(
            id: "installed-mlx",
            tier: .entry,
            version: "1.0.0",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 1024,
            capabilities: [.chat],
            localDirectory: directory,
            format: "mlx-4bit"
        )
        let mlxEngine = InferenceEngineFactory.make(for: installedAsset)
        XCTAssertTrue(mlxEngine is MLXInferenceEngine)

        try mlxEngine.load(installedAsset)
        XCTAssertEqual(mlxEngine.status().state, .ready)
        XCTAssertEqual(mlxEngine.status().asset?.localDirectory, directory)
    }

    func testMLXEngineRejectsMissingInstalledDirectory() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-mlx-\(UUID().uuidString)", isDirectory: true)
        let installedAsset = ModelAsset(
            id: "missing-mlx",
            tier: .entry,
            version: "1.0.0",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 1024,
            capabilities: [.chat],
            localDirectory: missing,
            format: "mlx-4bit"
        )
        XCTAssertThrowsError(try MLXInferenceEngine().load(installedAsset))
    }

    func testExplicitLengthIntentRaisesNormalChatBudgetOnly() {
        XCTAssertNil(OutputLengthPlanner.requestedChars(in: "介绍一下自己"))
        XCTAssertEqual(OutputLengthPlanner.requestedChars(in: "请写一篇800字作文"), 800)
        XCTAssertEqual(
            OutputLengthPlanner.targetChars(
                userText: "请写一篇800字作文",
                thermalLimit: nil,
                mode: .chat
            ),
            800
        )
        XCTAssertEqual(
            OutputLengthPlanner.targetChars(
                userText: "请写一篇800字作文",
                thermalLimit: 120,
                mode: .chat
            ),
            120
        )
        XCTAssertEqual(
            OutputLengthPlanner.targetChars(
                userText: "请写一篇9000字作文",
                thermalLimit: nil,
                mode: .chat
            ),
            2_000
        )
        XCTAssertEqual(
            OutputLengthPlanner.targetChars(
                userText: "请写一篇800字作文",
                thermalLimit: nil,
                mode: .voice
            ),
            200
        )
    }

    func testGenerationWatchdogSeparatesFirstTokenAndIncrementTimeouts() {
        var now = Date(timeIntervalSince1970: 1_000)
        let watchdog = GenerationWatchdog(
            clock: { now },
            firstTokenTimeout: 60,
            tokenIntervalTimeout: 45
        )
        XCTAssertNil(watchdog.timeoutStage())

        now = now.addingTimeInterval(61)
        XCTAssertEqual(watchdog.timeoutStage(), "等待首 token")

        watchdog.markHasToken()
        watchdog.touch()
        XCTAssertNil(watchdog.timeoutStage())

        now = now.addingTimeInterval(46)
        XCTAssertEqual(watchdog.timeoutStage(), "等待下一 token")
        watchdog.markTimedOut("等待下一 token")
        XCTAssertNil(watchdog.timeoutStage())
        XCTAssertTrue(watchdog.timedOut)
    }

    private func collect(_ stream: AsyncThrowingStream<InferenceEvent, Error>) async throws -> [InferenceEvent] {
        var events: [InferenceEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {
            // expected
        }
    }
}
