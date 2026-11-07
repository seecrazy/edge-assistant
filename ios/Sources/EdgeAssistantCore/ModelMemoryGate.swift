import Foundation

/// 激活前内存护栏：超过 iOS 内存的 MLX 加载会被系统 SIGKILL，不能等引擎自己去撞。
public enum ModelMemoryGate {
    public struct Decision: Equatable, Sendable {
        public let canLoad: Bool
        public let requiredBytes: Int64
        public let availableBytes: Int64
        public let reason: String?
    }

    /// 权重之外保留上下文、KV cache、Metal buffer 和系统余量。
    public static func evaluate(
        modelBytes: Int64,
        availableBytes: Int64,
        reserveBytes: Int64 = 1_500_000_000
    ) -> Decision {
        let modelBytes = max(0, modelBytes)
        let reserveBytes = max(0, reserveBytes)
        let availableBytes = max(0, availableBytes)
        let requiredBytes = modelBytes + reserveBytes
        let canLoad = availableBytes >= requiredBytes
        return Decision(
            canLoad: canLoad,
            requiredBytes: requiredBytes,
            availableBytes: availableBytes,
            reason: canLoad ? nil : "模型加载预计需要 \(requiredBytes) 字节内存，当前仅 \(availableBytes) 字节可用。"
        )
    }

    public static func currentAvailableBytes() -> Int64 {
        #if os(macOS)
        return Int64(ProcessInfo.processInfo.physicalMemory / 2)
        #else
        let bytes = os_proc_available_memory()
        return bytes == 0 ? 0 : Int64(clamping: bytes)
        #endif
    }
}
