import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// MLX Swift LM 3.x 适配层：把本地已安装模型接入 `InferenceEngine` 契约。
/// 对上层只暴露域类型；`ModelContainer`、tokenizer 和生成流都不外泄。
public class MLXInferenceEngine: InferenceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: () -> Date
    private let firstTokenTimeout: TimeInterval
    private let tokenIntervalTimeout: TimeInterval

    private var asset: ModelAsset?
    private var state: EngineState = .unloaded
    private var lastMetrics: InferenceMetrics?
    private var lastError: String?
    private var container: ModelContainer?

    public init(
        clock: @escaping () -> Date = { Date() },
        firstTokenTimeout: TimeInterval = 60,
        tokenIntervalTimeout: TimeInterval = 45
    ) {
        self.clock = clock
        self.firstTokenTimeout = firstTokenTimeout
        self.tokenIntervalTimeout = tokenIntervalTimeout
    }

    public func load(_ asset: ModelAsset) throws {
        guard !asset.capabilities.isEmpty else { throw EngineError.assetRequired }

        guard let directory = asset.localDirectory else {
            lastError = "MLX asset has no local directory"
            throw EngineError.notReady
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw EngineError.modelDirectoryMissing(directory.path)
        }

        // 轻量检查下载清单中的关键文件，避免到生成阶段才发现权重缺失。
        do {
            try RemoteFileValidator.validateModelDirectory(at: directory)
        } catch let error as ModelStoreError {
            if case .invalidModelFile(let path, let reason) = error {
                throw EngineError.invalidModelFile(path, reason)
            }
            throw error
        }

        lock.lock()
        self.asset = asset
        self.state = .ready
        self.lastError = nil
        lock.unlock()
    }

    public func unload() {
        lock.lock()
        asset = nil
        container = nil
        state = .unloaded
        lock.unlock()
    }

    /// App 激活时预热真实容器，把 tokenizer/config/权重加载错误提前到切换阶段。
    public func prepare() async throws {
        _ = try await ensureContainer()
    }

    public func status() -> EngineStatus {
        lock.lock()
        defer { lock.unlock() }
        return EngineStatus(
            state: state,
            asset: asset,
            lastMetrics: lastMetrics,
            lastError: lastError
        )
    }

    public func generateStream(
        _ request: InferenceRequest
    ) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runGeneration(request, continuation: continuation)
                } catch {
                    if !(error is CancellationError) {
                        self.lock.lock()
                        self.lastError = error.localizedDescription
                        self.lock.unlock()
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runGeneration(
        _ request: InferenceRequest,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) async throws {
        let watchdog = GenerationWatchdog(
            clock: clock,
            firstTokenTimeout: firstTokenTimeout,
            tokenIntervalTimeout: tokenIntervalTimeout
        )
        watchdog.touch()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.consumeGeneration(request, continuation: continuation, watchdog: watchdog)
                }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { break }
                        if let stage = watchdog.timeoutStage() {
                            watchdog.markTimedOut(stage)
                            continuation.finish(throwing: EngineError.timeout(stage))
                            throw EngineError.timeout(stage)
                        }
                    }
                }

                // 生成或看门狗任一路先结束；另一路随后被取消并静默回收。
                _ = try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError where watchdog.timedOut {
            throw EngineError.timeout(watchdog.timedOutStage ?? "本地推理")
        } catch {
            if watchdog.timedOut, let stage = watchdog.timedOutStage {
                throw EngineError.timeout(stage)
            }
            throw error
        }
    }

    private func consumeGeneration(
        _ request: InferenceRequest,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation,
        watchdog: GenerationWatchdog
    ) async throws {
        guard let currentAsset = status().asset,
              status().state == .ready else {
            throw EngineError.notReady
        }
        guard currentAsset.capabilities.contains(request.mode) else {
            throw EngineError.capabilityMissing(request.mode)
        }

        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw EngineError.promptRequired }
        if Task.isCancelled { throw CancellationError() }

        let modelContainer = try await ensureContainer()
        watchdog.touch()

        let maxOutputChars = request.maxOutputChars
            ?? (request.mode == .voice ? 48 : request.mode == .video ? 120 : 180)
        // 中文/token 数与字符数并非 1:2；上浮预算避免长文在模型端被提前截断。
        let maxTokens = max(16, Int((Double(maxOutputChars) * 1.4).rounded(.up)))

        let userInput = UserInput(chat: [
            .system(systemPrompt(maxOutputChars: maxOutputChars)),
            .user(prompt),
        ])

        let input = try await modelContainer.prepare(input: userInput)
        watchdog.touch()
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0.2
        )

        let startedAt = clock()
        var firstTokenAt: Date?
        var outputChars = 0

        let generation = try await modelContainer.generate(
            input: input,
            parameters: parameters
        )
        watchdog.touch()

        for try await event in generation {
            watchdog.touch()
            if Task.isCancelled {
                record(
                    request: request,
                    cancelled: true,
                    startedAt: startedAt,
                    firstTokenAt: firstTokenAt,
                    outputChars: outputChars
                )
                throw CancellationError()
            }

            switch event {
            case .chunk(let text):
                if firstTokenAt == nil {
                    firstTokenAt = clock()
                    watchdog.markHasToken()
                }
                outputChars += text.count
                continuation.yield(.token(
                    text: text,
                    firstTokenMs: ms(between: startedAt, and: firstTokenAt!),
                    outputChars: outputChars
                ))

                if outputChars >= maxOutputChars {
                    let metrics = record(
                        request: request,
                        cancelled: false,
                        startedAt: startedAt,
                        firstTokenAt: firstTokenAt,
                        outputChars: outputChars
                    )
                    continuation.yield(.done(metrics))
                    continuation.finish()
                    return
                }

            case .info:
                continue

            case .toolCall, .rejectedToolCall:
                throw EngineError.toolCallsUnsupported
            }
        }

        let metrics = record(
            request: request,
            cancelled: false,
            startedAt: startedAt,
            firstTokenAt: firstTokenAt,
            outputChars: outputChars
        )
        continuation.yield(.done(metrics))
        continuation.finish()
    }

    func loadContainer(from directory: URL) async throws -> ModelContainer {
        try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
    }

    func systemPrompt(maxOutputChars: Int) -> String {
        if maxOutputChars >= 600 {
            return "你是运行在用户设备本地的离线助手。请按用户要求的结构和字数完成回答，不要提前结束，也不要只回复等待或计划。"
        }
        return "你是运行在用户设备本地的离线助手。请用简体中文简洁回答。"
    }

    func ensureContainer() async throws -> ModelContainer {
        if let container = cachedContainer() {
            return container
        }

        let directory = status().asset?.localDirectory
        guard let directory else { throw EngineError.notReady }

        let loaded = try await loadContainer(from: directory)

        storeContainer(loaded)
        return loaded
    }

    private func cachedContainer() -> ModelContainer? {
        lock.withLock { container }
    }

    private func storeContainer(_ value: ModelContainer) {
        lock.withLock { container = value }
    }

    private func record(
        request: InferenceRequest,
        cancelled: Bool,
        startedAt: Date,
        firstTokenAt: Date?,
        outputChars: Int
    ) -> InferenceMetrics {
        let metrics = InferenceMetrics(
            mode: request.mode,
            cancelled: cancelled,
            firstTokenMs: firstTokenAt.map { ms(between: startedAt, and: $0) },
            durationMs: ms(between: startedAt, and: clock()),
            outputChars: outputChars,
            plannedFirstTokenMs: nil
        )

        lock.lock()
        lastMetrics = metrics
        lock.unlock()
        return metrics
    }

    private func ms(between start: Date, and end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }
}

/// MLX 生成流的无进展看门狗：加载/prepare/生成任一阶段卡住都会转成显式错误。
final class GenerationWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: () -> Date
    private let firstTokenTimeout: TimeInterval
    private let tokenIntervalTimeout: TimeInterval
    private var startedAt: Date
    private var lastActivityAt: Date
    private var hasToken = false
    private(set) var timedOut = false
    private(set) var timedOutStage: String?

    init(
        clock: @escaping () -> Date,
        firstTokenTimeout: TimeInterval,
        tokenIntervalTimeout: TimeInterval
    ) {
        self.clock = clock
        self.firstTokenTimeout = firstTokenTimeout
        self.tokenIntervalTimeout = tokenIntervalTimeout
        let now = clock()
        self.startedAt = now
        self.lastActivityAt = now
    }

    func touch() {
        lock.lock()
        lastActivityAt = clock()
        lock.unlock()
    }

    func markTimedOut(_ stage: String) {
        lock.lock()
        timedOut = true
        timedOutStage = stage
        lock.unlock()
    }

    func markHasToken() {
        lock.lock()
        hasToken = true
        lock.unlock()
    }

    func timeoutStage() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !timedOut else { return nil }
        let now = clock()
        if !hasToken, now.timeIntervalSince(lastActivityAt) >= firstTokenTimeout {
            return "等待首 token"
        }
        if hasToken, now.timeIntervalSince(lastActivityAt) >= tokenIntervalTimeout {
            return "等待下一 token"
        }
        return nil
    }
}
