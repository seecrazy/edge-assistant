import Foundation

public enum EngineState: String, Sendable {
    case unloaded, ready
}

public enum EngineError: Error, Equatable {
    case notReady
    case assetRequired
    case capabilityMissing(CapabilityMode)
    case promptRequired
    case modelDirectoryMissing(String)
    case invalidModelFile(String, String)
    case toolCallsUnsupported
    case timeout(String)
}

extension EngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notReady:
            return "推理引擎尚未就绪。"
        case .assetRequired:
            return "推理资产缺少能力声明。"
        case .capabilityMissing(let mode):
            return "当前模型不支持能力：\(mode.rawValue)。"
        case .promptRequired:
            return "请输入要发送的内容。"
        case .modelDirectoryMissing(let path):
            return "模型目录或必需文件缺失：\(path)。"
        case .invalidModelFile(let path, let reason):
            return "模型文件损坏或不受支持：\(path)（\(reason)）。请删除模型后重新下载。"
        case .toolCallsUnsupported:
            return "当前本地模型不支持工具调用。"
        case .timeout(let stage):
            return "本地推理长时间没有进展（\(stage)）。请停止后重试；若连续失败，请切换到更轻量的本地模型。"
        }
    }
}

public struct InferenceRequest: Sendable {
    public let mode: CapabilityMode
    public let prompt: String
    public let maxOutputChars: Int?

    public init(mode: CapabilityMode, prompt: String, maxOutputChars: Int? = nil) {
        self.mode = mode
        self.prompt = prompt
        self.maxOutputChars = maxOutputChars
    }
}

/// 用户明确长度意图与端侧安全预算的单一入口（ADR 0012）。
public enum OutputLengthPlanner {
    public static func requestedChars(in text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let regex = try? NSRegularExpression(pattern: #"(?:至少|不少于|大约|约)?([0-9]{2,5})\s*(?:个)?(?:中/英)?字(?:符|数)?"#) else {
            return nil
        }
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: text),
              let value = Int(text[numberRange]), value > 0 else {
            return nil
        }
        return value
    }

    public static func targetChars(
        userText: String,
        thermalLimit: Int?,
        mode: CapabilityMode
    ) -> Int {
        if let thermalLimit {
            return thermalLimit
        }

        let defaultLimit: Int
        let hardLimit: Int
        switch mode {
        case .chat:
            defaultLimit = 180
            hardLimit = 2_000
        case .voice:
            defaultLimit = 48
            hardLimit = 200
        default:
            defaultLimit = 120
            hardLimit = 400
        }

        guard let requested = requestedChars(in: userText) else {
            return defaultLimit
        }
        return min(max(requested, 16), hardLimit)
    }
}

public struct InferenceMetrics: Sendable, Equatable {
    public let mode: CapabilityMode
    public let cancelled: Bool
    public let firstTokenMs: Int?
    public let durationMs: Int
    public let outputChars: Int
    public let plannedFirstTokenMs: Int?
}

public enum InferenceEvent: Sendable {
    case token(text: String, firstTokenMs: Int?, outputChars: Int)
    case done(InferenceMetrics)
}

public struct EngineStatus: Sendable {
    public let state: EngineState
    public let asset: ModelAsset?
    public let lastMetrics: InferenceMetrics?
    public let lastError: String?
}

/// 跨后端推理契约（ADR 0004）：生命周期、能力门控、流式输出、取消语义。
public protocol InferenceEngine: AnyObject, Sendable {
    func load(_ asset: ModelAsset) throws
    /// 激活阶段加载真实后端必需资源；Mock 可立即通过。
    func prepare() async throws
    func unload()
    func status() -> EngineStatus
    func generateStream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error>
}

/// 确定性 Mock 后端：固化协议语义，真实 MLX / llama.cpp 适配层按同一协议接入。
public final class MockInferenceEngine: InferenceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let replyBuilder: (InferenceRequest) -> String
    private let latencyPlanner: (CapabilityMode) -> Int?
    private let clock: () -> Date
    private let sleep: (Int) async -> Void

    private var asset: ModelAsset?
    private var state: EngineState
    private var lastMetrics: InferenceMetrics?
    private var lastError: String?

    public init(
        replyBuilder: @escaping (InferenceRequest) -> String = { "本地模拟推理完成：\($0.prompt)" },
        latencyPlanner: @escaping (CapabilityMode) -> Int? = { _ in nil },
        clock: @escaping () -> Date = { Date() },
        sleep: @escaping (Int) async -> Void = { _ in }
    ) {
        self.replyBuilder = replyBuilder
        self.latencyPlanner = latencyPlanner
        self.clock = clock
        self.sleep = sleep
        self.asset = nil
        self.state = .unloaded
    }

    public func load(_ asset: ModelAsset) throws {
        guard !asset.capabilities.isEmpty else { throw EngineError.assetRequired }
        lock.lock()
        self.asset = asset
        state = .ready
        lastError = nil
        lock.unlock()
    }

    public func prepare() async throws {}

    public func unload() {
        lock.lock()
        asset = nil
        state = .unloaded
        lock.unlock()
    }

    public func status() -> EngineStatus {
        lock.lock()
        defer { lock.unlock() }
        return EngineStatus(state: state, asset: asset, lastMetrics: lastMetrics, lastError: lastError)
    }

    public func generateStream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let asset = self.status().asset, self.status().state == .ready else {
                        throw EngineError.notReady
                    }
                    guard asset.capabilities.contains(request.mode) else {
                        throw EngineError.capabilityMissing(request.mode)
                    }
                    let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !prompt.isEmpty else { throw EngineError.promptRequired }
                    if Task.isCancelled { throw CancellationError() }

                    let maxChars = request.maxOutputChars
                        ?? (request.mode == .voice ? 48 : request.mode == .video ? 120 : 180)
                    let reply = String(self.replyBuilder(request).prefix(maxChars))
                    let chunkSize = request.mode == .voice ? 2 : 3
                    let chunks = stride(from: 0, to: reply.count, by: chunkSize).map {
                        String(Array(reply)[$0..<min($0 + chunkSize, reply.count)])
                    }

                    let startedAt = self.clock()
                    var firstTokenAt: Date?
                    var outputChars = 0

                    for chunk in chunks {
                        await self.sleep(0)
                        if Task.isCancelled {
                            self.recordCancellation(request.mode, startedAt: startedAt, firstTokenAt: firstTokenAt, outputChars: outputChars)
                            throw CancellationError()
                        }
                        if firstTokenAt == nil { firstTokenAt = self.clock() }
                        outputChars += chunk.count
                        continuation.yield(.token(
                            text: chunk,
                            firstTokenMs: self.ms(between: startedAt, and: firstTokenAt!),
                            outputChars: outputChars
                        ))
                    }

                    let metrics = InferenceMetrics(
                        mode: request.mode,
                        cancelled: false,
                        firstTokenMs: firstTokenAt.map { self.ms(between: startedAt, and: $0) } ?? 0,
                        durationMs: self.ms(between: startedAt, and: self.clock()),
                        outputChars: outputChars,
                        plannedFirstTokenMs: self.latencyPlanner(request.mode)
                    )
                    self.lock.lock()
                    self.lastMetrics = metrics
                    self.lastError = nil
                    self.lock.unlock()
                    continuation.yield(.done(metrics))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func recordCancellation(_ mode: CapabilityMode, startedAt: Date, firstTokenAt: Date?, outputChars: Int) {
        let metrics = InferenceMetrics(
            mode: mode,
            cancelled: true,
            firstTokenMs: firstTokenAt.map { self.ms(between: startedAt, and: $0) },
            durationMs: self.ms(between: startedAt, and: self.clock()),
            outputChars: outputChars,
            plannedFirstTokenMs: nil
        )
        lock.lock()
        lastMetrics = metrics
        lock.unlock()
    }

    private func ms(between start: Date, and end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }
}
