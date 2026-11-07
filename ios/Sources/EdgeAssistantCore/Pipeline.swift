import Foundation

public enum PipelineError: Error, Equatable {
    case unknownMode
    case unknownTier
}

public struct PipelineStage: Equatable, Sendable {
    public let name: String
    public let targetMs: Int
}

public struct PipelinePlan: Equatable, Sendable {
    public let mode: CapabilityMode
    public let tier: ModelTier
    public let stages: [PipelineStage]
    public let totalMs: Int
    public let meetsTarget: Bool
}

/// 延迟预算，与 JS `planPipeline` 对齐。
public enum PipelinePlanner {
    public static func plan(mode: CapabilityMode, tier: ModelTier) -> PipelinePlan {
        let llmFirstToken = tier.firstTokenLatency
        let ttsFirstBlock = tier == .entry ? 140 : 120

        let stages: [PipelineStage]
        switch mode {
        case .chat:
            stages = [
                .init(name: "本地上下文检索", targetMs: 70),
                .init(name: "LLM 首 token", targetMs: llmFirstToken),
                .init(name: "UI 流式渲染", targetMs: 40),
            ]
        case .voice:
            stages = [
                .init(name: "VAD 判定说完", targetMs: 80),
                .init(name: "ASR 尾句定稿", targetMs: tier == .entry ? 220 : 200),
                .init(name: "LLM 首 token", targetMs: llmFirstToken),
                .init(name: "TTS 首音频块", targetMs: ttsFirstBlock),
                .init(name: "播放启动", targetMs: 20),
            ]
        case .video:
            let vlmMs: Int
            switch tier {
            case .flagship: vlmMs = 250
            case .mainstream: vlmMs = 400
            case .entry: vlmMs = 700
            }
            stages = [
                .init(name: "关键帧抽取", targetMs: 80),
                .init(name: "VLM 画面摘要", targetMs: vlmMs),
                .init(name: "视觉上下文压缩", targetMs: 40),
                .init(name: "LLM 首 token", targetMs: llmFirstToken),
                .init(name: "TTS 首音频块", targetMs: ttsFirstBlock),
            ]
        }

        let total = stages.reduce(0) { $0 + $1.targetMs }
        return PipelinePlan(mode: mode, tier: tier, stages: stages, totalMs: total, meetsTarget: total <= 1200)
    }
}

extension ModelTier {
    var firstTokenLatency: Int {
        switch self {
        case .flagship: return 350
        case .mainstream: return 500
        case .entry: return 700
        }
    }
}

// MARK: - 语音通话状态机（与 JS `CONVERSATION_TRANSITIONS` 对齐）

public enum VoiceState: String, Sendable {
    case idle, listening, thinking, speaking
}

public enum VoiceEvent: String, Sendable {
    case startCall, submitText, userStop, interrupt, stopCall
    case firstToken, ttsDone, textResponse, error
}

public struct ConversationStateMachine: Equatable, Sendable {
    public private(set) var state: VoiceState = .idle

    public init() {}

    @discardableResult
    public mutating func send(_ event: VoiceEvent) -> VoiceState? {
        let nextState: VoiceState?
        switch (state, event) {
        case (.idle, .startCall): nextState = .listening
        case (.idle, .submitText): nextState = .thinking
        case (.listening, .userStop): nextState = .thinking
        case (.listening, .interrupt): nextState = .listening
        case (.listening, .stopCall): nextState = .idle
        case (.thinking, .firstToken): nextState = .speaking
        case (.thinking, .textResponse): nextState = .idle
        case (.thinking, .interrupt): nextState = .listening
        case (.thinking, .stopCall): nextState = .idle
        case (.thinking, .error): nextState = .idle
        case (.speaking, .ttsDone): nextState = .listening
        case (.speaking, .interrupt): nextState = .listening
        case (.speaking, .stopCall): nextState = .idle
        case (.speaking, .error): nextState = .idle
        default: nextState = nil
        }
        if let next = nextState { state = next }
        return nextState
    }
}

/// 打断动作，与 JS `interruptAction` 对齐：任何阶段打断都必须取消未完成推理。
public struct InterruptAction: Equatable, Sendable {
    public let stopTts: Bool
    public let dropQueuedAudio: Bool
    public let cancelInference: Bool
    public let nextState: VoiceState
}

public enum Interrupt {
    public static func action(for state: VoiceState) -> InterruptAction? {
        switch state {
        case .speaking:
            return InterruptAction(stopTts: true, dropQueuedAudio: true, cancelInference: true, nextState: .listening)
        case .thinking:
            return InterruptAction(stopTts: false, dropQueuedAudio: false, cancelInference: true, nextState: .listening)
        case .listening:
            return InterruptAction(stopTts: false, dropQueuedAudio: false, cancelInference: false, nextState: .listening)
        case .idle:
            return nil
        }
    }
}
