import Foundation

/// 设计 §5.7 的四级热档位。
public enum ThermalLevel: String, Sendable {
    case normal, warm, hot, critical
}

public struct ThermalDegradePlan: Equatable, Sendable {
    public let level: ThermalLevel
    public let shortenReplyLimit: Bool
    public let reduceVisionFPS: Bool
    public let disableVisionPipeline: Bool
    public let pauseInference: Bool
    /// `nil` 表示沿用当前模式默认上限；`critical` 由调用方先阻止推理。
    public let chatReplyCharLimit: Int?
}

/// `ProcessInfo.thermalState` → 设计档位 + 预定义降级动作。
public enum ThermalMapper {
    public static func level(for state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .normal
        case .fair: return .warm
        case .serious: return .hot
        case .critical: return .critical
        @unknown default: return .normal
        }
    }

    public static func degradePlan(for level: ThermalLevel) -> ThermalDegradePlan {
        switch level {
        case .normal:
            return ThermalDegradePlan(
                level: level,
                shortenReplyLimit: false,
                reduceVisionFPS: false,
                disableVisionPipeline: false,
                pauseInference: false,
                chatReplyCharLimit: nil
            )
        case .warm:
            return ThermalDegradePlan(
                level: level,
                shortenReplyLimit: true,
                reduceVisionFPS: true,
                disableVisionPipeline: false,
                pauseInference: false,
                chatReplyCharLimit: 120
            )
        case .hot:
            return ThermalDegradePlan(
                level: level,
                shortenReplyLimit: true,
                reduceVisionFPS: true,
                disableVisionPipeline: true,
                pauseInference: false,
                chatReplyCharLimit: 90
            )
        case .critical:
            return ThermalDegradePlan(
                level: level,
                shortenReplyLimit: true,
                reduceVisionFPS: true,
                disableVisionPipeline: true,
                pauseInference: true,
                chatReplyCharLimit: nil
            )
        }
    }

    public static func rank(for level: ThermalLevel) -> Int {
        switch level {
        case .normal: return 0
        case .warm: return 1
        case .hot: return 2
        case .critical: return 3
        }
    }
}

/// 注入时间源，使恢复迟滞可在单元测试中确定性验证。
public protocol ThermalClock: Sendable {
    func now() -> ContinuousClock.Instant
}

public struct SystemThermalClock: ThermalClock {
    public init() {}

    public func now() -> ContinuousClock.Instant {
        ContinuousClock.now
    }
}

/// 热档位迟滞控制器：升级立即生效；恢复逐级且每级至少停留 `recoveryHold`。
public struct ThermalHysteresisController: Sendable {
    private let recoveryHold: Duration
    private let clock: any ThermalClock
    private(set) var current: ThermalLevel
    private(set) var currentChangedAt: ContinuousClock.Instant

    public init(
        initialLevel: ThermalLevel = .normal,
        recoveryHold: Duration = .seconds(60),
        clock: any ThermalClock = SystemThermalClock()
    ) {
        self.recoveryHold = recoveryHold
        self.clock = clock
        self.current = initialLevel
        self.currentChangedAt = clock.now()
    }

    public var level: ThermalLevel {
        current
    }

    public var plan: ThermalDegradePlan {
        ThermalMapper.degradePlan(for: current)
    }

    @discardableResult
    public mutating func update(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        update(to: ThermalMapper.level(for: state))
    }

    @discardableResult
    public mutating func update(to target: ThermalLevel) -> ThermalLevel {
        if ThermalMapper.rank(for: target) > ThermalMapper.rank(for: current) {
            move(to: target, at: clock.now())
            return current
        }

        guard target != current, clock.now() - currentChangedAt >= recoveryHold else {
            return current
        }

        let targetRank = ThermalMapper.rank(for: target)
        let currentRank = ThermalMapper.rank(for: current)
        if targetRank > currentRank {
            move(to: target, at: clock.now())
        } else if let recovered = ThermalLevel.allCases.first(where: {
            ThermalMapper.rank(for: $0) == currentRank - 1
        }) {
            move(to: recovered, at: clock.now())
        }
        return current
    }

    private mutating func move(to level: ThermalLevel, at instant: ContinuousClock.Instant) {
        current = level
        currentChangedAt = instant
    }
}

extension ThermalLevel: CaseIterable {}
