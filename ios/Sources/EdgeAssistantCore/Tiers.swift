import Foundation

/// 功能模式，与 JS 原型 `SUPPORTED_MODES` 对齐。
public enum CapabilityMode: String, CaseIterable, Codable, Sendable {
    case chat, voice, video
}

/// 设备档位，与 JS 原型 `MODEL_TIERS` 对齐。
public enum ModelTier: String, CaseIterable, Codable, Sendable {
    case flagship, mainstream, entry

    public var label: String {
        switch self {
        case .flagship: return "Flagship"
        case .mainstream: return "Mainstream"
        case .entry: return "Entry"
        }
    }

    public var modelDescription: String {
        switch self {
        case .flagship: return "3–4B dense / MoE, 4-bit"
        case .mainstream: return "1.5–2B dense, 4-bit"
        case .entry: return "1B dense, 4-bit"
        }
    }

    public var assetSizeDescription: String {
        switch self {
        case .flagship: return "2.0–2.5GB"
        case .mainstream: return "1.0–1.5GB"
        case .entry: return "0.7–0.9GB"
        }
    }

    public var supportedModes: [CapabilityMode] {
        self == .entry ? [.chat, .voice] : [.chat, .voice, .video]
    }
}

public enum DeviceProfileError: Error, Equatable {
    case invalidRAM
}

/// 机型分级输入与结果，与 JS `classifyDevice` 对齐。
public struct DeviceProfile: Equatable, Sendable {
    public let ramGB: Int
    public let hasNPU: Bool

    public init(ramGB: Int, hasNPU: Bool) throws {
        guard ramGB > 0 else { throw DeviceProfileError.invalidRAM }
        self.ramGB = ramGB
        self.hasNPU = hasNPU
    }

    public var tier: ModelTier {
        if ramGB >= 12 && hasNPU { return .flagship }
        if ramGB >= 8 { return .mainstream }
        return .entry
    }
}
